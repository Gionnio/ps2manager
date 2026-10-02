import AppKit

/// Database dei titoli (seriale → nome) incluso nell'app.
enum GameDatabase {
	static let titles: [String: String] = {
		guard let url = Bundle.main.url(forResource: "gameid", withExtension: "txt"),
		      let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
		var result: [String: String] = [:]
		for line in text.components(separatedBy: .newlines) {
			let line = line.trimmingCharacters(in: .whitespaces)
			guard let space = line.firstIndex(where: \.isWhitespace) else { continue }
			let title = line[space...].trimmingCharacters(in: .whitespaces)
			guard !title.isEmpty else { continue }
			result[key(String(line[..<space]))] = title
		}
		return result
	}()

	static func title(forSerial serial: String) -> String? {
		titles[key(serial)]
	}

	/// `SLES_553.45` e `SLES55345` puntano allo stesso gioco.
	private static func key(_ serial: String) -> String {
		serial.uppercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "")
	}
}

/// File di terze parti che l'utente importa da sé (non sono inclusi nell'app):
/// POPSTARTER.ELF e l'archivio di patch POPS, salvati in ~/Library/Application Support/PS2 Manager/.
@MainActor
final class UserAssets: ObservableObject {
	static let shared = UserAssets()

	@Published private(set) var hasPOPStarter = false
	@Published private(set) var patchPacks: [PatchPack] = []

	nonisolated static let folder: URL = {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("PS2 Manager", isDirectory: true)
	}()
	nonisolated static let popStarterURL = folder.appendingPathComponent("POPSTARTER.ELF")
	nonisolated static let patchesURL = folder.appendingPathComponent("Patches", isDirectory: true)

	private init() {
		reload()
	}

	func reload() {
		hasPOPStarter = FileManager.default.fileExists(atPath: Self.popStarterURL.path)
		patchPacks = PatchPack.load(from: Self.patchesURL)
	}

	nonisolated static func popStarterData() -> Data? {
		try? Data(contentsOf: popStarterURL)
	}

	// MARK: - POPStarter

	func importPOPStarter(from source: URL) throws {
		let data = try Data(contentsOf: source)
		// Un eseguibile ELF inizia con 0x7F 'E' 'L' 'F'.
		guard data.starts(with: [0x7F, 0x45, 0x4C, 0x46]) else {
			throw ToolError.message(String(localized: "The selected file is not a valid ELF executable."))
		}
		try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
		try data.write(to: Self.popStarterURL, options: .atomic)
		reload()
	}

	func removePOPStarter() {
		try? FileManager.default.removeItem(at: Self.popStarterURL)
		reload()
	}

	/// Chiede il file all'utente; restituisce true se l'importazione è riuscita.
	@discardableResult
	func chooseAndImportPOPStarter() -> Bool {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.message = String(localized: "Choose your POPSTARTER.ELF file.")
		panel.prompt = String(localized: "Import")
		guard panel.runModal() == .OK, let url = panel.url else { return false }
		do {
			try importPOPStarter(from: url)
			return true
		} catch {
			Self.showError(error)
			return false
		}
	}

	// MARK: - Patch

	/// Copia una cartella di patch (sottocartelle con file TROJAN_x.BIN / PATCH_x.BIN) sostituendo quella importata in precedenza.
	func importPatches(from source: URL) throws {
		guard !PatchPack.load(from: source).isEmpty else {
			throw ToolError.message(String(localized: "No TROJAN_x.BIN or PATCH_x.BIN files found in the selected folder."))
		}
		let fm = FileManager.default
		try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
		let temp = Self.folder.appendingPathComponent("Patches.importing", isDirectory: true)
		try? fm.removeItem(at: temp)
		try fm.copyItem(at: source, to: temp)
		try? fm.removeItem(at: Self.patchesURL)
		try fm.moveItem(at: temp, to: Self.patchesURL)
		reload()
	}

	func removePatches() {
		try? FileManager.default.removeItem(at: Self.patchesURL)
		reload()
	}

	func chooseAndImportPatches() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.message = String(localized: "Choose the folder that contains your POPS patches.")
		panel.prompt = String(localized: "Import")
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			try importPatches(from: url)
		} catch {
			Self.showError(error)
		}
	}

	func revealFolder() {
		try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
		NSWorkspace.shared.open(Self.folder)
	}

	private static func showError(_ error: Error) {
		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.messageText = String(localized: "Import failed")
		alert.informativeText = error.localizedDescription
		alert.runModal()
	}
}

/// File `CFG/<seriale>.cfg` di Open PS2 Loader (righe `chiave=valore`).
enum OPLConfig {
	static func read(_ url: URL) -> [String: String] {
		guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
		var map: [String: String] = [:]
		for line in text.components(separatedBy: .newlines) {
			guard let eq = line.firstIndex(of: "=") else { continue }
			map[String(line[..<eq])] = String(line[line.index(after: eq)...])
		}
		return map
	}

	static func write(_ map: [String: String], to url: URL) throws {
		let body = map.keys.sorted().compactMap { key -> String? in
			guard let value = map[key], !value.isEmpty else { return nil }
			return "\(key)=\(value)\n"
		}.joined()
		try body.write(to: url, atomically: true, encoding: .utf8)
	}
}

/// Copertine dai repository di xlenore su GitHub, salvate come `ART/<seriale>_COV.png`.
enum CoverDownloader {
	private static let ps2Base = "https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/"
	private static let ps1Base = "https://raw.githubusercontent.com/xlenore/psx-covers/main/covers/default/"

	private static let session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 15
		return URLSession(configuration: config)
	}()

	static func download(serial: String, platform: Platform, to artDirectory: URL) async throws {
		let base = platform == .ps2 ? ps2Base : ps1Base
		let dashed = serial.replacingOccurrences(of: "_", with: "-")
		let candidates = [dashed, dashed.replacingOccurrences(of: ".", with: "")]
		for name in candidates {
			guard let url = URL(string: base + name + ".jpg") else { continue }
			let (data, response) = try await session.data(from: url)
			guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
			guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else {
				throw ToolError.message(String(localized: "Invalid image"))
			}
			try png.write(to: artDirectory.appendingPathComponent("\(serial)_COV.png"), options: .atomic)
			return
		}
		throw ToolError.message(String(localized: "Cover not found"))
	}
}

/// Una patch POPS (cartella con file TROJAN_x.BIN / PATCH_x.BIN) dell'archivio importato dall'utente.
struct PatchPack: Identifiable, Hashable {
	let name: String
	let folder: URL
	let binFiles: [String]
	var id: String { folder.path }

	static func isPatchFile(_ name: String) -> Bool {
		let upper = name.uppercased()
		return upper.hasSuffix(".BIN") && (upper.hasPrefix("TROJAN_") || upper.hasPrefix("PATCH_"))
	}

	static func load(from root: URL) -> [PatchPack] {
		guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
		var packs: [PatchPack] = []
		for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
			let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
			let bins = files.filter { $0.uppercased().hasSuffix(".BIN") }.sorted()
			if files.contains(where: isPatchFile) {
				packs.append(PatchPack(name: url.lastPathComponent, folder: url, binFiles: bins))
			}
		}
		return packs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}

	func isInstalled(in directory: URL) -> Bool {
		binFiles.contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
	}

	@discardableResult
	func install(in directory: URL) throws -> Int {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		for file in binFiles {
			try DiscTools.atomicCopy(from: folder.appendingPathComponent(file), to: directory.appendingPathComponent(file))
		}
		return binFiles.count
	}

	@discardableResult
	func uninstall(from directory: URL) -> Int {
		var count = 0
		for file in binFiles where (try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))) != nil {
			count += 1
		}
		return count
	}
}
