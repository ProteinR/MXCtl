import AppKit
import SwiftUI

/// A short notice after a key press (mic muted, etc.), in the style of the macOS Tahoe HUD: a small
/// glass panel in the top right corner of the screen with the pointer. Made on first use only.
@MainActor
final class OSD {
    static let shared = OSD()

    final class Model: ObservableObject {
        @Published var symbol = "mic.fill"
        @Published var title = ""
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 240, height: 56)
    private static let margin: CGFloat = 12

    func show(symbol: String, title: String) {
        model.symbol = symbol
        model.title = title
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.size.width - Self.margin,
                                         y: visible.maxY - Self.size.height - Self.margin))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OSDView(model: model).frame(width: Self.size.width, height: Self.size.height))
        return panel
    }
}

private struct OSDView: View {
    @ObservedObject var model: OSD.Model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)
                .contentTransition(.symbolEffect(.replace))
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(GlassBackground())
    }
}

private struct GlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
