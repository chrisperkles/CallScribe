import AppKit
import SwiftUI

/// The "want to record this?" and "call ended, stop?" popups. A floating panel
/// rather than a system notification: notification buttons stay hidden until
/// hovered and the banner is gone in five seconds, which is not enough while
/// someone is joining a call.
///
/// The panel never activates CallScribe, so the call app keeps keyboard focus.
@MainActor
final class CallPrompt {

    struct Content {
        var symbol: String
        var tint: Color
        var title: String
        var detail: String
        var confirm: String
        var cancel: String
        var timeout: Duration

        static func callStarted(app: String) -> Content {
            Content(symbol: "phone.fill", tint: .green,
                    title: "Record this call?", detail: "\(app) is using the microphone.",
                    confirm: "Record", cancel: "Not now", timeout: .seconds(25))
        }

        /// Stays longer, and ignoring it keeps recording: a call app that lets
        /// go of the mic for a moment must never cost the rest of the recording.
        static func callEnded(app: String) -> Content {
            Content(symbol: "phone.down.fill", tint: .red,
                    title: "Call ended — stop recording?", detail: "\(app) released the microphone.",
                    confirm: "Stop", cancel: "Keep going", timeout: .seconds(60))
        }
    }

    private var panel: NSPanel?
    private var expiry: Task<Void, Never>?

    func show(_ content: Content, onConfirm: @escaping () -> Void) {
        dismiss()

        let view = CallPromptView(
            content: content,
            confirm: { [weak self] in
                self?.dismiss()
                onConfirm()
            },
            dismiss: { [weak self] in self?.dismiss() })

        let hosting = FirstMouseHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Keep the prompt out of a shared screen where the OS honours it.
        panel.sharingType = .none

        // Top-right of the screen being used, where notifications appear.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 16,
                y: visible.maxY - panel.frame.height - 16))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        expiry = Task { [weak self] in
            try? await Task.sleep(for: content.timeout)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        expiry?.cancel()
        expiry = nil
        panel?.close()
        panel = nil
    }
}

/// Borderless panels refuse key status by default, which would swallow the
/// first click on a button.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CallPromptView: View {
    let content: CallPrompt.Content
    let confirm: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: content.symbol)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(content.tint.gradient, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title).font(.headline)
                Text(content.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Button(action: confirm) {
                    Text(content.confirm).frame(width: 72)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(action: dismiss) {
                    Text(content.cancel).frame(width: 72)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5))
    }
}
