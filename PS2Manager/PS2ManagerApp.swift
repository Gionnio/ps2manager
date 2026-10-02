import SwiftUI

@main
struct PS2ManagerApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@StateObject private var library: Library
	@AppStorage(SettingsKey.theme) private var theme = AppTheme.system

	init() {
		SettingsKey.registerDefaults()
		let library = Library()
		_library = StateObject(wrappedValue: library)
		AppDelegate.library = library
	}

	var body: some Scene {
		Window("PS2 Manager", id: "main") {
			ContentView()
				.environmentObject(library)
				.preferredColorScheme(theme.colorScheme)
		}
		.defaultSize(width: 1000, height: 680)
		.commands {
			CommandGroup(replacing: .appInfo) {
				Button("About PS2 Manager") { AboutWindow.show() }
			}
			CommandGroup(replacing: .newItem) {
				Button("Open Drive…") { library.chooseDrive() }
					.keyboardShortcut("o")
				Button("Show Drive in Finder") { library.revealDrive() }
					.keyboardShortcut("o", modifiers: [.command, .shift])
					.disabled(library.layout == nil)
			}
			CommandMenu("Games") {
				Button("Refresh") { library.refresh() }
					.keyboardShortcut("r")
					.disabled(library.layout == nil)
				Divider()
				Button("Download All Covers") { library.downloadAllCovers() }
					.disabled(library.layout == nil)
				Button("Defragment All PS2 Games") { library.defragAll() }
					.disabled(library.layout == nil)
				Divider()
				Button("Cancel Current Operation") { library.cancelCurrentJob() }
					.keyboardShortcut(".")
					.disabled(!library.isBusy)
			}
		}

		Settings {
			SettingsView()
				.preferredColorScheme(theme.colorScheme)
		}
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	static weak var library: Library?

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	/// File trascinati sull'icona nel Dock o aperti con "Apri con": stesso comportamento del trascinamento nella finestra.
	func application(_ application: NSApplication, open urls: [URL]) {
		Task { @MainActor in Self.library?.handleDrop(urls) }
	}
}
