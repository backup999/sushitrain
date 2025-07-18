// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
@preconcurrency import SushitrainCore
import Photos

let photoFSType: String = "sushitrain.photos.v1"

private class PhotoFS: NSObject {
	private let cacheLock = DispatchSemaphore(value: 1)
	private var cachedRoots: [String: StaticCustomFSDirectory] = [:]
}

enum CustomFSError: Error {
	case notADirectory
	case notAFile
}

enum PhotoFSError: LocalizedError {
	case albumNotFound
	case invalidURI
	case assetUnavailable

	var errorDescription: String? {
		switch self {
		case .albumNotFound:
			return String(localized: "album not found")
		case .invalidURI:
			return String(localized: "invalid configuration")
		case .assetUnavailable:
			return String(localized: "media file is currently unavailable")
		}
	}
}

private class CustomFSEntry: NSObject, SushitrainCustomFileEntryProtocol {
	let entryName: String

	internal init(_ name: String, _ children: [CustomFSEntry]? = nil) {
		self.entryName = name
	}

	func isDir() -> Bool {
		return false
	}

	func name() -> String {
		return self.entryName
	}

	func child(at index: Int) throws -> any SushitrainCustomFileEntryProtocol {
		throw CustomFSError.notADirectory
	}

	func childCount(_ ret: UnsafeMutablePointer<Int>?) throws {
		throw CustomFSError.notADirectory
	}

	func data() throws -> Data {
		throw CustomFSError.notAFile
	}

	func modifiedTime() -> Int64 {
		return 0
	}

	func bytes(_ ret: UnsafeMutablePointer<Int>?) throws {
		throw CustomFSError.notAFile
	}
}

private protocol CustomFSDirectory {
	func getOrCreateSubdirectory(_ name: String) -> CustomFSDirectory
	func place(_ entry: CustomFSEntry)
}

private class StaticCustomFSDirectory: CustomFSEntry {
	var children: [CustomFSEntry]
	let modTime: Date

	init(_ name: String, children: [CustomFSEntry]) {
		self.children = children
		self.modTime = Date()
		super.init(name)
	}

	override func isDir() -> Bool {
		return true
	}

	override func child(at index: Int) throws -> any SushitrainCustomFileEntryProtocol {
		return self.children[index]
	}

	override func childCount(_ ret: UnsafeMutablePointer<Int>?) throws {
		ret?.pointee = self.children.count
	}

	override func modifiedTime() -> Int64 {
		return Int64(self.modTime.timeIntervalSince1970)
	}
}

extension StaticCustomFSDirectory: CustomFSDirectory {
	func getOrCreateSubdirectory(_ name: String) -> CustomFSDirectory {
		if let subDir = children.first(where: { $0.name() == name }) {
			if let subDir = subDir as? CustomFSDirectory {
				return subDir
			}
			else {
				fatalError("Expected a subdirectory, but found something else")
			}
		}
		else {
			// Create
			let subDir = StaticCustomFSDirectory(name, children: [])
			self.children.append(subDir)
			return subDir
		}
	}

	func place(_ entry: CustomFSEntry) {
		self.children.append(entry)
	}
}

private class StaticCustomFSEntry: CustomFSEntry {
	let contents: Data
	let modTime: Date

	init(_ name: String, contents: Data) {
		self.contents = contents
		self.modTime = Date()
		super.init(name, nil)
	}

	override func isDir() -> Bool {
		return false
	}

	override func data() throws -> Data {
		return self.contents
	}

	override func modifiedTime() -> Int64 {
		return Int64(self.modTime.timeIntervalSince1970)
	}
}

private class PhotoFSAssetEntry: CustomFSEntry {
	let asset: PHAsset
	private var cachedSize: Int? = nil

	init(_ name: String, asset: PHAsset) {
		self.asset = asset
		super.init(name)
	}

	override func modifiedTime() -> Int64 {
		return Int64(asset.creationDate?.timeIntervalSince1970 ?? 0.0)
	}

	override func isDir() -> Bool {
		return false
	}

	override func bytes(_ ret: UnsafeMutablePointer<Int>?) throws {
		if let s = self.cachedSize {
			ret?.pointee = s
			return
		}
		let d = try self.data()
		self.cachedSize = d.count
		ret?.pointee = self.cachedSize!
	}

	override func data() throws -> Data {
		let options = PHImageRequestOptions()
		options.isSynchronous = true
		options.resizeMode = .none
		options.deliveryMode = .highQualityFormat
		options.isNetworkAccessAllowed = false
		options.allowSecondaryDegradedImage = false
		options.version = .current

		var exported: Data? = nil
		let start = Date()
		PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
			if let inICloud = info?[PHImageResultIsInCloudKey] as? NSNumber, inICloud.boolValue {
				Log.warn("Asset is in iCloud and therefore ignored: '\(self.asset.localIdentifier)'")
			}
			else if let info = info, let errorMessage = info[PHImageErrorKey] {
				Log.warn("Could not export asset '\(self.asset.localIdentifier)': \(errorMessage) \(info)")
			}
			exported = data
		}
		let duration = Date().timeIntervalSince(start)
		if duration > 1.0 {
			Log.warn(
				"Slow asset export: \(asset.localIdentifier) \(self.modifiedTime()) bytes=\(exported?.count ?? -1) duration=\(duration)"
			)
		}

		if let exported = exported {
			return exported
		}
		throw PhotoFSError.assetUnavailable
	}
}

// File system entry (directory) that represents a single album from the system photo library.
private class PhotoFSAlbumEntry: CustomFSEntry {
	private var children: [CustomFSEntry]? = nil
	private let config: PhotoFSAlbumConfiguration
	private var lastUpdate: Date? = nil
	private var lastChangeCounter = -1

	init(_ name: String, config: PhotoFSAlbumConfiguration) throws {
		self.config = config
		super.init(name)
	}

	override func isDir() -> Bool {
		return true
	}

	// Returns true when listing this directory requires fetching assets from the photo library anew first
	// This is either when we detected a change, or when a time interval has passed (as fallback)
	private var isStale: Bool {
		if self.children == nil || self.lastUpdate == nil
			|| self.lastChangeCounter < PhotoFSLibraryObserver.shared.changeCounter
		{
			return true
		}
		if let d = self.lastUpdate, d.timeIntervalSinceNow < TimeInterval(-60 * 60) {
			return true
		}
		return false
	}

	private func update() throws {
		if self.isStale {
			self.lastChangeCounter = PhotoFSLibraryObserver.shared.changeCounter
			let fetchResult = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [self.config.albumID], options: nil)
			guard let album = fetchResult.firstObject else {
				throw PhotoFSError.albumNotFound
			}

			// Faux directory used to give folderStructure.place a CustomFSDirectory interface for the root directory
			let fauxRoot = StaticCustomFSDirectory("", children: [])
			let structure = self.config.folderStructure ?? .singleFolder

			// Enumerate relevant assets
			let assets = PHAsset.fetchAssets(in: album, options: nil)
			assets.enumerateObjects { asset, index, stop in
				if asset.mediaType == .image {
					structure.place(
						asset: asset, root: fauxRoot, timeZone: self.config.timeZone ?? .specific(timeZone: TimeZone.gmt.identifier))
				}
			}

			self.lastUpdate = Date()
			var childrenList = fauxRoot.children
			Log.info("Enumerated album \(self.config.albumID): \(childrenList.count) assets")
			childrenList.sort { a, b in
				return a.name() < b.name()
			}
			self.children = childrenList
		}
	}

	override func child(at index: Int) throws -> any SushitrainCustomFileEntryProtocol {
		try self.update()
		return self.children![index]
	}

	override func childCount(_ ret: UnsafeMutablePointer<Int>?) throws {
		try self.update()
		ret?.pointee = self.children!.count
	}
}

struct PhotoFSAlbumConfiguration: Codable, Equatable {
	var albumID: String = ""

	// Needs to be optional because older versions did not have this field
	var folderStructure: PhotoBackupFolderStructure? = nil

	var timeZone: PhotoBackupTimeZone? = nil

	var isValid: Bool {
		return !self.albumID.isEmpty
	}
}

struct PhotoFSConfiguration: Codable, Equatable {
	var folders: [String: PhotoFSAlbumConfiguration] = [:]
}

extension PhotoBackupFolderStructure {
	fileprivate func place(asset: PHAsset, root: CustomFSDirectory, timeZone: PhotoBackupTimeZone) {
		let translatedFileName = asset.fileNameInFolder(structure: self)
		let subdirs = asset.subdirectoriesInFolder(structure: self, timeZone: timeZone)

		var dir = root
		for dirName in subdirs {
			dir = dir.getOrCreateSubdirectory(dirName)
		}

		dir.place(PhotoFSAssetEntry(translatedFileName, asset: asset))
	}
}

extension PhotoFS: SushitrainCustomFilesystemTypeProtocol {

	func root(_ uri: String?) throws -> any SushitrainCustomFileEntryProtocol {
		guard let uri = uri else {
			throw PhotoFSError.invalidURI
		}

		// See if we have a root cached for this URI
		do {
			self.cacheLock.wait()
			defer {
				self.cacheLock.signal()
			}
			if let r = self.cachedRoots[uri] {
				return r
			}
		}

		// Attempt to decode URI as JSON containing a configuration struct
		var config = PhotoFSConfiguration()
		if let d = uri.data(using: .utf8) {
			config = (try? JSONDecoder().decode(PhotoFSConfiguration.self, from: d)) ?? config
		}

		let folderRoot = StaticCustomFSDirectory(
			"",
			children: [
				// Folder marker (needs to be present for Syncthing to know the folder is healthy
				StaticCustomFSDirectory(
					".stfolder",
					children: [
						StaticCustomFSEntry(".photofs-marker", contents: "# EMPTY ON PURPOSE\n".data(using: .ascii)!)
					]),

				// Ignore file (empty for now)
				StaticCustomFSEntry(".stignore", contents: "# EMPTY ON PURPOSE\n".data(using: .ascii)!),
			])

		// Go over all configured albums and place them at the right locations in the entry tree
		for (folderPath, albumConfig) in config.folders {
			if folderPath.isEmpty {
				// Must have a path (can't place at root)
				Log.warn("Can't place folder album at root")
				continue
			}

			var subdirs = folderPath.split(separator: "/")
			let first = subdirs.first!
			if first.lowercased().starts(with: ".st") {
				// Can't place anything in .stfolder or over .stignore
				Log.warn("Can't place folder album over reserved subdirectory name: \(folderPath) \(first)")
				continue
			}

			var dir: CustomFSDirectory = folderRoot
			let lastDirName = String(subdirs.removeLast())
			for subdir in subdirs {
				dir = dir.getOrCreateSubdirectory(String(subdir))
			}

			let albumDirectory = try PhotoFSAlbumEntry(lastDirName, config: albumConfig)
			dir.place(albumDirectory)
		}

		// Cache root
		do {
			self.cacheLock.wait()
			defer {
				self.cacheLock.signal()
			}
			self.cachedRoots[uri] = folderRoot
		}

		return folderRoot
	}
}

private final class PhotoFSLibraryObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
	nonisolated(unsafe) var changeCounter: Int = 0
	private let lock = DispatchSemaphore(value: 1)

	static let shared = PhotoFSLibraryObserver()

	func photoLibraryDidChange(_ changeInstance: PHChange) {
		Log.info("Photo library did change: \(changeInstance) \(self.changeCounter)")
		self.lock.wait()
		defer { self.lock.signal() }
		self.changeCounter += 1
	}
}

func registerPhotoFilesystem() {
	SushitrainRegisterCustomFilesystemType(photoFSType, PhotoFS())
	PHPhotoLibrary.shared().register(PhotoFSLibraryObserver.shared)
}
