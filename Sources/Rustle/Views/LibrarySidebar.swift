import SwiftUI

struct LibrarySidebar: View {
    @EnvironmentObject var store: AppStore
    var onDelete: (Recording) -> Void

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(placeholder: "搜索记录和内容", text: $store.search)
                .frame(height: 24).padding(.horizontal, 14).padding(.vertical, 12)
            List(selection: $store.selectedID) {
                Section("资料库") {
                    ForEach(LibraryFilter.allCases) { filter in
                        Button {
                            store.filter = filter
                            if !store.visibleRecordings.contains(where: { $0.id == store.selectedID }) {
                                store.selectedID = store.visibleRecordings.first?.id
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: filterSymbol(filter)).foregroundStyle(Palette.accent).frame(width: 18)
                                Text(filter.rawValue)
                                Spacer()
                                Text("\(count(filter))").monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.system(size: 13, weight: store.filter == filter ? .semibold : .regular))
                            .padding(.vertical, 3).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(store.filter == filter ? Palette.accent.opacity(0.08) : Color.clear)
                        .accessibilityAddTraits(store.filter == filter ? .isSelected : [])
                    }
                }
                Section(store.filter.rawValue) {
                    ForEach(store.visibleRecordings) { record in
                        recordingRow(record).tag(record.id)
                            .contextMenu {
                                Button(record.isFavorite ? "取消收藏" : "收藏记录", systemImage: record.isFavorite ? "star.slash" : "star") {
                                    store.toggleFavorite(record.id)
                                }
                                Divider()
                                Button("删除记录及内容…", systemImage: "trash", role: .destructive) { onDelete(record) }
                            }
                    }
                    if store.visibleRecordings.isEmpty {
                        Text(store.search.isEmpty ? "这里还没有记录" : "没有找到匹配的记录")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                if let record = store.selected { onDelete(record) }
            }
            .overlay(alignment: .bottom) { Divider() }
            HStack(spacing: 8) {
                Label("\(store.recordings.count) 条记录", systemImage: "internaldrive")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: "gearshape", label: "设置") { store.showSettingsSheet = true }
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
        .navigationTitle("Rustle")
    }

    private func recordingRow(_ record: Recording) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.sourceKind.symbol).font(.system(size: 15)).frame(width: 22, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.title).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(record.createdAt.formatted(.dateTime.month().day()))
                    Text("·")
                    Text(record.status == .processing ? store.processingStage : record.status == .failed ? "处理失败" : record.duration.durationLabel).lineLimit(1)
                    Spacer(minLength: 0)
                    if record.isFavorite { Image(systemName: "star.fill").font(.system(size: 10)) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if record.status == .processing, let fraction = store.processingProgress?.fraction {
                    ProgressView(value: fraction).controlSize(.mini)
                }
            }
        }.padding(.vertical, 7)
    }

    private func filterSymbol(_ filter: LibraryFilter) -> String {
        switch filter { case .all: "tray.full"; case .favorites: "star" }
    }
    private func count(_ filter: LibraryFilter) -> Int {
        switch filter {
        case .all: store.recordings.count
        case .favorites: store.recordings.filter(\.isFavorite).count
        }
    }
}
