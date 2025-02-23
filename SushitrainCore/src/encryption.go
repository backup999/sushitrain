// Copyright (C) 2025 Tommy van der Vorst
// Copyright (C) 2014 The Syncthing Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"encoding/base32"
	"strings"

	"github.com/miscreant/miscreant.go"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	keySize               = 32 // fits both chacha20poly1305 and AES-SIV
	miscreantAlgo         = "AES-SIV"
	maxPathComponent      = 200              // characters
	encryptedDirExtension = ".syncthing-enc" // for top level dirs
)

var base32Hex = base32.HexEncoding.WithPadding(base32.NoPadding)

// encryptDeterministic encrypts bytes using AES-SIV
func encryptDeterministic(data []byte, key *[keySize]byte, additionalData []byte) []byte {
	aead, err := miscreant.NewAEAD(miscreantAlgo, key[:], 0)
	if err != nil {
		panic("cipher failure: " + err.Error())
	}
	return aead.Seal(nil, nil, data, additionalData)
}

// slashify inserts slashes (and file extension) in the string to create an
// appropriate tree. ABCDEFGH... => A.syncthing-enc/BC/DEFGH... We can use
// forward slashes here because we're on the outside of native path formats,
// the slash is the wire format.
func slashify(s string) string {
	// We somewhat sloppily assume bytes == characters here, but the only
	// file names we should deal with are those that come from our base32
	// encoding.

	comps := make([]string, 0, len(s)/maxPathComponent+3)
	comps = append(comps, s[:1]+encryptedDirExtension)
	s = s[1:]
	comps = append(comps, s[:2])
	s = s[2:]

	for len(s) > maxPathComponent {
		comps = append(comps, s[:maxPathComponent])
		s = s[maxPathComponent:]
	}
	if len(s) > 0 {
		comps = append(comps, s)
	}
	return strings.Join(comps, "/")
}

func (folder *Folder) folderKey(password string) *[keySize]byte {
	keyGen := protocol.NewKeyGenerator()
	return keyGen.KeyFromPassword(folder.FolderID, password)
}

func (entry *Entry) EncryptedFilePath(folderPassword string) string {
	key := entry.Folder.folderKey(folderPassword)
	enc := encryptDeterministic([]byte(entry.info.Name), key, nil)
	return slashify(base32Hex.EncodeToString(enc))
}

func (entry *Entry) FileKeyBase32(password string) string {
	folderKey := entry.Folder.folderKey(password)
	keyGen := protocol.NewKeyGenerator()
	fileKey := keyGen.FileKey(entry.info.Name, folderKey)
	return base32Hex.EncodeToString(fileKey[:])
}
