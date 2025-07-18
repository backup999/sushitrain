// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import QuickLook

struct ExtraFilesView: View {
	var folder: SushitrainFolder
	@Environment(AppState.self) private var appState
	@State private var extraFiles: [String] = []
	@Environment(\.dismiss) private var dismiss
	@State private var verdicts: [String: Bool] = [:]
	@State private var localItemURL: URL? = nil
	@State private var allVerdict: Bool? = nil
	@State private var errorMessage: String? = nil

	var body: some View {
		Group {
			if extraFiles.isEmpty {
				ContentUnavailableView("No extra files found", systemImage: "checkmark.circle")
			}
			else {
				List {
					Section {
						if folder.folderType() == SushitrainFolderTypeSendReceive {
							Text("Extra files have been found. Please decide for each file whether they should be synchronized or removed.")
								.textFieldStyle(.plain)
						}
						else if folder.folderType() == SushitrainFolderTypeReceiveOnly {
							Text("Extra files have been found. Because this is a receive-only folder, these files will not be synchronized.")
								.textFieldStyle(.plain)
						}
					}

					Section {
						HStack {
							VStack(alignment: .leading) { Text("For all files").multilineTextAlignment(.leading) }.frame(
								maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

							Picker(
								"Action",
								selection: Binding(
									get: { return allVerdict },
									set: { s in
										allVerdict = s
										for f in extraFiles { verdicts[f] = s }
									})
							) {
								Image(systemName: "trash").tint(.red).tag(false).accessibilityLabel("Delete file")
								if folder.folderType() == SushitrainFolderTypeReceiveOnly {
									Image(systemName: "trash.slash").tag(true).accessibilityLabel("Keep file")
								}
								else {
									Image(systemName: "plus.square.fill").tag(true).accessibilityLabel("Keep file")
								}
							}.pickerStyle(.segmented).frame(width: 100)
						}
					}

					Section {
						ForEach(extraFiles, id: \.self) { path in
							let verdict = verdicts[path]
							let globalEntry = try? folder.getFileInformation(path)

							HStack {
								VStack(alignment: .leading) {
									Text(path).multilineTextAlignment(.leading).dynamicTypeSize(.small).foregroundStyle(
										verdict == false ? .red : verdict == true ? .green : .primary
									).onTapGesture {
										if let folderNativePath = folder.localNativeURL { self.localItemURL = folderNativePath.appending(path: path) }
									}.disabled(folder.localNativeURL == nil)
								}.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

								Picker(
									"Action",
									selection: Binding(
										get: { return verdicts[path] },
										set: { s in
											verdicts[path] = s
											allVerdict = nil
										})
								) {
									Image(systemName: "trash").tint(.red).tag(false).accessibilityLabel("Delete file")
									if folder.folderType() == SushitrainFolderTypeReceiveOnly {
										Image(systemName: "trash.slash").tag(true).accessibilityLabel("Keep file")
									}
									else {
										if let ge = globalEntry, !ge.isDeleted() {
											Image(systemName: "rectangle.2.swap").tag(true).accessibilityLabel("Replace existing file")
										}
										else {
											Image(systemName: "plus.square.fill").tag(true).accessibilityLabel("Keep file")
										}
									}
								}.pickerStyle(.segmented).frame(width: 100)
							}
						}
					}
				}
			}
		}
		.task { await reload() }
		.navigationTitle("Extra files in folder \(folder.label())")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.toolbar {
			ToolbarItem(
				placement: .confirmationAction,
				content: {
					Button("Apply") { Task { await self.apply() } }.disabled(
						!folder.isIdleOrSyncing || verdicts.isEmpty || extraFiles.isEmpty)
				})
		}.quickLookPreview(self.$localItemURL).alert(isPresented: Binding.constant(errorMessage != nil)) {
			Alert(
				title: Text("An error occurred"), message: Text(errorMessage ?? ""),
				dismissButton: .default(Text("OK")) { errorMessage = nil })
		}
	}
	private func apply() async {
		do {
			let json = try JSONEncoder().encode(self.verdicts)
			try folder.setExplicitlySelectedJSON(json)
			verdicts = [:]
			allVerdict = nil
			dismiss()
		}
		catch {
			errorMessage = error.localizedDescription
			Task { await reload() }
		}
	}

	private func reload() async {
		if folder.isIdleOrSyncing {
			extraFiles = await Task.detached { return (try? folder.extraneousFiles().asArray().sorted()) ?? [] }.value
		}
		else {
			extraFiles = []
		}
	}
}
