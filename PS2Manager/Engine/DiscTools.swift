import Foundation

/// Operazioni sui file dei giochi: copia con avanzamento, conversioni BIN ⇄ VCD (POPS), lettura dei seriali.
enum DiscTools {
	static let sectorSize = 2352
	static let vcdHeaderSize = 0x100000
	private static let chunkSize = 4 * 1024 * 1024

	typealias Progress = @Sendable (Double) -> Void

	// MARK: - Seriali

	static let serialPattern = try! NSRegularExpression(pattern: "(SLES|SCES|SLUS|SCUS|SLPM|SCPM|SIPS|SLPS|SCPS)_(\\d{3})\\.(\\d{2})")

	/// Cerca un seriale (es. `SLES_553.45`) nei primi 2 MB del file.
	static func serial(inFileAt url: URL) -> String? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }
		guard let data = try? handle.read(upToCount: 2 * 1024 * 1024), !data.isEmpty else { return nil }
		// Latin-1 mappa ogni byte su un carattere, quindi i dati binari non fanno fallire la decodifica.
		guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
		return firstSerial(in: text)
	}

	static func serial(inFilename name: String) -> String? {
		firstSerial(in: name)
	}

	private static func firstSerial(in text: String) -> String? {
		let range = NSRange(text.startIndex..., in: text)
		guard let match = serialPattern.firstMatch(in: text, range: range), let r = Range(match.range, in: text) else { return nil }
		return String(text[r])
	}

	/// Nome proposto per un ISO in stile OPL: `SLES_553.45.Titolo del gioco.iso`.
	static func proposedISOName(serial: String, title: String?) -> String {
		var clean = title ?? "Unknown Game"
		for (from, to) in [(":", " -"), ("/", "-"), ("\\", "-"), ("?", ""), ("*", ""), ("\"", ""), ("<", ""), (">", ""), ("|", "")] {
			clean = clean.replacingOccurrences(of: from, with: to)
		}
		return "\(serial).\(clean.trimmingCharacters(in: .whitespaces)).iso"
	}

	// MARK: - Copia

	/// Copia un file a blocchi segnalando l'avanzamento; in caso di errore rimuove la destinazione parziale.
	static func copy(from source: URL, to destination: URL, progress: Progress) throws {
		let size = try fileSize(source)
		let input = try FileHandle(forReadingFrom: source)
		defer { try? input.close() }
		let output = try createFile(at: destination)
		var ok = false
		defer {
			try? output.close()
			if !ok { try? FileManager.default.removeItem(at: destination) }
		}
		try pump(from: input, to: output, total: size, progress: progress)
		ok = true
	}

	/// Copia passando per un file temporaneo, così la destinazione non resta mai a metà.
	static func atomicCopy(from source: URL, to destination: URL) throws {
		let temp = destination.appendingPathExtension("tmp")
		try? FileManager.default.removeItem(at: temp)
		try FileManager.default.copyItem(at: source, to: temp)
		if FileManager.default.fileExists(atPath: destination.path) {
			_ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
		} else {
			try FileManager.default.moveItem(at: temp, to: destination)
		}
	}

	// MARK: - PS1: CUE / VCD

	struct CueInfo {
		var binURL: URL
		var trackType: String
		var minutes: Int, seconds: Int, frames: Int
	}

	/// Legge il primo FILE e l'INDEX 01 della prima traccia di un .cue.
	static func parseCue(at url: URL) throws -> CueInfo {
		let text = try String(contentsOf: url, encoding: .isoLatin1)
		var binName: String?
		var trackType = "MODE2/2352"
		var inFirstTrack = false
		var index: (Int, Int, Int)?
		for raw in text.components(separatedBy: .newlines) {
			let line = raw.trimmingCharacters(in: .whitespaces)
			let upper = line.uppercased()
			if upper.hasPrefix("FILE "), binName == nil {
				binName = cueFileName(line)
			} else if upper.hasPrefix("TRACK ") {
				let parts = line.split(separator: " ", omittingEmptySubsequences: true)
				inFirstTrack = parts.count >= 2 && Int(parts[1]) == 1
				if inFirstTrack, parts.count >= 3 { trackType = String(parts[2]) }
			} else if upper.hasPrefix("INDEX 01"), inFirstTrack, index == nil {
				let time = line.split(separator: " ").last.map(String.init) ?? ""
				let p = time.split(separator: ":").compactMap { Int($0) }
				if p.count == 3 { index = (p[0], p[1], p[2]) }
			}
		}
		guard let binName, !binName.isEmpty else { throw ToolError.message(String(localized: "BIN file not found in the CUE sheet")) }
		let i = index ?? (0, 0, 0)
		return CueInfo(binURL: url.deletingLastPathComponent().appendingPathComponent(binName), trackType: trackType, minutes: i.0, seconds: i.1, frames: i.2)
	}

	private static func cueFileName(_ line: String) -> String? {
		if let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last {
			return String(line[line.index(after: first)..<last])
		}
		let parts = line.split(separator: " ")
		return parts.count >= 3 ? parts[1...(parts.count - 2)].joined(separator: " ") : nil
	}

	static func cueSheet(forBin binName: String) -> String {
		"FILE \"\(binName)\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00"
	}

	/// Converte un'immagine BIN (2352 byte/settore) in un VCD per POPStarter: header di 1 MB + dati.
	static func convertBinToVCD(bin: URL, vcd: URL, cue: CueInfo, progress: Progress) throws {
		let size = try fileSize(bin)
		let sectorCount = UInt32(size / Int64(sectorSize))
		var header = [UInt8](repeating: 0, count: vcdHeaderSize)
		header[0] = 0x41; header[2] = 0xA0; header[7] = 0x01; header[8] = 0x20
		header[12] = 0xA1; header[22] = 0xA2
		let leadOut = sectorCount + 150
		let m = leadOut / 4500, s = (leadOut % 4500) / 75, f = (leadOut % 4500) % 75
		header[27] = bcd(m); header[28] = bcd(s); header[29] = bcd(f)
		header[33] = UInt8(truncatingIfNeeded: cue.minutes)
		header[34] = UInt8(truncatingIfNeeded: cue.seconds)
		header[35] = UInt8(truncatingIfNeeded: cue.frames)
		header[1024] = 0x6B; header[1025] = 0x48; header[1026] = 0x6E; header[1027] = 0x20
		writeLE(sectorCount, into: &header, at: 1032)
		writeLE(sectorCount, into: &header, at: 1036)

		let input = try FileHandle(forReadingFrom: bin)
		defer { try? input.close() }
		let output = try createFile(at: vcd)
		var ok = false
		defer {
			try? output.close()
			if !ok { try? FileManager.default.removeItem(at: vcd) }
		}
		try output.write(contentsOf: Data(header))
		try pump(from: input, to: output, total: size, progress: progress)
		ok = true
	}

	/// Estrae i dati BIN da un VCD scartando l'header di 1 MB.
	static func convertVCDToBin(vcd: URL, bin: URL, progress: Progress) throws {
		let size = try fileSize(vcd)
		guard size > Int64(vcdHeaderSize) else { throw ToolError.message(String(localized: "Invalid VCD file")) }
		let input = try FileHandle(forReadingFrom: vcd)
		defer { try? input.close() }
		try input.seek(toOffset: UInt64(vcdHeaderSize))
		let output = try createFile(at: bin)
		var ok = false
		defer {
			try? output.close()
			if !ok { try? FileManager.default.removeItem(at: bin) }
		}
		try pump(from: input, to: output, total: size - Int64(vcdHeaderSize), progress: progress)
		ok = true
	}

	// MARK: - Utilità

	static func fileSize(_ url: URL) throws -> Int64 {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		return (attributes[.size] as? NSNumber)?.int64Value ?? 0
	}

	private static func createFile(at url: URL) throws -> FileHandle {
		FileManager.default.createFile(atPath: url.path, contents: nil)
		return try FileHandle(forWritingTo: url)
	}

	private static func pump(from input: FileHandle, to output: FileHandle, total: Int64, progress: Progress) throws {
		var written: Int64 = 0
		var lastReport = Date.distantPast
		while true {
			try Task.checkCancellation()
			let chunk = try autoreleasepool { try input.read(upToCount: chunkSize) }
			guard let chunk, !chunk.isEmpty else { break }
			try output.write(contentsOf: chunk)
			written += Int64(chunk.count)
			if Date().timeIntervalSince(lastReport) > 0.1, total > 0 {
				progress(Double(written) / Double(total))
				lastReport = Date()
			}
		}
		progress(1)
	}

	private static func bcd(_ value: UInt32) -> UInt8 {
		UInt8(((value / 10) * 16) + (value % 10))
	}

	private static func writeLE(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
		for i in 0..<4 { buffer[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
	}
}

enum ToolError: LocalizedError {
	case message(String)
	var errorDescription: String? {
		if case .message(let text) = self { return text }
		return nil
	}
}
