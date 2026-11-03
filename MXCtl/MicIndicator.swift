import AppKit
import CoreAudio
import SwiftUI

/// While the microphone is muted: a red tab with a crossed-out mic on the right edge of every
/// screen, a third of the way down, above everything (full-screen apps too), clicks pass through.
/// As Logi Options+ showed it. It follows the mic itself, so muting from Control Center shows it too.
@MainActor
final class MicIndicator {
    static let shared = MicIndicator()

    private var panels: [NSPanel] = []
    private var watchedDevice: AudioDeviceID?
    private var isShown = false
    private static let size = NSSize(width: 44, height: 40)

    func start() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in
            MainActor.assumeIsolated { MicIndicator.shared.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MicIndicator.shared.removePanels()
                MicIndicator.shared.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        watch(Microphone.defaultInput())
        let muted = Microphone.isMuted()
        if muted != isShown { Log.info("Mic \(muted ? "muted" : "unmuted"): indicator \(muted ? "shown" : "hidden")", "mic") }
        isShown = muted
        if muted { show() } else { removePanels() }
    }

    /// Mute and volume changes of the current input device (from anywhere) update the indicator.
    private func watch(_ device: AudioDeviceID?) {
        guard let device, device != watchedDevice else { return }
        watchedDevice = device
        for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(device, &address) else { continue }
            AudioObjectAddPropertyListenerBlock(device, &address, .main) { _, _ in
                MainActor.assumeIsolated {
                    // Only the device being watched now counts.
                    if MicIndicator.shared.watchedDevice == device { MicIndicator.shared.refresh() }
                }
            }
        }
    }

    private func show() {
        if panels.isEmpty { panels = NSScreen.screens.map(makePanel) }
        for panel in panels { panel.orderFrontRegardless() }
    }

    private func removePanels() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let frame = screen.frame
        let origin = NSPoint(x: frame.maxX - Self.size.width,
                             y: frame.maxY - frame.height / 3 - Self.size.height / 2)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // Above menus, full-screen apps and the Dock.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: MicMutedTab().frame(width: Self.size.width, height: Self.size.height))
        return panel
    }
}

private struct MicMutedTab: View {
    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            Image(systemName: "mic")
                .font(.system(size: 17, weight: .medium))
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .heavy))
                .offset(y: -1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.94, green: 0.16, blue: 0.29))
    }
}
