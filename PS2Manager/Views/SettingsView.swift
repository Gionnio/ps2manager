import SwiftUI

struct SettingsView: View {
	@AppStorage(SettingsKey.theme) private var theme = AppTheme.system
	@AppStorage(SettingsKey.loaderMode) private var loaderMode = LoaderMode.usb
	@AppStorage(SettingsKey.reopenLastDrive) private var reopenLastDrive = true
	@AppStorage(SettingsKey.showCovers) private var showCovers = true
	@AppStorage(SettingsKey.autoDownloadCovers) private var autoDownloadCovers = true
	@AppStorage(SettingsKey.confirmDeletion) private var confirmDeletion = true
	@AppStorage(SettingsKey.readSerialsFromImages) private var readSerials = true
	@ObservedObject private var assets = UserAssets.shared

	var body: some View {
		Form {
			Section("Appearance") {
				Picker("Theme", selection: $theme) {
					ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
				}
				.pickerStyle(.segmented)
				Toggle(isOn: $showCovers) {
					Text("Show covers in the list")
					Text("Small cover thumbnails next to each game.")
				}
			}

			Section("Drive") {
				Picker(selection: $loaderMode) {
					ForEach(LoaderMode.allCases) { Text($0.rawValue).tag($0) }
				} label: {
					Text("Open PS2 Loader mode")
					Text("Sets the POPStarter launcher prefix for new PS1 games: XX. for USB, SB. for SMB.")
				}
				Toggle(isOn: $reopenLastDrive) {
					Text("Reopen the last drive at launch")
					Text("If it is still connected.")
				}
				Toggle(isOn: $readSerials) {
					Text("Read the game ID from the images")
					Text("More accurate titles; turn it off if the list is slow on network shares.")
				}
			}

			Section {
				LabeledContent {
					HStack {
						if assets.hasPOPStarter {
							Button("Remove", role: .destructive) { assets.removePOPStarter() }
						}
						Button(assets.hasPOPStarter ? "Replace…" : "Import…") { assets.chooseAndImportPOPStarter() }
					}
				} label: {
					Label {
						Text("POPSTARTER.ELF")
						Text(assets.hasPOPStarter ? "Imported" : "Not imported: needed to install PS1 games.")
					} icon: {
						Image(systemName: assets.hasPOPStarter ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
							.foregroundStyle(assets.hasPOPStarter ? .green : .orange)
					}
				}
				LabeledContent {
					HStack {
						if !assets.patchPacks.isEmpty {
							Button("Remove", role: .destructive) { assets.removePatches() }
						}
						Button(assets.patchPacks.isEmpty ? "Import…" : "Replace…") { assets.chooseAndImportPatches() }
					}
				} label: {
					Label {
						Text("POPS patch archive")
						Text(assets.patchPacks.isEmpty ? "Not imported (optional)." : "\(assets.patchPacks.count) patches imported")
					} icon: {
						Image(systemName: assets.patchPacks.isEmpty ? "circle.dashed" : "checkmark.circle.fill")
							.foregroundStyle(assets.patchPacks.isEmpty ? Color.secondary : .green)
					}
				}
				Button("Show in Finder", systemImage: "folder") { assets.revealFolder() }
					.buttonStyle(.link)
			} header: {
				Text("Third-party files")
			} footer: {
				Text("PS2 Manager does not include POPStarter or POPS patches. Import your own copies: they are kept in ~/Library/Application Support/PS2 Manager.")
					.font(.caption).foregroundStyle(.secondary)
			}

			Section("Games") {
				Toggle(isOn: $autoDownloadCovers) {
					Text("Download the cover after installing")
					Text("Fetches the cover from the xlenore repositories on GitHub.")
				}
				Toggle(isOn: $confirmDeletion) {
					Text("Ask before deleting a game")
					Text("Deleting also removes cover, configuration, cheats and patches.")
				}
			}
		}
		.formStyle(.grouped)
		.frame(width: 480)
		.fixedSize(horizontal: false, vertical: true)
	}
}
