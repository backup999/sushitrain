package sushitrain

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path"
	"strings"

	"github.com/syncthing/syncthing/lib/build"
	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/db/backend"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/osutil"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/sha256"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
)

type Client struct {
	Delegate                   ClientDelegate
	cert                       tls.Certificate
	config                     config.Wrapper
	cancel                     context.CancelFunc
	ctx                        context.Context
	backend                    backend.Backend
	app                        *syncthing.App
	evLogger                   events.Logger
	Server                     *StreamingServer
	foldersTransferring        map[string]bool
	downloadProgress           map[string]map[string]*model.PullerProgress
	IsUsingCustomConfiguration bool
	connectedDeviceAddresses   map[string]string
}

type ClientDelegate interface {
	OnEvent(event string)
	OnDeviceDiscovered(deviceID string, addresses *ListOfStrings)
	OnFolderOffered(deviceID string, folder string)
	OnListenAddressesChanged(addresses *ListOfStrings)
}

func NewClient(configPath string, filesPath string) (*Client, error) {
	// Set version info
	build.Version = "v1.27.9"
	build.Host = "t-shaped.nl"
	build.User = "sushitrain"

	// Some early chores
	osutil.MaximizeOpenFileLimit()
	sha256.SelectAlgo()
	sha256.Report()

	// Set up logging and context for cancellation
	ctx, cancel := context.WithCancel(context.Background())
	evLogger := events.NewLogger()
	go evLogger.Serve(ctx)

	// Set up default locations
	locations.SetBaseDir(locations.DataBaseDir, configPath)
	locations.SetBaseDir(locations.ConfigBaseDir, configPath)
	locations.SetBaseDir(locations.UserHomeBaseDir, filesPath)
	fmt.Printf("Database dir: %s\n", configPath)
	fmt.Printf("Files dir: %s\n", filesPath)

	// Check for custom user-provided config file
	isUsingCustomConfiguration := false
	customConfigFilePath := path.Join(filesPath, "config.xml")
	if info, err := os.Stat(customConfigFilePath); err == nil {
		if !info.IsDir() {
			fmt.Println("Config XML exists in files dir, using it at", customConfigFilePath)
			locations.Set(locations.ConfigFile, customConfigFilePath)
			isUsingCustomConfiguration = true
		}
	}

	// Check for custom user-provided identity
	customCertPath := path.Join(filesPath, "cert.pem")
	customKeyPath := path.Join(filesPath, "key.pem")
	if keyInfo, err := os.Stat(customKeyPath); err == nil {
		if !keyInfo.IsDir() {
			if certInfo, err := os.Stat(customCertPath); err == nil {
				if !certInfo.IsDir() {
					fmt.Println("Found user-provided identity files, using those")
					locations.Set(locations.CertFile, customCertPath)
					locations.Set(locations.KeyFile, customKeyPath)
					isUsingCustomConfiguration = true
				}
			}
		}
	}

	// Print final locations
	fmt.Printf("Config file: %s\n", locations.Get(locations.ConfigFile))
	fmt.Printf("Cert file: %s key file: %s\n", locations.Get(locations.CertFile), locations.Get(locations.KeyFile))

	// Ensure that we have a certificate and key.
	cert, err := syncthing.LoadOrGenerateCertificate(
		locations.Get(locations.CertFile),
		locations.Get(locations.KeyFile),
	)
	if err != nil {
		return nil, err
	}

	// Load or create the config
	devID := protocol.NewDeviceID(cert.Certificate[0])
	fmt.Printf("Loading config file from %s\n", locations.Get(locations.ConfigFile))
	config, err := loadOrDefaultConfig(devID, ctx, evLogger)
	if err != nil {
		return nil, err
	}

	// Load database
	dbFile := locations.Get(locations.Database)
	ldb, err := syncthing.OpenDBBackend(dbFile, config.Options().DatabaseTuning)
	if err != nil {
		return nil, err
	}

	appOpts := syncthing.Options{
		NoUpgrade:            false,
		ProfilerAddr:         "",
		ResetDeltaIdxs:       false,
		Verbose:              false,
		DBRecheckInterval:    0,
		DBIndirectGCInterval: 0,
	}

	app, err := syncthing.New(config, ldb, evLogger, cert, appOpts)
	if err != nil {
		return nil, err
	}

	server, err := NewServer(app, ctx)
	if err != nil {
		return nil, err
	}

	return &Client{
		Delegate:                   nil,
		cert:                       cert,
		config:                     config,
		cancel:                     cancel,
		ctx:                        ctx,
		backend:                    ldb,
		app:                        app,
		evLogger:                   evLogger,
		Server:                     server,
		foldersTransferring:        make(map[string]bool, 0),
		connectedDeviceAddresses:   make(map[string]string, 0),
		IsUsingCustomConfiguration: isUsingCustomConfiguration,
	}, nil
}

func (self *Client) Stop() {
	self.app.Stop(svcutil.ExitSuccess)
	self.cancel()
	self.app.Wait()
}

func (self *Client) startEventListener() {
	sub := self.evLogger.Subscribe(events.AllEvents)
	defer sub.Unsubscribe()

	for {
		select {
		case <-self.ctx.Done():
			return
		case evt := <-sub.C():
			if self.Delegate != nil {
				switch evt.Type {
				case events.DeviceDiscovered:
					data := evt.Data.(map[string]interface{})
					devID := data["device"].(string)
					addresses := data["addrs"].([]string)
					self.Delegate.OnDeviceDiscovered(devID, &ListOfStrings{data: addresses})

				case events.FolderRejected:
					// TODO: FolderRejected is deprecated
					data := evt.Data.(map[string]string)
					devID := data["device"]
					folderID := data["folder"]
					self.Delegate.OnFolderOffered(devID, folderID)

				case events.StateChanged:
					// Keep track of which folders are in syncing state. We need to know whether we are idling or not
					data := evt.Data.(map[string]interface{})
					folder := data["folder"].(string)
					state := data["to"].(string)
					folderTransferring := (state == model.FolderSyncing.String() || state == model.FolderSyncWaiting.String() || state == model.FolderSyncPreparing.String())
					self.foldersTransferring[folder] = folderTransferring
					self.Delegate.OnEvent(evt.Type.String())

				case events.ConfigSaved, events.ClusterConfigReceived:
					self.Delegate.OnEvent(evt.Type.String())

				case events.DownloadProgress:
					self.downloadProgress = evt.Data.(map[string]map[string]*model.PullerProgress)
					self.Delegate.OnEvent(evt.Type.String())

				case events.ListenAddressesChanged:
					addrs := make([]string, 0)
					data := evt.Data.(map[string]interface{})
					wanAddresses := data["wan"].([]*url.URL)
					lanAddresses := data["lan"].([]*url.URL)

					for _, wa := range wanAddresses {
						addrs = append(addrs, wa.String())
					}
					for _, la := range lanAddresses {
						addrs = append(addrs, la.String())
					}

					self.Delegate.OnListenAddressesChanged(List(addrs))

				case events.DeviceConnected:
					data := evt.Data.(map[string]string)
					devID := data["id"]
					address := data["addr"]
					self.connectedDeviceAddresses[devID] = address
					self.Delegate.OnEvent(evt.Type.String())

				case events.LocalIndexUpdated:
					self.Delegate.OnEvent(evt.Type.String())

				case events.DeviceDisconnected:
					self.Delegate.OnEvent(evt.Type.String())

				default:
					fmt.Println("EVENT", evt)
					//self.Delegate.OnEvent(evt.Type.String())
				}

			}
		}
	}
}

func (self *Client) GetLastPeerAddress(deviceID string) string {
	if addr, ok := self.connectedDeviceAddresses[deviceID]; ok {
		return addr
	}
	return ""
}

func (self *Client) IsTransferring() bool {
	for _, isTransferring := range self.foldersTransferring {
		if isTransferring {
			return true
		}
	}
	return false
}

func (self *Client) Start() error {
	// Subscribe to events
	go self.startEventListener()

	if err := self.app.Start(); err != nil {
		return err
	}

	return nil
}

func loadOrDefaultConfig(devID protocol.DeviceID, ctx context.Context, logger events.Logger) (config.Wrapper, error) {
	cfgFile := locations.Get(locations.ConfigFile)
	cfg, _, err := config.Load(cfgFile, devID, logger)
	if err != nil {
		newCfg := config.New(devID)
		newCfg.GUI.Enabled = false
		newCfg.Options.RawListenAddresses = make([]string, 0) // Do not listen by default, we will connect to other devices on our initiative
		cfg = config.Wrap(cfgFile, newCfg, devID, logger)

	}

	go cfg.Serve(ctx)

	// Always override the following options in config
	waiter, err := cfg.Modify(func(conf *config.Configuration) {
		conf.GUI.Enabled = false                         // Don't need the web UI, we have our own :-)
		conf.Options.CREnabled = false                   // No crash reporting for now
		conf.Options.URAccepted = -1                     // No usage reporting for now
		conf.Options.ProgressUpdateIntervalS = 1         // We want to update the user often, it improves the experience and is worth the compute cost
		conf.Options.CRURL = ""                          // No crash reporting for now
		conf.Options.URURL = ""                          // No usage reporting for now
		conf.Options.ReleasesURL = ""                    // Disable auto update, we can't do so on iOS anyway
		conf.Options.InsecureAllowOldTLSVersions = false // Never allow insecure TLS
		conf.Defaults.Folder.IgnorePerms = true          // iOS doesn't expose permissions to users
		conf.Options.RelayReconnectIntervalM = 1         // Set this to one minute (from the default 10) because on mobile networks this is more often necessary
	})

	if err != nil {
		return nil, err
	}
	waiter.Wait()

	err = cfg.Save()
	if err != nil {
		return nil, err
	}

	return cfg, err
}

/** Returns the device ID */
func (self *Client) DeviceID() string {
	return protocol.NewDeviceID(self.cert.Certificate[0]).String()
}

func (self *Client) deviceID() protocol.DeviceID {
	return protocol.NewDeviceID(self.cert.Certificate[0])
}

func (self *Client) Folders() *ListOfStrings {
	if self.config == nil {
		return nil
	}

	return List(Map(self.config.FolderList(), func(folder config.FolderConfiguration) string {
		return folder.ID
	}))
}

func (self *Client) FolderWithID(id string) *Folder {
	if self.config == nil {
		return nil
	}

	fi, ok := self.config.Folders()[id]
	if !ok {
		return nil // Folder with this ID does not exist
	}

	return &Folder{
		client:   self,
		FolderID: fi.ID,
	}
}

func (self *Client) ConnectedPeerCount() int {
	if self.config == nil || self.app == nil || self.app.M == nil {
		return 0
	}

	devIDs := self.config.Devices()
	connected := 0
	for devID, _ := range devIDs {
		if devID == self.deviceID() {
			continue
		}
		if self.app.M.ConnectedTo(devID) {
			connected++
		}
	}
	return connected
}

func (self *Client) Peers() *ListOfStrings {
	if self.config == nil {
		return nil
	}

	return List(Map(self.config.DeviceList(), func(device config.DeviceConfiguration) string {
		return device.DeviceID.String()
	}))
}

func (self *Client) PeerWithID(deviceID string) *Peer {
	devID, err := protocol.DeviceIDFromString(deviceID)

	if err != nil {
		return nil
	}

	return &Peer{
		client:   self,
		deviceID: devID,
	}
}

func (self *Client) changeConfiguration(block config.ModifyFunction) error {
	waiter, err := self.config.Modify(block)
	if err != nil {
		return err
	}
	waiter.Wait()

	err = self.config.Save()
	return err
}

func (self *Client) AddPeer(deviceID string) error {
	addedDevice, err := protocol.DeviceIDFromString(deviceID)
	if err != nil {
		return err
	}

	deviceConfig := self.config.DefaultDevice()
	deviceConfig.DeviceID = addedDevice

	return self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.SetDevice(deviceConfig)
	})
}

func (self *Client) AddFolder(folderID string) error {
	folderConfig := self.config.DefaultFolder()
	folderConfig.ID = folderID
	folderConfig.Label = folderID
	folderConfig.Path = path.Join(locations.Get(locations.LocationEnum(locations.UserHomeBaseDir)), folderID)
	folderConfig.FSWatcherEnabled = true
	folderConfig.Paused = false

	err := self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.SetFolder(folderConfig)
	})
	if err != nil {
		return err
	}

	// Set default ignores for on-demand sync
	return self.app.M.SetIgnores(folderID, []string{"*"})
}

func (self *Client) SetNATEnabled(enabled bool) error {
	return self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.NATEnabled = enabled
	})
}

func (self *Client) IsNATEnabled() bool {
	return self.config.Options().NATEnabled
}

func (self *Client) SetRelaysEnabled(enabled bool) error {
	return self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.RelaysEnabled = enabled
	})
}

func (self *Client) IsRelaysEnabled() bool {
	return self.config.Options().RelaysEnabled
}

func (self *Client) SetLocalAnnounceEnabled(enabled bool) error {
	return self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.LocalAnnEnabled = enabled
	})
}

func (self *Client) IsLocalAnnounceEnabled() bool {
	return self.config.Options().LocalAnnEnabled
}

func (self *Client) SetGlobalAnnounceEnabled(enabled bool) error {
	return self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.GlobalAnnEnabled = enabled
	})
}

func (self *Client) IsGlobalAnnounceEnabled() bool {
	return self.config.Options().GlobalAnnEnabled
}

func (self *Client) SetAnnounceLANAddresses(enabled bool) error {
	return self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.AnnounceLANAddresses = enabled
	})
}

func (self *Client) IsAnnounceLANAddressesEnabled() bool {
	return self.config.Options().AnnounceLANAddresses
}

func (self *Client) IsBandwidthLimitedInLAN() bool {
	return self.config.Options().LimitBandwidthInLan
}

func (self *Client) SetBandwidthLimitedInLAN(enabled bool) error {
	return self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.LimitBandwidthInLan = enabled
	})
}

func (self *Client) GetBandwidthLimitUpMbitsPerSec() int {
	return self.config.Options().MaxSendKbps / 1000
}

func (self *Client) GetBandwidthLimitDownMbitsPerSec() int {
	return self.config.Options().MaxRecvKbps / 1000
}

func (self *Client) SetBandwidthLimitsMbitsPerSec(down int, up int) error {
	if down < 0 {
		down = 0
	}
	if up < 0 {
		up = 0
	}

	return self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.MaxRecvKbps = down * 1000
		cfg.Options.MaxSendKbps = up * 1000
	})
}

type Progress struct {
	BytesTotal int64
	BytesDone  int64
	FilesTotal int64
	Percentage float32
}

func (self *Client) GetTotalDownloadProgress() *Progress {
	if self.downloadProgress == nil {
		return nil
	}

	var doneBytes, totalBytes int64
	doneBytes = 0
	totalBytes = 0
	fileCount := 0
	for _, info := range self.downloadProgress {
		for _, fileInfo := range info {
			doneBytes += fileInfo.BytesDone
			totalBytes += fileInfo.BytesTotal
			fileCount++
		}
	}

	if totalBytes == 0 {
		return nil
	}

	return &Progress{
		BytesTotal: totalBytes,
		BytesDone:  doneBytes,
		FilesTotal: int64(fileCount),
		Percentage: float32(doneBytes) / float32(totalBytes),
	}
}

func (self *Client) GetDownloadProgressForFile(path string, folder string) *Progress {
	if self.downloadProgress == nil {
		return nil
	}

	if folderInfo, ok := self.downloadProgress[folder]; ok {
		if fileInfo, ok := folderInfo[path]; ok {
			return &Progress{
				BytesTotal: fileInfo.BytesTotal,
				BytesDone:  fileInfo.BytesDone,
				FilesTotal: 1,
				Percentage: float32(fileInfo.BytesDone) / float32(fileInfo.BytesTotal),
			}
		}
	}

	return nil
}

func (self *Client) GetName() (string, error) {
	devID := self.deviceID()

	selfConfig, ok := self.config.Devices()[devID]
	if !ok {
		return "", errors.New("cannot find myself")
	}
	return selfConfig.Name, nil
}

func (self *Client) SetName(name string) error {
	devID := self.deviceID()

	selfConfig, ok := self.config.Devices()[devID]
	if !ok {
		return errors.New("cannot find myself")
	}
	selfConfig.Name = name

	return self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.SetDevice(selfConfig)
	})
}

func (self *Client) Statistics() (*FolderStats, error) {
	globalTotal := FolderCounts{}
	localTotal := FolderCounts{}

	for _, folder := range self.config.FolderList() {
		snap, err := self.app.M.DBSnapshot(folder.ID)
		defer snap.Release()
		if err != nil {
			return nil, err
		}
		globalTotal.add(newFolderCounts(snap.GlobalSize()))
		localTotal.add(newFolderCounts(snap.LocalSize()))
	}

	return &FolderStats{
		Global: &globalTotal,
		Local:  &localTotal,
	}, nil
}

type SearchResultDelegate interface {
	Result(entry *Entry)
	IsCancelled() bool
}

/*
* Search for files by name in the global index. Calls back the delegate up to `maxResults` times with a result in no
particular order, unless/until the delegate returns true from IsCancelled. Set maxResults to <=0 to collect all results.
*/
func (self *Client) Search(text string, delegate SearchResultDelegate, maxResults int) error {
	text = strings.ToLower(text)
	resultCount := 0

	for _, folder := range self.config.FolderList() {
		folderObject := Folder{
			client:   self,
			FolderID: folder.ID,
		}

		snap, err := self.app.M.DBSnapshot(folder.ID)
		if err != nil {
			return err
		}
		defer snap.Release()

		snap.WithGlobal(func(f protocol.FileIntf) bool {
			if delegate.IsCancelled() {
				// This shouild cancel the scan
				return false
			}

			pathParts := strings.Split(f.FileName(), "/")
			fn := strings.ToLower(pathParts[len(pathParts)-1])
			gimmeMore := maxResults <= 0 || resultCount < maxResults

			if gimmeMore && strings.Contains(fn, text) {
				entry := &Entry{
					Folder: &folderObject,
					info:   f.(protocol.FileInfo),
				}

				if err == nil {
					resultCount += 1
					delegate.Result(entry)
				}
			}

			return gimmeMore
		})
	}
	return nil
}

func (self *Client) GetEnoughConnections() int {
	return self.config.Options().ConnectionLimitEnough
}

func (self *Client) SetEnoughConnections(enough int) error {
	return self.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.ConnectionLimitEnough = enough
	})
}

func (self *Client) IsListening() bool {
	return len(self.config.Options().ListenAddresses()) == 0
}

func (self *Client) SetListening(passive bool) error {
	return self.changeConfiguration(func(cfg *config.Configuration) {
		if passive {
			cfg.Options.RawListenAddresses = []string{}
		} else {
			cfg.Options.RawListenAddresses = []string{"default"}
		}
	})
}
