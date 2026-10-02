import SwiftUI

struct GameRow: View {
	@EnvironmentObject private var library: Library
	@AppStorage(SettingsKey.showCovers) private var showCovers = true
	let game: Game
	let onConfigure: () -> Void

	var body: some View {
		HStack(spacing: 12) {
			if showCovers {
				CoverThumbnail(url: library.coverURL(for: game), platform: game.platform, revision: library.coverRevision)
					.frame(width: 36, height: 50)
			}
			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 6) {
					Text(game.title).font(.body.weight(.semibold)).lineLimit(1)
					if game.missingDisc {
						Badge(text: String(localized: "Missing disc"), color: .orange)
					}
				}
				HStack(spacing: 6) {
					if let serial = game.serial {
						Badge(text: serial, color: .blue)
					}
					Text(game.filename).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
				}
				.font(.caption)
			}
			Spacer(minLength: 8)
			Text(game.sizeText)
				.font(.callout.monospacedDigit())
				.foregroundStyle(.secondary)
			HStack(spacing: 2) {
				RowButton("Configure", symbol: "gearshape", action: onConfigure)
				if game.platform == .ps2 {
					RowButton("Rename to OPL Format", symbol: "pencil") { library.rename(game) }
				}
				RowButton(game.platform == .ps2 ? "Export ISO" : "Export as BIN/CUE", symbol: "square.and.arrow.up") { library.export(game) }
				if game.platform == .ps2 {
					RowButton("Defragment", symbol: "arrow.triangle.2.circlepath") { library.defrag(game) }
				}
				RowButton("Delete", symbol: "trash", tint: .red) { library.delete(game) }
			}
		}
		.padding(.vertical, 3)
		.contentShape(Rectangle())
		.onTapGesture(count: 2, perform: onConfigure)
	}
}

private struct RowButton: View {
	let title: LocalizedStringKey
	let symbol: String
	var tint: Color = .secondary
	let action: () -> Void

	init(_ title: LocalizedStringKey, symbol: String, tint: Color = .secondary, action: @escaping () -> Void) {
		self.title = title
		self.symbol = symbol
		self.tint = tint
		self.action = action
	}

	var body: some View {
		Button(action: action) {
			Image(systemName: symbol)
				.frame(width: 26, height: 22)
				.foregroundStyle(tint)
		}
		.buttonStyle(.borderless)
		.help(title)
	}
}

struct CoverThumbnail: View {
	let url: URL?
	let platform: Platform
	var revision = 0
	@State private var image: NSImage?

	var body: some View {
		Group {
			if let image {
				Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
					.clipShape(RoundedRectangle(cornerRadius: 4))
					.shadow(color: .black.opacity(0.2), radius: 2, y: 1)
			} else {
				RoundedRectangle(cornerRadius: 4)
					.fill(.quaternary)
					.overlay {
						Image(systemName: platform == .ps2 ? "opticaldisc" : "playstation.logo")
							.foregroundStyle(.secondary)
					}
			}
		}
		// Caricata in background e solo quando cambia il file o la revisione, così l'elenco resta fluido anche su USB.
		.task(id: "\(url?.path ?? "")#\(revision)") {
			guard let url else { image = nil; return }
			image = await Task.detached { NSImage(contentsOf: url) }.value
		}
	}
}
