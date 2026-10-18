import SwiftUI

private struct DeleteRecordingActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var deleteRecordingAction: (() -> Void)? {
        get { self[DeleteRecordingActionKey.self] }
        set { self[DeleteRecordingActionKey.self] = newValue }
    }
}

struct RecordingCommands: Commands {
    @FocusedValue(\.deleteRecordingAction) private var deleteRecording

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("删除记录及内容…", role: .destructive) { deleteRecording?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(deleteRecording == nil)
        }
    }
}
