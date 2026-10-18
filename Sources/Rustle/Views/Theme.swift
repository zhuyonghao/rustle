import AppKit
import SwiftUI

enum Palette {
    static let background = Color(nsColor: .textBackgroundColor)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let raised = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let text = Color.primary
    static let secondary = Color.secondary
    static let accent = Color.accentColor
    static let amber = Color.orange
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct IconButton: View {
    var symbol: String
    var label: String
    var active = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(active ? Palette.accent : Palette.secondary)
        .help(label).accessibilityLabel(label)
    }
}

struct CapsuleLabel: View {
    var text: String
    var color = Palette.secondary
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct SectionCaption: View {
    var title: String
    var symbol: String
    var body: some View {
        Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
    }
}

/// Uses the system focus ring, clear button and search accessibility behavior.
struct NativeSearchField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}
