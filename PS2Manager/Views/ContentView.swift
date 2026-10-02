import SwiftUI

struct ContentView: View {
	@EnvironmentObject private var library: Library
	@AppStorage(SettingsKey.loaderMode) private var loaderMode = LoaderMode.usb
	@AppStorage("selectedPlatform") private var platform: Platform = .ps2
	@State private var search = ""
	@State private var isDropTargeted = false
	@State private var configuring: Game?

	private var games: [Game] {
		let list = platform == .ps2 ? library.ps2Games : library.ps1Games
		guard !search.isEmpty else { return list }
		return list.filter {
			$0.title.localizedCaseInsensitiveContains(search) || $0.filename.localizedCaseInsensitiveContains(search)
				|| ($0.serial?.localizedCaseInsensitiveContains(search) ?? false)
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			if let layout = library.layout {
				DriveBar(root: layout.root)
				Divider()
				gameList
			} else {
				WelcomeView()
			}
			Divider()
			StatusBar()
		}
		.frame(minWidth: 760, minHeight: 520)
		.overlay { dropHighlight }
		.dropDestination(for: URL.self) { urls, _ in
			library.handleDrop(urls)
			return true
		} isTargeted: { isDropTargeted = $0 }
		.toolbar { toolbar }
		.searchable(text: $search, placement: .toolbar, prompt: Text("Search games"))
		.sheet(item: $configuring) { game in
			GameConfigView(game: game)
				.environmentObject(library)
		}
	}

	@ViewBuilder
	private var gameList: some View {
		if games.isEmpty {
			ContentUnavailableView {
				Label(search.isEmpty ? "No games" : "No results", systemImage: platform == .ps2 ? "opticaldisc" : "playstation.logo")
			} description: {
				Text(search.isEmpty ? (platform == .ps2 ? "Drag .iso files here to install them." : "Drag .cue or .bin files here to convert and install them.") : "Try a different search.")
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else {
			List(games) { game in
				GameRow(game: game, onConfigure: { configuring = game })
					.contextMenu { actions(for: game) }
			}
			.listStyle(.inset(alternatesRowBackgrounds: true))
		}
	}

	@ViewBuilder
	private func actions(for game: Game) -> some View {
		Button("Configure…", systemImage: "gearshape") { configuring = game }
		if game.platform == .ps2 {
			Button("Rename to OPL Format", systemImage: "pencil") { library.rename(game) }
		} else if let disc = game.discInfo, !disc.isStandard {
			Button("Rename to “Name (Disc N)”", systemImage: "pencil") { library.standardizeDiscNames(game) }
		}
		Button(game.platform == .ps2 ? "Export ISO…" : "Export as BIN/CUE…", systemImage: "square.and.arrow.up") { library.export(game) }
		if game.platform == .ps2 {
			Button("Defragment", systemImage: "arrow.triangle.2.circlepath") { library.defrag(game) }
		}
		Divider()
		Button("Delete", systemImage: "trash", role: .destructive) { library.delete(game) }
	}

	@ToolbarContentBuilder
	private var toolbar: some ToolbarContent {
		ToolbarItem(placement: .navigation) {
			Picker("Platform", selection: $platform) {
				Text("PS2 (\(library.ps2Games.count))").tag(Platform.ps2)
				Text("PS1 (\(library.ps1Games.count))").tag(Platform.ps1)
			}
			.pickerStyle(.segmented)
			.disabled(library.layout == nil)
			.help("PS2 games in DVD/, PS1 games in POPS/")
		}
		ToolbarItemGroup {
			Picker("Mode", selection: $loaderMode) {
				ForEach(LoaderMode.allCases) { Text($0.rawValue).tag($0) }
			}
			.pickerStyle(.menu)
			.fixedSize()
			.help("OPL mode: USB uses the XX. prefix for POPStarter, SMB uses SB.")
			Button("Open Drive", systemImage: "externaldrive.badge.plus") { library.chooseDrive() }
				.help("Choose the USB drive or SMB share")
			Button("Refresh", systemImage: "arrow.clockwise") { library.refresh() }
				.disabled(library.layout == nil)
			Menu("Tools", systemImage: "wrench.and.screwdriver") {
				Button("Download All Covers", systemImage: "photo.on.rectangle.angled") { library.downloadAllCovers() }
				Button("Defragment All PS2 Games", systemImage: "arrow.triangle.2.circlepath") { library.defragAll() }
			}
			.disabled(library.layout == nil)
			.help("Global tools")
		}
	}

	@ViewBuilder
	private var dropHighlight: some View {
		if isDropTargeted {
			RoundedRectangle(cornerRadius: 12)
				.strokeBorder(Color.accentColor, lineWidth: 3)
				.background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
				.overlay {
					Label("Drop to install", systemImage: "square.and.arrow.down.fill")
						.font(.title2.weight(.semibold))
						.padding(.horizontal, 20).padding(.vertical, 12)
						.background(.thinMaterial, in: Capsule())
				}
				.padding(8)
				.allowsHitTesting(false)
		}
	}
}

private struct DriveBar: View {
	@EnvironmentObject private var library: Library
	@AppStorage(SettingsKey.loaderMode) private var loaderMode = LoaderMode.usb
	let root: URL

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: loaderMode == .smb ? "network" : "externaldrive.fill")
				.font(.title3)
				.foregroundStyle(Color.accentColor)
			VStack(alignment: .leading, spacing: 1) {
				Text(FileManager.default.displayName(atPath: root.path)).font(.headline)
				Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
			}
			Button("Show in Finder", systemImage: "folder") { library.revealDrive() }
				.labelStyle(.iconOnly)
				.buttonStyle(.borderless)
				.help("Show in Finder")
			Spacer()
			if library.isScanning { ProgressView().controlSize(.small) }
			Badge(text: loaderMode.rawValue, color: .blue)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
	}
}

private struct WelcomeView: View {
	@EnvironmentObject private var library: Library

	var body: some View {
		VStack(spacing: 14) {
			Image(nsImage: NSApp.applicationIconImage)
				.resizable().frame(width: 96, height: 96)
			Text("PS2 Manager").font(.largeTitle.bold())
			Text("Manage the PS2 and PS1 games on your Open PS2 Loader drive.\nChoose the drive, then drag .iso, .cue or .bin files into the window.")
				.multilineTextAlignment(.center)
				.foregroundStyle(.secondary)
			Button("Open Drive…", systemImage: "externaldrive.badge.plus") { library.chooseDrive() }
				.controlSize(.large)
				.buttonStyle(.borderedProminent)
		}
		.padding(40)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

private struct StatusBar: View {
	@EnvironmentObject private var library: Library

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: library.statusKind.symbol)
				.foregroundStyle(library.statusKind.color)
			Text(library.status)
				.font(.callout)
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer()
			if library.queuedJobs > 0 {
				Badge(text: String(localized: "\(library.queuedJobs) queued"), color: .orange)
			}
			if library.isBusy {
				if let progress = library.progress {
					ProgressView(value: progress).frame(width: 160)
					Text(progress, format: .percent.precision(.fractionLength(0)))
						.font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
				} else {
					ProgressView().controlSize(.small)
				}
				Button("Cancel", systemImage: "xmark.circle.fill") { library.cancelCurrentJob() }
					.labelStyle(.iconOnly)
					.buttonStyle(.borderless)
					.help("Cancel the current operation")
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 7)
		.background(.bar)
	}
}

struct Badge: View {
	let text: String
	let color: Color

	var body: some View {
		Text(text)
			.font(.caption.weight(.semibold))
			.foregroundStyle(color)
			.padding(.horizontal, 7)
			.padding(.vertical, 2)
			.background(color.opacity(0.18), in: Capsule())
	}
}
