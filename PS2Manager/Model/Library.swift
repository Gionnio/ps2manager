import AppKit
import SwiftUI

/// Stato dell'app: unità aperta, elenchi dei giochi e coda delle operazioni (eseguite una alla volta).
@MainActor
final class Library: ObservableObject {
	@Published private(set) var layout: DriveLayout?
	@Published private(set) var ps2Games: [Game] = []
	@Published private(set) var ps1Games: [Game] = []
	@Published private(set) var isScanning = false

	@Published private(set) var status: String = String(localized: "Choose a drive to get started.")
	@Published private(set) var statusKind: StatusKind = .info
	@Published private(set) var progress: Double?
	@Published private(set) var isBusy = false
	@Published private(set) var queuedJobs = 0
	/// Incrementato quando cambiano le copertine, per ricaricare le miniature.
	@Published private(set) var coverRevision = 0

	private var tail: Task<Void, Never>?
	private var currentJob: Task<Void, Error>?
	private var defaults: UserDefaults { .standard }

	var loaderMode: LoaderMode {
		LoaderMode(rawValue: defaults.string(forKey: SettingsKey.loaderMode) ?? "") ?? .usb
	}

	init() {
		if defaults.bool(forKey: SettingsKey.reopenLastDrive), let path = defaults.string(forKey: SettingsKey.lastDrivePath),
		   FileManager.default.fileExists(atPath: path) {
			open(drive: URL(fileURLWithPath: path))
		}
	}

	// MARK: - Stato

	func setStatus(_ text: String, _ kind: StatusKind = .info) {
		status = text
		statusKind = kind
	}

	/// Accoda un'operazione: le operazioni sui file girano una alla volta e condividono la barra di avanzamento.
	func enqueue(_ title: String, _ work: @escaping @MainActor () async throws -> Void) {
		let previous = tail
		queuedJobs += 1
		tail = Task {
			await previous?.value
			queuedJobs -= 1
			isBusy = true
			progress = nil
			setStatus(title)
			let job = Task { try await work() }
			currentJob = job
			do {
				try await job.value
			} catch is CancellationError {
				setStatus(String(localized: "Operation cancelled."), .warning)
			} catch {
				setStatus(String(localized: "Error: \(error.localizedDescription)"), .error)
			}
			currentJob = nil
			progress = nil
			isBusy = false
		}
	}

	func cancelCurrentJob() {
		currentJob?.cancel()
	}

	/// Esegue lavoro pesante fuori dal thread principale, aggiornando la barra di avanzamento.
	private func background<T: Sendable>(_ body: @escaping @Sendable (@escaping DiscTools.Progress) throws -> T) async throws -> T {
		progress = 0
		let report: DiscTools.Progress = { [weak self] value in
			Task { @MainActor in self?.progress = value }
		}
		let task = Task.detached(priority: .userInitiated) { try body(report) }
		return try await withTaskCancellationHandler {
			try await task.value
		} onCancel: {
			task.cancel()
		}
	}

	// MARK: - Unità

	func chooseDrive() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.prompt = String(localized: "Open")
		panel.message = String(localized: "Choose the root of the USB drive or SMB share used by Open PS2 Loader.")
		if panel.runModal() == .OK, let url = panel.url {
			open(drive: url)
		}
	}

	func open(drive url: URL) {
		let layout = DriveLayout(root: url)
		layout.createFolders()
		self.layout = layout
		defaults.set(url.path, forKey: SettingsKey.lastDrivePath)
		refresh()
	}

	func revealDrive() {
		if let root = layout?.root { NSWorkspace.shared.open(root) }
	}

	func refresh() {
		guard let layout else { return }

		isScanning = true
		let readSerials = defaults.bool(forKey: SettingsKey.readSerialsFromImages)
		Task {
			let (ps2, ps1) = await Task.detached { Self.scan(layout, readSerials: readSerials) }.value
			ps2Games = ps2
			ps1Games = ps1
			coverRevision += 1
			isScanning = false
			if !isBusy {
				setStatus(String(localized: "PS2 games: \(ps2.count) · PS1 games: \(ps1.count)"), .success)
			}
		}
	}

	nonisolated private static func scan(_ layout: DriveLayout, readSerials: Bool) -> ([Game], [Game]) {
		let fm = FileManager.default
		func files(_ dir: URL, ext: String) -> [URL] {
			let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
			return items.filter { !$0.lastPathComponent.hasPrefix("._") && $0.pathExtension.lowercased() == ext }
		}
		func size(_ url: URL) -> Int64 {
			Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
		}
		func serial(_ url: URL) -> String? {
			(readSerials ? DiscTools.serial(inFileAt: url) : nil) ?? DiscTools.serial(inFilename: url.lastPathComponent)
		}

		let ps2 = files(layout.dvd, ext: "iso").map { url -> Game in
			let id = serial(url)
			let title = id.flatMap(GameDatabase.title(forSerial:)) ?? url.deletingPathExtension().lastPathComponent
			return Game(platform: .ps2, filename: url.lastPathComponent, serial: id, title: title, size: size(url), missingDisc: false)
		}

		let vcds = files(layout.pops, ext: "vcd")
		var discCount: [String: Int] = [:]
		for url in vcds {
			if let info = DriveLayout.discInfo(url.deletingPathExtension().lastPathComponent) { discCount[info.key, default: 0] += 1 }
		}
		let ps1 = vcds.map { url -> Game in
			let name = url.deletingPathExtension().lastPathComponent
			let missing = DriveLayout.discInfo(name).map { (discCount[$0.key] ?? 0) < 2 } ?? false
			return Game(platform: .ps1, filename: url.lastPathComponent, serial: serial(url),
			            title: name.replacingOccurrences(of: "_", with: " "), size: size(url), missingDisc: missing)
		}

		let order: (Game, Game) -> Bool = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
		return (ps2.sorted(by: order), ps1.sorted(by: order))
	}

	// MARK: - Installazione (trascinamento)

	func handleDrop(_ urls: [URL]) {
		guard let layout else {
			alert(String(localized: "Choose the destination drive first!"))
			return
		}
		var ps2: [URL] = []
		var ps1: [URL] = []
		for url in expand(urls) where !url.lastPathComponent.hasPrefix("._") {
			switch url.pathExtension.lowercased() {
			case "iso":
				ps2.append(url)
			case "cue":
				ps1.append(url)
			case "bin":
				// Un .bin con il suo .cue accanto viene gestito dal .cue.
				let cue = url.deletingPathExtension().appendingPathExtension("cue")
				ps1.append(FileManager.default.fileExists(atPath: cue.path) ? cue : url)
			default:
				break
			}
		}
		var seen = Set<URL>()
		ps1 = ps1.filter { seen.insert($0.standardizedFileURL).inserted }

		for iso in ps2 {
			let destination = layout.dvd.appendingPathComponent(iso.lastPathComponent)
			if FileManager.default.fileExists(atPath: destination.path),
			   !confirm(String(localized: "Overwrite?"), String(localized: "\(iso.lastPathComponent) is already on the drive. Overwrite it?")) {
				continue
			}
			enqueue(String(localized: "Installing PS2: \(iso.lastPathComponent)")) { [unowned self] in
				try await installPS2(iso, layout: layout)
			}
		}
		handlePS1Drop(ps1, layout: layout)
	}

	/// Le cartelle trascinate vengono esplorate alla ricerca di immagini.
	private func expand(_ urls: [URL]) -> [URL] {
		urls.flatMap { url -> [URL] in
			guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [url] }
			let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
			return (enumerator?.allObjects as? [URL] ?? []).filter { ["iso", "cue", "bin"].contains($0.pathExtension.lowercased()) }
		}
	}

	private func handlePS1Drop(_ sources: [URL], layout: DriveLayout) {
		guard !sources.isEmpty, ensurePOPStarter() else { return }
		var groups: [String: [(url: URL, info: DiscInfo)]] = [:]
		var singles: [URL] = []
		for url in sources {
			if let info = DriveLayout.discInfo(url.deletingPathExtension().lastPathComponent) {
				groups[info.key, default: []].append((url, info))
			} else {
				singles.append(url)
			}
		}

		for url in singles {
			let name = url.deletingPathExtension().lastPathComponent
			if FileManager.default.fileExists(atPath: layout.pops.appendingPathComponent(name + ".VCD").path),
			   !confirm(String(localized: "Overwrite PS1 game?"), String(localized: "\(name) is already on the drive. Overwrite it?")) {
				continue
			}
			enqueue(String(localized: "Converting PS1: \(name)")) { [unowned self] in
				try await installPS1(url, layout: layout)
			}
		}

		for (key, discs) in groups.sorted(by: { $0.key < $1.key }) {
			let base = discs[0].info.base
			if discs.count == 1,
			   !confirm(String(localized: "Incomplete multi-disc game"), String(localized: "You only dropped one disc of:\n\(base)\nContinue anyway?")) {
				continue
			}
			let sorted = discs.sorted { $0.info.disc < $1.info.disc }.map(\.url)
			for (index, disc) in sorted.enumerated() {
				enqueue(String(localized: "Multi-disc \(base): disc \(index + 1) of \(sorted.count)")) { [unowned self] in
					try await installPS1(disc, layout: layout)
					if index == sorted.count - 1 { try writeMultiDiscConfig(key: key, base: base, layout: layout) }
				}
			}
		}
	}

	/// POPSTARTER.ELF non è incluso nell'app: se manca, propone di importarlo prima di installare giochi PS1.
	private func ensurePOPStarter() -> Bool {
		let assets = UserAssets.shared
		if assets.hasPOPStarter { return true }
		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.messageText = String(localized: "POPSTARTER.ELF is needed")
		alert.informativeText = String(localized: "PS1 games are started through POPStarter, which is not included with PS2 Manager. Import your own copy of POPSTARTER.ELF to continue.")
		alert.addButton(withTitle: String(localized: "Import POPSTARTER.ELF…"))
		alert.addButton(withTitle: String(localized: "Cancel"))
		guard alert.runModal() == .alertFirstButtonReturn else { return false }
		return assets.chooseAndImportPOPStarter()
	}

	private func installPS2(_ source: URL, layout: DriveLayout) async throws {
		let destination = layout.dvd.appendingPathComponent(source.lastPathComponent)
		try await background { progress in try DiscTools.copy(from: source, to: destination, progress: progress) }
		setStatus(String(localized: "Installed: \(source.lastPathComponent)"), .success)
		await autoDownloadCover(for: destination, platform: .ps2, layout: layout)
		refresh()
	}

	/// Converte un .cue/.bin in VCD, copia le patch accanto all'immagine e crea il lanciatore in APPS/.
	private func installPS1(_ source: URL, layout: DriveLayout) async throws {
		let gameName = source.deletingPathExtension().lastPathComponent
		let vcd = layout.pops.appendingPathComponent(gameName + ".VCD")
		let cue: DiscTools.CueInfo = source.pathExtension.lowercased() == "cue"
			? try DiscTools.parseCue(at: source)
			: DiscTools.CueInfo(binURL: source, trackType: "MODE2/2352", minutes: 0, seconds: 0, frames: 0)
		try await background { progress in try DiscTools.convertBinToVCD(bin: cue.binURL, vcd: vcd, cue: cue, progress: progress) }

		let fm = FileManager.default
		let localPatches = source.deletingLastPathComponent().appendingPathComponent(gameName)
		if let files = try? fm.contentsOfDirectory(atPath: localPatches.path) {
			let patchFolder = layout.pops.appendingPathComponent(gameName)
			for file in files where PatchPack.isPatchFile(file) {
				try fm.createDirectory(at: patchFolder, withIntermediateDirectories: true)
				try DiscTools.atomicCopy(from: localPatches.appendingPathComponent(file), to: patchFolder.appendingPathComponent(file))
			}
		}

		try writeLauncher(gameName: gameName, layout: layout)
		setStatus(String(localized: "Installed: \(gameName)"), .success)
		await autoDownloadCover(for: vcd, platform: .ps1, layout: layout)
		refresh()
	}

	private func writeLauncher(gameName: String, layout: DriveLayout) throws {
		guard let elf = UserAssets.popStarterData() else { throw ToolError.message(String(localized: "POPSTARTER.ELF has not been imported. Import it in Settings.")) }
		let folder = layout.apps.appendingPathComponent(gameName)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let elfName = "\(loaderMode.popsPrefix)\(gameName).ELF"
		try elf.write(to: folder.appendingPathComponent(elfName))
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent(elfName).path)
		try "title=\(gameName)\nboot=\(elfName)".write(to: folder.appendingPathComponent("title.cfg"), atomically: true, encoding: .utf8)
	}

	/// DISCS.TXT e VMCDIR.TXT fanno sì che POPStarter tratti i dischi come un solo gioco con una memory card condivisa.
	private func writeMultiDiscConfig(key: String, base: String, layout: DriveLayout) throws {
		let discs = discFiles(key: key, layout: layout).map(\.file)
		guard let first = discs.first else { return }
		let list = discs.joined(separator: "\n")
		let vmc = (first as NSString).deletingPathExtension
		for disc in discs {
			let folder = layout.pops.appendingPathComponent((disc as NSString).deletingPathExtension)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try list.write(to: folder.appendingPathComponent("DISCS.TXT"), atomically: true, encoding: .utf8)
			try vmc.write(to: folder.appendingPathComponent("VMCDIR.TXT"), atomically: true, encoding: .utf8)
		}
		setStatus(String(localized: "Multi-disc set up: \(base) (\(discs.count) discs)"), .success)
	}

	/// I VCD sull'unità che appartengono allo stesso gioco multidisco, ordinati per numero di disco.
	private func discFiles(key: String, layout: DriveLayout) -> [(file: String, info: DiscInfo)] {
		((try? FileManager.default.contentsOfDirectory(atPath: layout.pops.path)) ?? [])
			.filter { !$0.hasPrefix("._") && $0.lowercased().hasSuffix(".vcd") }
			.compactMap { file in DriveLayout.discInfo((file as NSString).deletingPathExtension).map { (file, $0) } }
			.filter { $0.info.key == key }
			.sorted { $0.info.disc < $1.info.disc }
	}

	/// Rinomina tutti i dischi di un gioco nel formato "Nome (Disc N)", spostando anche le cartelle POPS/ e APPS/
	/// e aggiornando lanciatori, DISCS.TXT e VMCDIR.TXT.
	func standardizeDiscNames(_ game: Game) {
		guard let layout, let info = game.discInfo else { return }
		let discs = discFiles(key: info.key, layout: layout)
		guard let newBase = askForGameName(base: info.base, discs: discs.map(\.file)) else { return }

		let fm = FileManager.default
		var renamed: [(old: String, new: String)] = []
		for disc in discs {
			let oldName = (disc.file as NSString).deletingPathExtension
			let newName = DiscInfo.standardName(base: newBase, disc: disc.info.disc)
			guard oldName != newName else { continue }
			if fm.fileExists(atPath: layout.pops.appendingPathComponent(newName + ".VCD").path) {
				alert(String(localized: "\(newName).VCD already exists on the drive."))
				return
			}
			renamed.append((oldName, newName))
		}

		do {
			for (oldName, newName) in renamed {
				let ext = (discs.first { ($0.file as NSString).deletingPathExtension == oldName }?.file as NSString?)?.pathExtension ?? "VCD"
				try fm.moveItem(at: layout.pops.appendingPathComponent("\(oldName).\(ext)"), to: layout.pops.appendingPathComponent("\(newName).VCD"))
				let oldFolder = layout.pops.appendingPathComponent(oldName)
				if fm.fileExists(atPath: oldFolder.path) {
					try fm.moveItem(at: oldFolder, to: layout.pops.appendingPathComponent(newName))
				}
				try renameLauncher(from: oldName, to: newName, layout: layout)
			}
			try writeMultiDiscConfig(key: DiscInfo(base: newBase, disc: 1, isStandard: true).key, base: newBase, layout: layout)
		} catch {
			setStatus(String(localized: "Error: \(error.localizedDescription)"), .error)
		}
		refresh()
	}

	/// Sposta APPS/<vecchio> in APPS/<nuovo>, rinominando l'ELF (mantiene il prefisso XX./SB.) e riscrivendo title.cfg.
	private func renameLauncher(from oldName: String, to newName: String, layout: DriveLayout) throws {
		let fm = FileManager.default
		let oldFolder = layout.apps.appendingPathComponent(oldName)
		guard fm.fileExists(atPath: oldFolder.path) else { return }
		let newFolder = layout.apps.appendingPathComponent(newName)
		try fm.moveItem(at: oldFolder, to: newFolder)
		let files = (try? fm.contentsOfDirectory(atPath: newFolder.path)) ?? []
		guard let elf = files.first(where: { $0.uppercased().hasSuffix(".ELF") }) else { return }
		let prefix = elf.hasPrefix("SB.") ? "SB." : (elf.hasPrefix("XX.") ? "XX." : loaderMode.popsPrefix)
		let newElf = "\(prefix)\(newName).ELF"
		if elf != newElf {
			try fm.moveItem(at: newFolder.appendingPathComponent(elf), to: newFolder.appendingPathComponent(newElf))
		}
		try "title=\(newName)\nboot=\(newElf)".write(to: newFolder.appendingPathComponent("title.cfg"), atomically: true, encoding: .utf8)
	}

	private func askForGameName(base: String, discs: [String]) -> String? {
		let alert = NSAlert()
		alert.messageText = String(localized: "Rename to standard format")
		alert.informativeText = String(localized: "The discs will be renamed to “Name (Disc N)”, together with their POPS and APPS folders:\n\(discs.joined(separator: "\n"))")
		let field = NSTextField(string: base)
		field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
		alert.accessoryView = field
		alert.window.initialFirstResponder = field
		alert.addButton(withTitle: String(localized: "Rename"))
		alert.addButton(withTitle: String(localized: "Cancel"))
		guard alert.runModal() == .alertFirstButtonReturn else { return nil }
		var name = field.stringValue
		for bad in [":", "/", "\\", "?", "*", "\"", "<", ">", "|"] { name = name.replacingOccurrences(of: bad, with: "") }
		name = name.trimmingCharacters(in: .whitespaces)
		return name.isEmpty ? nil : name
	}

	private func autoDownloadCover(for file: URL, platform: Platform, layout: DriveLayout) async {
		guard defaults.bool(forKey: SettingsKey.autoDownloadCovers) else { return }
		let serial = await Task.detached { DiscTools.serial(inFileAt: file) ?? DiscTools.serial(inFilename: file.lastPathComponent) }.value
		guard let serial, !FileManager.default.fileExists(atPath: layout.coverURL(serial: serial).path) else { return }
		try? await CoverDownloader.download(serial: serial, platform: platform, to: layout.art)
	}

	// MARK: - Azioni sui giochi

	func defrag(_ game: Game) {
		guard let layout, confirm(String(localized: "Defragment"), String(localized: "Defragment \(game.filename)?")) else { return }
		enqueue(String(localized: "Defragmenting \(game.title)…")) { [unowned self] in
			try await defragment(game, layout: layout)
			setStatus(String(localized: "Defragmentation complete."), .success)
			refresh()
		}
	}

	func defragAll() {
		guard let layout, !ps2Games.isEmpty,
		      confirm(String(localized: "Defragment everything"), String(localized: "This rewrites every PS2 game and can take a long time.\nContinue?")) else { return }
		let games = ps2Games
		enqueue(String(localized: "Batch defragmentation…")) { [unowned self] in
			var failures = 0
			for (index, game) in games.enumerated() {
				try Task.checkCancellation()
				setStatus(String(localized: "Defrag [\(index + 1)/\(games.count)]: \(game.title)"))
				do { try await defragment(game, layout: layout) } catch is CancellationError { throw CancellationError() } catch { failures += 1 }
			}
			setStatus(String(localized: "Batch defragmentation complete. Errors: \(failures)"), failures == 0 ? .success : .warning)
			refresh()
		}
	}

	/// Riscrive il file in modo contiguo: lo rinomina in .bak, lo ricopia e cancella il .bak (ripristinandolo se qualcosa va storto).
	private func defragment(_ game: Game, layout: DriveLayout) async throws {
		let original = layout.gameURL(game)
		let backup = original.appendingPathExtension("bak")
		try FileManager.default.moveItem(at: original, to: backup)
		do {
			try await background { progress in try DiscTools.copy(from: backup, to: original, progress: progress) }
			try FileManager.default.removeItem(at: backup)
		} catch {
			try? FileManager.default.removeItem(at: original)
			try? FileManager.default.moveItem(at: backup, to: original)
			throw error
		}
	}

	func rename(_ game: Game) {
		guard let layout else { return }
		let url = layout.gameURL(game)
		guard let serial = DiscTools.serial(inFileAt: url) ?? DiscTools.serial(inFilename: game.filename) else {
			alert(String(localized: "No game ID found in \(game.filename)."))
			return
		}
		let newName = DiscTools.proposedISOName(serial: serial, title: GameDatabase.title(forSerial: serial))
		guard newName != game.filename else {
			setStatus(String(localized: "The name is already correct."), .success)
			return
		}
		guard confirm(String(localized: "Rename"), String(localized: "New name:\n\(newName)")) else { return }
		do {
			try FileManager.default.moveItem(at: url, to: layout.dvd.appendingPathComponent(newName))
			setStatus(String(localized: "Renamed to \(newName)"), .success)
		} catch {
			setStatus(String(localized: "Error: \(error.localizedDescription)"), .error)
		}
		refresh()
	}

	func export(_ game: Game) {
		guard let layout, let folder = chooseFolder(String(localized: "Choose where to export \(game.title)")) else { return }
		let source = layout.gameURL(game)
		if game.platform == .ps2 {
			enqueue(String(localized: "Exporting ISO: \(game.filename)")) { [unowned self] in
				try await background { progress in try DiscTools.copy(from: source, to: folder.appendingPathComponent(game.filename), progress: progress) }
				setStatus(String(localized: "Export complete: \(game.filename)"), .success)
			}
		} else {
			let name = game.baseName.replacingOccurrences(of: "_", with: " ")
			enqueue(String(localized: "Converting VCD to BIN/CUE…")) { [unowned self] in
				let bin = folder.appendingPathComponent(name + ".bin")
				try await background { progress in try DiscTools.convertVCDToBin(vcd: source, bin: bin, progress: progress) }
				try DiscTools.cueSheet(forBin: name + ".bin").write(to: folder.appendingPathComponent(name + ".cue"), atomically: true, encoding: .utf8)
				setStatus(String(localized: "Export complete: \(name)"), .success)
			}
		}
	}

	func delete(_ game: Game) {
		guard let layout else { return }
		if defaults.bool(forKey: SettingsKey.confirmDeletion),
		   !confirm(String(localized: "Delete"), String(localized: "Delete \(game.filename) and its cover, configuration and cheats?"), destructive: true) {
			return
		}
		let fm = FileManager.default
		if let serial = game.serial {
			let dashed = serial.replacingOccurrences(of: "_", with: "-")
			for name in ["\(serial)_COV.png", "\(serial)_COV.jpg", "\(dashed)_COV.png", "\(dashed)_COV.jpg"] {
				try? fm.removeItem(at: layout.art.appendingPathComponent(name))
			}
			try? fm.removeItem(at: layout.cheatURL(serial: serial))
			try? fm.removeItem(at: layout.configURL(serial: serial))
		}
		try? fm.removeItem(at: layout.gameURL(game))
		if game.platform == .ps1 {
			let name = (game.filename as NSString).deletingPathExtension
			try? fm.removeItem(at: layout.apps.appendingPathComponent(name))
			try? fm.removeItem(at: layout.pops.appendingPathComponent(name))
		}
		setStatus(String(localized: "Deleted: \(game.title)"), .success)
		refresh()
	}

	// MARK: - Copertine

	/// Percorso della copertina (può non esistere: le miniature lo verificano caricandola in background).
	func coverURL(for game: Game) -> URL? {
		guard let layout, let serial = game.serial else { return nil }
		return layout.coverURL(serial: serial)
	}

	func downloadCover(serial: String, platform: Platform) async -> Bool {
		guard let layout else { return false }
		setStatus(String(localized: "Downloading cover…"))
		do {
			try await CoverDownloader.download(serial: serial, platform: platform, to: layout.art)
			coverRevision += 1
			setStatus(String(localized: "Cover downloaded!"), .success)
			return true
		} catch {
			setStatus(String(localized: "Cover download failed: \(error.localizedDescription)"), .error)
			return false
		}
	}

	func downloadAllCovers() {
		guard let layout, !(ps2Games.isEmpty && ps1Games.isEmpty),
		      confirm(String(localized: "Download covers"), String(localized: "Download the missing covers for ALL games?")) else { return }
		let games = ps2Games + ps1Games
		enqueue(String(localized: "Downloading covers…")) { [unowned self] in
			var downloaded = 0, failed = 0
			for (index, game) in games.enumerated() {
				try Task.checkCancellation()
				progress = Double(index + 1) / Double(games.count)
				guard let serial = game.serial, !FileManager.default.fileExists(atPath: layout.coverURL(serial: serial).path) else { continue }
				setStatus(String(localized: "[\(index + 1)/\(games.count)] Downloading: \(game.title)"))
				do {
					try await CoverDownloader.download(serial: serial, platform: game.platform, to: layout.art)
					downloaded += 1
				} catch {
					failed += 1
				}
				try await Task.sleep(for: .milliseconds(100))
			}
			coverRevision += 1
			setStatus(String(localized: "Done! Downloaded: \(downloaded) – Errors: \(failed)"), failed == 0 ? .success : .warning)
		}
	}

	// MARK: - Finestre di dialogo

	func confirm(_ title: String, _ message: String, destructive: Bool = false) -> Bool {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = message
		alert.alertStyle = destructive ? .critical : .informational
		let ok = alert.addButton(withTitle: destructive ? String(localized: "Delete") : String(localized: "OK"))
		ok.hasDestructiveAction = destructive
		alert.addButton(withTitle: String(localized: "Cancel"))
		return alert.runModal() == .alertFirstButtonReturn
	}

	func alert(_ message: String) {
		let alert = NSAlert()
		alert.messageText = message
		alert.runModal()
	}

	private func chooseFolder(_ message: String) -> URL? {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.message = message
		panel.prompt = String(localized: "Export")
		return panel.runModal() == .OK ? panel.url : nil
	}
}
