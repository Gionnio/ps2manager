import SwiftUI

/// Configurazione di un gioco: seriale e copertina, modalità di compatibilità OPL, cheat (PS2), patch POPS (PS1) e VMC.
struct GameConfigView: View {
	@EnvironmentObject private var library: Library
	@Environment(\.dismiss) private var dismiss
	let game: Game

	@State private var serial = ""
	@State private var vmc = ""
	@State private var compatModes = Array(repeating: false, count: 6)
	@State private var config: [String: String] = [:]
	@State private var hasCheats = false
	@State private var activePatches: [String] = []
	@State private var downloading = false
	@State private var showingArchive = false
	@State private var dropTargeted = false

	private static let modeHints: [LocalizedStringKey] = [
		"Accurate reads", "Synchronous mode", "Unhook syscalls", "Skip videos", "Emulate DVD-DL", "Disable IGR",
	]

	private var layout: DriveLayout? { library.layout }
	private var cleanSerial: String { serial.trimmingCharacters(in: .whitespaces).uppercased() }

	var body: some View {
		VStack(spacing: 0) {
			HStack(alignment: .top, spacing: 20) {
				coverColumn
				Form {
					if game.platform == .ps2 {
						compatibilitySection
						cheatSection
					} else {
						patchSection
					}
					Section("Virtual Memory Card") {
						TextField("VMC", text: $vmc, prompt: Text("e.g. GENERIC_0"))
						Text("Name of the VMC file in the VMC folder to use for this game.")
							.font(.caption).foregroundStyle(.secondary)
					}
				}
				.formStyle(.grouped)
			}
			.padding([.top, .horizontal], 20)
			Divider()
			HStack {
				Text(game.filename).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Save") { save() }
					.keyboardShortcut(.defaultAction)
					.disabled(cleanSerial.isEmpty)
			}
			.padding(14)
		}
		.frame(width: 680, height: 620)
		.overlay {
			if dropTargeted {
				RoundedRectangle(cornerRadius: 12)
					.strokeBorder(Color.accentColor, lineWidth: 3)
					.background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
					.padding(6)
					.allowsHitTesting(false)
			}
		}
		.dropDestination(for: URL.self) { urls, _ in
			handleDrop(urls)
			return true
		} isTargeted: { dropTargeted = $0 }
		.sheet(isPresented: $showingArchive, onDismiss: reloadPatches) {
			PatchArchiveView(game: game)
				.environmentObject(library)
		}
		.onAppear(perform: load)
	}

	// MARK: - Sezioni

	private var coverColumn: some View {
		VStack(spacing: 12) {
			Text(game.title).font(.title3.bold()).multilineTextAlignment(.center).lineLimit(3)
			CoverThumbnail(url: layout.map { $0.coverURL(serial: cleanSerial) }, platform: game.platform, revision: library.coverRevision)
				.frame(width: 160, height: 224)
			TextField("Serial", text: $serial, prompt: Text("Serial"))
				.textFieldStyle(.roundedBorder)
				.multilineTextAlignment(.center)
				.font(.body.monospaced())
			Button {
				downloading = true
				Task {
					_ = await library.downloadCover(serial: cleanSerial, platform: game.platform)
					downloading = false
				}
			} label: {
				Label("Download Cover", systemImage: "arrow.down.circle")
					.frame(maxWidth: .infinity)
			}
			.disabled(cleanSerial.isEmpty || downloading)
			if downloading { ProgressView().controlSize(.small) }
			Spacer()
		}
		.frame(width: 190)
	}

	private var compatibilitySection: some View {
		Section("Compatibility") {
			ForEach(0..<6, id: \.self) { index in
				Toggle(isOn: $compatModes[index]) {
					Text("Mode \(index + 1)")
					Text(Self.modeHints[index])
				}
			}
		}
	}

	private var cheatSection: some View {
		Section("Cheats") {
			Label(hasCheats ? "Cheat file present" : "No cheat file", systemImage: hasCheats ? "checkmark.circle.fill" : "circle.dashed")
				.foregroundStyle(hasCheats ? .green : .secondary)
			Text("Drag a .cht or .txt file onto this window to install it.")
				.font(.caption).foregroundStyle(.secondary)
		}
	}

	private var patchSection: some View {
		Section("POPS Patches") {
			Button("Open Patch Archive…", systemImage: "shippingbox") { showingArchive = true }
			if activePatches.isEmpty {
				Text("No active patches").foregroundStyle(.secondary)
			} else {
				ForEach(activePatches, id: \.self) { file in
					HStack {
						Label(file, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
						Spacer()
						Button("Remove", systemImage: "trash") { removePatch(file) }
							.labelStyle(.iconOnly)
							.buttonStyle(.borderless)
							.foregroundStyle(.red)
					}
				}
			}
			Text("Drag TROJAN_x.BIN or PATCH_x.BIN files onto this window to install them manually.")
				.font(.caption).foregroundStyle(.secondary)
		}
	}

	// MARK: - Dati

	private func load() {
		serial = game.serial ?? ""
		guard let layout else { return }
		if let id = game.serial {
			config = OPLConfig.read(layout.configURL(serial: id))
			hasCheats = FileManager.default.fileExists(atPath: layout.cheatURL(serial: id).path)
		}
		vmc = config["$VMC_0"] ?? ""
		compatModes = (1...6).map { config["$CompatMode_\($0)"] == "1" }
		reloadPatches()
	}

	private func reloadPatches() {
		guard let layout, game.platform == .ps1 else { return }
		let files = (try? FileManager.default.contentsOfDirectory(atPath: layout.patchFolder(for: game).path)) ?? []
		activePatches = files.filter(PatchPack.isPatchFile).sorted()
	}

	private func removePatch(_ file: String) {
		guard let layout else { return }
		try? FileManager.default.removeItem(at: layout.patchFolder(for: game).appendingPathComponent(file))
		reloadPatches()
	}

	private func handleDrop(_ urls: [URL]) {
		guard let layout else { return }
		do {
			if game.platform == .ps1 {
				let patches = urls.filter { PatchPack.isPatchFile($0.lastPathComponent) }
				guard !patches.isEmpty else { return }
				let folder = layout.patchFolder(for: game)
				try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
				for url in patches {
					try DiscTools.atomicCopy(from: url, to: folder.appendingPathComponent(url.lastPathComponent.uppercased()))
				}
				reloadPatches()
				library.setStatus(String(localized: "Patches installed: \(patches.count)"), .success)
			} else {
				guard !cleanSerial.isEmpty, let cheat = urls.first(where: { ["cht", "txt"].contains($0.pathExtension.lowercased()) }) else { return }
				try FileManager.default.createDirectory(at: layout.cht, withIntermediateDirectories: true)
				try DiscTools.atomicCopy(from: cheat, to: layout.cheatURL(serial: cleanSerial))
				hasCheats = true
				library.setStatus(String(localized: "Cheats installed."), .success)
			}
		} catch {
			library.setStatus(String(localized: "Error: \(error.localizedDescription)"), .error)
		}
	}

	private func save() {
		guard let layout, !cleanSerial.isEmpty else { return }
		var map = config
		map["Title"] = game.title
		map["$VMC_0"] = vmc.trimmingCharacters(in: .whitespaces)
		if game.platform == .ps2 {
			for (index, enabled) in compatModes.enumerated() {
				map["$CompatMode_\(index + 1)"] = enabled ? "1" : nil
			}
		}
		do {
			try OPLConfig.write(map, to: layout.configURL(serial: cleanSerial))
			library.setStatus(String(localized: "Configuration saved."), .success)
			dismiss()
		} catch {
			library.setStatus(String(localized: "Error: \(error.localizedDescription)"), .error)
		}
	}
}

/// Archivio delle patch POPS importate dall'utente: cerca per nome del gioco e installa/rimuove con un clic.
struct PatchArchiveView: View {
	@EnvironmentObject private var library: Library
	@ObservedObject private var assets = UserAssets.shared
	@Environment(\.dismiss) private var dismiss
	let game: Game

	@State private var query = ""
	@State private var installed: Set<String> = []

	private var folder: URL? { library.layout?.patchFolder(for: game) }
	private var packs: [PatchPack] {
		let q = query.trimmingCharacters(in: .whitespaces).lowercased()
		return q.isEmpty ? assets.patchPacks : assets.patchPacks.filter { $0.name.lowercased().contains(q) }
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
				TextField("Search patches", text: $query)
					.textFieldStyle(.plain)
				if !query.isEmpty {
					Button("Show Entire Archive") { query = "" }
						.buttonStyle(.link)
				}
			}
			.padding(12)
			Divider()
			if assets.patchPacks.isEmpty {
				ContentUnavailableView {
					Label("No patch archive", systemImage: "shippingbox")
				} description: {
					Text("No POPS patches have been imported yet. Choose a folder with your patches (subfolders containing TROJAN_x.BIN or PATCH_x.BIN files).")
				} actions: {
					Button("Import Patch Folder…") {
						assets.chooseAndImportPatches()
						refreshInstalled()
					}
				}
				.frame(maxHeight: .infinity)
			} else if packs.isEmpty {
				ContentUnavailableView("No patches found", systemImage: "shippingbox",
				                       description: Text("Try “Show Entire Archive”."))
					.frame(maxHeight: .infinity)
			} else {
				List(packs) { pack in
					Toggle(isOn: binding(for: pack)) {
						Text(pack.name)
						Text(pack.binFiles.joined(separator: ", "))
					}
					.toggleStyle(.checkbox)
				}
				.listStyle(.inset)
			}
			Divider()
			HStack {
				Text("\(packs.count) patches").font(.caption).foregroundStyle(.secondary)
				Spacer()
				Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
			}
			.padding(12)
		}
		.frame(width: 560, height: 480)
		.navigationTitle(Text("Patch Manager: \(game.title)"))
		.onAppear {
			query = game.title.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? ""
			refreshInstalled()
		}
	}

	private func refreshInstalled() {
		guard let folder else { return }
		installed = Set(assets.patchPacks.filter { $0.isInstalled(in: folder) }.map(\.id))
	}

	private func binding(for pack: PatchPack) -> Binding<Bool> {
		Binding {
			installed.contains(pack.id)
		} set: { enabled in
			guard let folder else { return }
			if enabled {
				do {
					let count = try pack.install(in: folder)
					installed.insert(pack.id)
					library.setStatus(String(localized: "Installed: \(pack.name) (\(count) files)"), .success)
				} catch {
					library.setStatus(String(localized: "Error: \(error.localizedDescription)"), .error)
				}
			} else {
				let count = pack.uninstall(from: folder)
				installed.remove(pack.id)
				library.setStatus(String(localized: "Removed: \(pack.name) (\(count) files)"), .success)
			}
		}
	}
}
