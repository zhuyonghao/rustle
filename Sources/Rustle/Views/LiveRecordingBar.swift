import SwiftUI

struct LiveRecordingBar: View {
    @EnvironmentObject var store: AppStore
    let session: LiveRecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if session.phase == .recording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                } else { ProgressView().controlSize(.small) }
                Text(session.phase == .recording ? "正在录音与转写" : session.phase == .finishing ? "正在完成转写" : "准备实时转录")
                    .fontWeight(.semibold)
                Text(session.duration.timestamp).monospacedDigit()
                Spacer()
                if store.selectedID != session.id, session.phase != .preparing {
                    Button("查看录音") { store.filter = .all; store.search = ""; store.selectedID = session.id }
                }
                if session.phase == .recording {
                    Button(action: store.stopLiveRecording) { Label("结束录音", systemImage: "stop.fill") }.buttonStyle(.borderedProminent)
                } else {
                    Button(session.phase == .preparing ? "取消" : "停止剩余转写", action: store.cancelLiveTranscription)
                }
            }
            if session.phase == .recording {
                ProgressView(value: session.level).tint(.red).accessibilityLabel("麦克风输入音量")
            }
            Text(session.detail).foregroundStyle(Palette.secondary)
            Text(session.provider == .whisperCpp ? "本地 Whisper · 音频在本机识别，显示速度取决于模型与设备性能" : "百炼 ASR · 录音分段上传至已配置的服务，按服务商用量计费")
                .foregroundStyle(Palette.secondary)
        }
        .font(.system(size: 11)).padding(16).background(Palette.accent.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
    }
}
