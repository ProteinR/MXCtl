import SwiftUI

/// An on/off switch drawn by SwiftUI itself, looking like the small system one, label on the left
/// and the switch on the right as in a settings form. The system switch (macOS 26 glass) took
/// ~100 MB of graphics memory for a moment whenever a settings page with switches appeared
/// (145 MB instead of 40–55 MB); MeetRec found the same.
struct LightSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
            Spacer(minLength: 8)
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.15))
                .frame(width: 30, height: 17)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .padding(1.5)
                }
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? "Вкл." : "Выкл.")
                .accessibilityAction { configuration.isOn.toggle() }
        }
    }
}
