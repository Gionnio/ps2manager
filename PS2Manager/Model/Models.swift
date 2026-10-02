import SwiftUI

enum Platform: String, Hashable {
	case ps2, ps1
}

/// Modalità di Open PS2 Loader: cambia il prefisso dell'ELF di POPStarter (`XX.` per USB, `SB.` per SMB).
enum LoaderMode: String, CaseIterable, Identifiable {
	case usb = "USB", smb = "SMB"
	var id: String { rawValue }
	var popsPrefix: String { self == .smb ? "SB." : "XX." }
}

enum AppTheme: String, CaseIterable, Identifiable {
	case system, light, dark
	var id: String { rawValue }

	var colorScheme: ColorScheme? {
		switch self {
		case .system: nil
		case .light: .light
		case .dark: .dark
		}
	}

	var label: LocalizedStringKey {
		switch self {
		case .system: "System"
		case .light: "Light"
		case .dark: "Dark"
		}
	}
}

/// Chiavi delle impostazioni condivise tra viste e modello.
enum SettingsKey {
	static let theme = "theme"
	static let loaderMode = "loaderMode"
	static let reopenLastDrive = "reopenLastDrive"
	static let lastDrivePath = "lastDrivePath"
	static let showCovers = "showCovers"
	static let autoDownloadCovers = "autoDownloadCovers"
	static let confirmDeletion = "confirmDeletion"
	static let readSerialsFromImages = "readSerialsFromImages"

	static func registerDefaults() {
		UserDefaults.standard.register(defaults: [
			theme: AppTheme.system.rawValue,
			loaderMode: LoaderMode.usb.rawValue,
			reopenLastDrive: true,
			showCovers: true,
			autoDownloadCovers: true,
			confirmDeletion: true,
			readSerialsFromImages: true,
		])
	}
}

struct Game: Identifiable, Hashable {
	let platform: Platform
	let filename: String
	let serial: String?
	let title: String
	let size: Int64
	/// Gioco multidisco di cui sull'unità c'è un solo disco.
	let missingDisc: Bool

	var id: String { "\(platform.rawValue)/\(filename)" }

	/// Nome senza estensione né prefisso `XX.`/`SB.`: è il nome delle cartelle POPS/<nome> e APPS/<nome>.
	var baseName: String {
		DriveLayout.stripPopsPrefix((filename as NSString).deletingPathExtension)
	}

	var sizeText: String {
		ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
	}
}

/// Struttura delle cartelle di Open PS2 Loader su un'unità USB o una condivisione SMB.
struct DriveLayout {
	let root: URL
	var dvd: URL { root.appendingPathComponent("DVD") }
	var pops: URL { root.appendingPathComponent("POPS") }
	var art: URL { root.appendingPathComponent("ART") }
	var cfg: URL { root.appendingPathComponent("CFG") }
	var vmc: URL { root.appendingPathComponent("VMC") }
	var cht: URL { root.appendingPathComponent("CHT") }
	var apps: URL { root.appendingPathComponent("APPS") }

	func createFolders() {
		for folder in [dvd, pops, art, cfg, vmc, cht] {
			try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		}
	}

	func coverURL(serial: String) -> URL { art.appendingPathComponent("\(serial)_COV.png") }
	func configURL(serial: String) -> URL { cfg.appendingPathComponent("\(serial).cfg") }
	func cheatURL(serial: String) -> URL { cht.appendingPathComponent("\(serial).cht") }
	func patchFolder(for game: Game) -> URL { pops.appendingPathComponent(game.baseName) }

	func gameURL(_ game: Game) -> URL {
		(game.platform == .ps2 ? dvd : pops).appendingPathComponent(game.filename)
	}

	static func stripPopsPrefix(_ name: String) -> String {
		name.hasPrefix("XX.") || name.hasPrefix("SB.") ? String(name.dropFirst(3)) : name
	}

	/// "Nome (Disc 2)" → ("Nome", 2)
	static func discInfo(_ name: String) -> (base: String, disc: Int)? {
		guard let match = discPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
		      let base = Range(match.range(at: 1), in: name), let disc = Range(match.range(at: 2), in: name) else { return nil }
		return (name[base].trimmingCharacters(in: .whitespaces), Int(name[disc]) ?? 0)
	}

	private static let discPattern = try! NSRegularExpression(pattern: "^(.*)\\s+\\(Disc\\s+(\\d+)\\)$", options: .caseInsensitive)
}

enum StatusKind {
	case info, success, warning, error

	var color: Color {
		switch self {
		case .info: .blue
		case .success: .green
		case .warning: .orange
		case .error: .red
		}
	}

	var symbol: String {
		switch self {
		case .info: "info.circle.fill"
		case .success: "checkmark.circle.fill"
		case .warning: "exclamationmark.triangle.fill"
		case .error: "xmark.octagon.fill"
		}
	}
}
