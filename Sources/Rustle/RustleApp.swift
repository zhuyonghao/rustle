import AppKit
import SwiftUI

@main
@MainActor
struct RustleApp: App {
    @NSApplicationDelegateAdaptor(RustleApplicationDelegate.self) private var applicationDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 820)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            RecordingCommands()
            CommandGroup(replacing: .newItem) {
                Button(store.liveSession?.phase == .recording ? "结束录音" : "开始实时转录") {
                    if store.liveSession?.phase == .recording { store.stopLiveRecording() }
                    else { store.startLiveRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.processingID != nil || (store.liveSession != nil && store.liveSession?.phase != .recording))
                Divider()
                Button("导入音频或视频…") {
                    NotificationCenter.default.post(name: Notification.Name("Rustle.importFiles"), object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("导入媒体链接…") {
                    NotificationCenter.default.post(name: Notification.Name("Rustle.importLink"), object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }

        WindowGroup("思维导图", for: UUID.self) { $recordID in
            if let recordID, let record = store.recordings.first(where: { $0.id == recordID }), let map = record.contentInsights?.mindMap {
                MindMapView(record: record, map: map).environmentObject(store)
            } else {
                ContentUnavailableView("暂无思维导图", systemImage: InsightFeature.mindMap.symbol, description: Text("请在记录中生成思维导图后再打开。"))
                    .frame(minWidth: 800, minHeight: 480)
            }
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            AppSettingsView()
                .environmentObject(store)
        }
    }
}

@MainActor
private final class RustleApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
