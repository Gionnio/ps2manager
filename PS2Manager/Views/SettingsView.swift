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
	@State private var language = AppLanguage.current
	@State private var askRelaunch = false

	var body: some View {
		Form {
			Section("Appearance") {
				VStack(alignment: .leading, spacing: 4) {
					Picker("Language", selection: Binding(get: { language }, set: { code in
						language = code
						if AppLanguage.set(code) { askRelaunch = true }
					})) {
						Text("System").tag("")
						Text(verbatim: "Italiano").tag("it")
						Text(verbatim: "English").tag("en")
					}
					Text("PS2 Manager restarts to change language.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
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
		.alert("Relaunch PS2 Manager to change the language?", isPresented: $askRelaunch) {
			Button("Relaunch Now") { AppLanguage.relaunch() }
			Button("Later", role: .cancel) {}
		}
		.frame(width: 480)
		.fixedSize(horizontal: false, vertical: true)
	}
}

/// Lingua dell'app: di sistema, italiano o inglese. macOS la legge all'avvio
/// (AppleLanguages nel dominio dell'app), quindi al cambio si chiede di riavviare.
enum AppLanguage {
	/// "" = lingua di sistema, altrimenti "it" o "en".
	static var current: String {
		(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"]
			as? [String])?.first.map { String($0.prefix(2)) } ?? ""
	}

	/// Salva la lingua scelta; true se è cambiata.
	@discardableResult
	static func set(_ code: String) -> Bool {
		guard code != current else { return false }
		if code.isEmpty {
			UserDefaults.standard.removeObject(forKey: "AppleLanguages")
		} else {
			UserDefaults.standard.set([code], forKey: "AppleLanguages")
		}
		return true
	}

	private static var relaunchRequested: Date?
	private static var relaunchObserver: NSObjectProtocol?

	/// Chiude PS2 Manager e lo riapre quando è davvero chiuso, così non ne restano due aperti.
	/// La riapertura parte solo se la chiusura va a buon fine.
	static func relaunch() {
		relaunchRequested = Date()
		if relaunchObserver == nil {
			relaunchObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
				guard let asked = relaunchRequested, Date().timeIntervalSince(asked) < 120 else { return }
				let pid = ProcessInfo.processInfo.processIdentifier
				let task = Process()
				task.executableURL = URL(fileURLWithPath: "/bin/sh")
				task.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
				try? task.run()
			}
		}
		NSApp.terminate(nil)
	}
}
