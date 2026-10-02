import SwiftUI

/// Finestra Informazioni con sfondo HUD, come nelle altre app di Gionnio.
enum AboutWindow {
	private static var window: NSWindow?

	@MainActor
	static func show() {
		if window == nil {
			let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView, .hudWindow, .utilityWindow], backing: .buffered, defer: false)
			panel.titlebarAppearsTransparent = true
			panel.titleVisibility = .hidden
			panel.isReleasedWhenClosed = false
			panel.isMovableByWindowBackground = true
			let effect = NSVisualEffectView()
			effect.material = .hudWindow
			effect.blendingMode = .behindWindow
			effect.state = .active
			let host = NSHostingView(rootView: AboutView())
			host.translatesAutoresizingMaskIntoConstraints = false
			effect.addSubview(host)
			NSLayoutConstraint.activate([
				host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
				host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
				host.topAnchor.constraint(equalTo: effect.topAnchor),
				host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
			])
			panel.contentView = effect
			panel.setContentSize(host.fittingSize)
			panel.center()
			window = panel
		}
		window?.makeKeyAndOrderFront(nil)
	}
}

struct AboutView: View {
	private var version: String {
		let info = Bundle.main.infoDictionary
		return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
	}

	var body: some View {
		VStack(spacing: 10) {
			Image(nsImage: NSApp.applicationIconImage)
				.resizable()
				.frame(width: 110, height: 110)
				.shadow(color: .black.opacity(0.3), radius: 8, y: 4)
			Text("PS2 Manager").font(.system(size: 26, weight: .bold))
			Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
			Divider().padding(.vertical, 4)
			Text("Made with ❤️ by Gionnio")
			Link(destination: URL(string: "https://github.com/Gionnio/ps2manager")!) {
				Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right")
					.padding(.horizontal, 14).padding(.vertical, 6)
					.background(Color.accentColor.opacity(0.18), in: Capsule())
			}
			.buttonStyle(.plain)
			Text("POPStarter and POPS patches are not included and belong to their respective authors.\nCovers from xlenore/ps2-covers and xlenore/psx-covers.")
				.font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
			Text("MIT License · © 2026 Gionnio").font(.caption2).foregroundStyle(.secondary)
		}
		.padding(.horizontal, 24)
		.padding(.top, 34)
		.padding(.bottom, 22)
		.frame(width: 320)
	}
}
