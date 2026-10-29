import AppKit
import SwiftUI

/// Records one key combination and reports it as a Ghostty trigger (see ``KeyTrigger``).
///
/// Click to start recording, then press the combination. Escape cancels; the clear button
/// removes the shortcut. Only combinations ``KeyTrigger`` can name are accepted, so the
/// result is always in the recorder grammar.
struct KeyRecorderView: View {
    /// The current trigger, or nil for none.
    let trigger: String?
    /// Called with the recorded trigger, or nil when cleared.
    let onChange: (String?) -> Void
    var placeholder: String = "Record Shortcut"
    /// Extra validation (e.g. the Workspace policy). Return an error to reject.
    var validate: (String) -> String? = { _ in nil }

    @State private var recording = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: recording ? 2 : 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                    Text(label)
                        .foregroundColor(trigger == nil && !recording ? .secondary : .primary)
                        .monospaced(trigger != nil && !recording)
                    if recording {
                        KeyCaptureRepresentable(
                            onKey: { recorded in
                                recording = false
                                if let message = validate(recorded) {
                                    error = message
                                } else {
                                    error = nil
                                    onChange(recorded)
                                }
                            },
                            onCancel: { recording = false },
                            onUnsupported: { error = "That key can't be used in a shortcut." }
                        )
                    }
                }
                .frame(width: 160, height: 22)
                .contentShape(Rectangle())
                .onTapGesture { recording.toggle(); error = nil }
                .accessibilityLabel(Text("Shortcut: \(label)"))
                .accessibilityAddTraits(.isButton)

                if trigger != nil {
                    Button {
                        error = nil
                        onChange(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
    }

    private var label: String {
        if recording { return "Type shortcut…" }
        guard let trigger else { return placeholder }
        return KeyTrigger.displayString(trigger)
    }
}

/// An invisible first responder that captures the next key press.
private struct KeyCaptureRepresentable: NSViewRepresentable {
    let onKey: (String) -> Void
    let onCancel: () -> Void
    let onUnsupported: () -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onKey = onKey
        view.onCancel = onCancel
        view.onUnsupported = onUnsupported
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.onKey = onKey
        nsView.onCancel = onCancel
        nsView.onUnsupported = onUnsupported
    }
}

final class KeyCaptureView: NSView {
    var onKey: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onUnsupported: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        onCancel?()
        return super.resignFirstResponder()
    }

    // Command combinations arrive here before keyDown; claim them so the menu doesn't.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if Int(event.keyCode) == 0x35 /* kVK_Escape */ && mods.isDisjoint(with: [.command, .control, .option, .shift]) {
            onCancel?()
            return
        }
        let characters = event.characters(byApplyingModifiers: [])
        guard let trigger = KeyTrigger.trigger(keyCode: Int(event.keyCode), characters: characters, modifiers: mods) else {
            onUnsupported?()
            return
        }
        onKey?(trigger)
    }
}
