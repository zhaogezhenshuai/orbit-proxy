import AppKit
import OrbitCore
import SwiftUI
import UniformTypeIdentifiers

/// "Node Sources" section of the settings window: the sources, which one is active, and
/// add / edit / remove. Changes apply at once; they aren't part of the Save button's form.
struct SourcesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var editor: SourceEditor.Mode?
    @State private var importing = false
    @State private var busy: String?
    @State private var error: String?
    @State private var removing: NodeSource?

    var body: some View {
        Section {
            ForEach(model.settings.sources) { src in
                SourceRow(source: src, active: src.id == model.settings.activeSourceID, count: model.sourceNodeCounts[src.id],
                          busy: busy == src.id, removable: busy == nil && !model.updating,
                          onActivate: { activate(src) }, onEdit: { editor = .edit(src) }, onRemove: { removing = src })
            }
            if model.settings.sources.isEmpty {
                Text(L("还没有节点来源，先添加一个。", "No node source yet; add one to get started."))
                    .foregroundStyle(.secondary)
            }
            HStack {
                if busy == "import" { Spinner(size: 12) }
                Spacer()
                Menu {
                    Button(L("订阅地址…", "Subscription URL…")) { editor = .addURL }
                    Button(L("导入文件…", "Import File…")) { importing = true }
                    Button(L("粘贴节点…", "Paste Nodes…")) { editor = .addPaste }
                } label: {
                    Label(L("添加来源", "Add Source"), systemImage: "plus")
                }
                .fixedSize()
                .disabled(busy != nil)
            }
        } header: {
            Text(L("节点来源", "Node Sources"))
        } footer: {
            Text(L("同一时间使用一个来源，点左侧圆圈切换。来源的改动会立即生效，不需要点「保存」。",
                   "One source is in use at a time; click its circle to switch. Source changes apply at once, without Save."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editor) { mode in
            SourceEditor(mode: mode) { editor = nil }.environmentObject(model)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.yaml, .json, .plainText, .data]) { result in
            if case .success(let url) = result { importFile(url) }
        }
        .alert(L("无法完成", "Couldn't Finish"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("好", "OK")) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog(L("删除「\(removing?.name ?? "")」？", "Remove “\(removing?.name ?? "")”?"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L("删除", "Remove"), role: .destructive) {
                if let src = removing { Task { await model.removeSource(src.id) } }
                removing = nil
            }
        } message: {
            Text(L("它的节点会从 Orbit 中移除；订阅地址或导入的内容不会再保留。",
                   "Its nodes leave Orbit; the subscription URL or imported content isn't kept."))
        }
    }

    private func activate(_ src: NodeSource) {
        guard busy == nil, src.id != model.settings.activeSourceID else { return }
        busy = src.id
        Task {
            await model.activateSource(src.id)
            busy = nil
        }
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            error = L("无法读取文件 \(url.lastPathComponent)", "Can't read \(url.lastPathComponent)")
            return
        }
        let name = url.lastPathComponent
        let src = NodeSource(name: NodeSource.defaultName(kind: .file, fileName: name), kind: .file, fileName: name)
        busy = "import"
        Task {
            do { try await model.addSource(src, content: data) } catch {
                self.error = L("导入「\(name)」失败：", "Couldn't import “\(name)”: ") + describe(error)
            }
            busy = nil
        }
    }
}

private struct SourceRow: View {
    let source: NodeSource
    let active: Bool
    let count: Int?
    let busy: Bool
    /// Off while a source is being fetched, which would otherwise finish for a deleted source.
    let removable: Bool
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onActivate) {
                Group {
                    if busy { Spinner(size: 14) } else {
                        Image(systemName: active ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(active ? Color.accentColor : Color.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(active ? L("正在使用", "In use") : L("使用这个来源", "Use this source"))
            Image(systemName: source.kind.icon).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name.isEmpty ? source.kind.title : source.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help(L("编辑", "Edit"))
            Button(action: onRemove) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(L("删除", "Remove"))
                .disabled(!removable)
        }
    }

    private var detail: String {
        let what: String
        switch source.kind {
        case .url: what = source.url
        case .file: what = source.fileName
        case .paste: what = L("粘贴的节点", "Pasted nodes")
        }
        guard let count else { return what }
        return L("\(count) 个节点 · ", "\(count) nodes · ") + what
    }
}

extension NodeSource.Kind {
    var icon: String {
        switch self {
        case .url: return "link"
        case .file: return "doc.text"
        case .paste: return "doc.on.clipboard"
        }
    }

    var title: String {
        switch self {
        case .url: return L("订阅地址", "Subscription URL")
        case .file: return L("导入的文件", "Imported file")
        case .paste: return L("粘贴的节点", "Pasted nodes")
        }
    }
}

/// Sheet for adding a subscription URL or pasted nodes, or editing any source.
struct SourceEditor: View {
    enum Mode: Identifiable {
        case addURL, addPaste, edit(NodeSource)

        var id: String {
            switch self {
            case .addURL: return "addURL"
            case .addPaste: return "addPaste"
            case .edit(let s): return s.id
            }
        }
    }

    @EnvironmentObject var model: AppModel
    let mode: Mode
    let onDone: () -> Void
    @State private var source: NodeSource
    @State private var pasted = ""
    @State private var originalPasted = ""
    @State private var working = false
    @State private var error: String?

    init(mode: Mode, onDone: @escaping () -> Void) {
        self.mode = mode
        self.onDone = onDone
        switch mode {
        case .addURL: _source = State(initialValue: NodeSource(name: "", kind: .url))
        case .addPaste: _source = State(initialValue: NodeSource(name: "", kind: .paste))
        case .edit(let s): _source = State(initialValue: s)
        }
    }

    private var adding: Bool { if case .edit = mode { return false } else { return true } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(L("名称", "Name")) {
                        TextField("", text: $source.name, prompt: Text(defaultName.isEmpty ? L("可选", "Optional") : defaultName))
                            .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
                    }
                    switch source.kind {
                    case .url: urlFields
                    case .paste: pasteField
                    case .file:
                        LabeledContent(L("文件", "File"), value: source.fileName)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 10) {
                if working {
                    Spinner(size: 12)
                    Text(source.kind == .url ? L("正在获取订阅…", "Fetching…") : L("正在解析…", "Parsing…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("取消", "Cancel"), action: onDone)
                    .buttonStyle(BarButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button(adding ? L("添加", "Add") : L("保存", "Save"), action: submit)
                    .buttonStyle(BarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || working)
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 460, height: source.kind == .file ? 220 : source.kind == .paste ? 370 : 350)
        .onAppear {
            if case .edit(let s) = mode, s.kind == .paste {
                pasted = model.pastedText(s)
                originalPasted = pasted
            }
        }
    }

    @ViewBuilder private var urlFields: some View {
        FieldRow(title: L("订阅地址", "Subscription URL"), text: $source.url, prompt: "https://…")
        VStack(alignment: .leading, spacing: 5) {
            Text("User-Agent")
            HStack(spacing: 6) {
                TextField("", text: $source.userAgent).textFieldStyle(.roundedBorder).labelsHidden()
                Menu(L("预设", "Presets")) {
                    ForEach(SubscriptionFetcher.userAgentPresets, id: \.value) { p in
                        Button(p.name) { source.userAgent = p.value }
                    }
                }
                .fixedSize()
            }
            Text(L("有些服务商按客户端返回不同的节点列表。节点不全时，可以在预设里换成其他客户端的 UA 再试。",
                   "Some providers send different node lists to different clients. If nodes are missing, try another client's UA from Presets."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        LabeledContent(L("自动更新间隔", "Auto-update every")) {
            HStack(spacing: 6) {
                IntField(value: $source.autoUpdateHours, range: 0...168)
                Text(L("小时", "hours")).foregroundStyle(.secondary)
            }
        }
        Text(source.autoUpdateHours == 0
             ? L("已关闭自动更新，只在手动点「更新订阅」时更新。", "Auto-update is off; the subscription updates only when you click Update.")
             : L("可输入 0-168；0 表示不自动更新", "Enter 0–168; 0 turns off auto-update."))
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var pasteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("节点", "Nodes"))
                Spacer()
                Button(L("从剪贴板粘贴", "Paste from Clipboard")) {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        pasted = pasted.isEmpty ? s : pasted + (pasted.hasSuffix("\n") ? "" : "\n") + s
                    }
                }
                .buttonStyle(.borderless)
            }
            TextEditor(text: $pasted)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                .overlay(alignment: .topLeading) {
                    if pasted.isEmpty {
                        Text("vless://…\nss://…").font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
            Text(L("每行一个分享链接；也可以粘贴 Clash YAML 或 sing-box JSON。", "One share link per line; Clash YAML or sing-box JSON also work."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var defaultName: String { NodeSource.defaultName(kind: source.kind, url: source.url, fileName: source.fileName) }

    private var canSubmit: Bool {
        switch source.kind {
        case .url: return !source.url.trimmingCharacters(in: .whitespaces).isEmpty
        case .paste: return !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file: return true
        }
    }

    private func submit() {
        var src = source
        src.url = src.url.trimmingCharacters(in: .whitespaces)
        src.name = src.name.trimmingCharacters(in: .whitespaces)
        if src.name.isEmpty { src.name = defaultName.isEmpty ? src.kind.title : defaultName }
        let content = src.kind == .paste && (adding || pasted != originalPasted) ? Data(pasted.utf8) : nil
        working = true
        error = nil
        Task {
            do {
                if adding { try await model.addSource(src, content: content) } else { try await model.editSource(src, content: content) }
                onDone()
            } catch {
                self.error = describe(error)
            }
            working = false
        }
    }
}
