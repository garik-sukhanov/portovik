import SwiftUI

struct LogsView: View {
    let target: LogsTarget
    @Environment(Monitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "text.alignleft")
                Text("Логи · \(target.title)").font(.headline)
                Text("последние 500 строк").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                Button { monitor.copy(text) } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(verbatim: text.isEmpty && !loading ? "Логов нет." : text)
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: text) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task { await load() }
    }

    private func load() async {
        loading = true
        text = await monitor.loadLogs(target.id)
        loading = false
    }
}
