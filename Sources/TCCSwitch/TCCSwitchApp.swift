import AppKit
import Foundation
import SwiftUI

@main
struct TCCSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - 状态：只看权限 / 撤销 / 授权

@MainActor
final class AppState: ObservableObject {
    @Published var records: [TCCRecord] = []
    @Published var appNames: [String: String] = [:]
    @Published var clients: [String] = []

    private var appPaths: [String: String] = [:]
    private var iconCache: [String: NSImage] = [:]
    @Published var systemAppIDs: Set<String> = []
    @Published var selectedClient: String?
    @Published var selectedService = "kTCCServiceCamera"
    @Published var search = ""
    @Published var command = ""
    @Published var note = "点上方按钮生成命令。所有命令只生成文本，本工具不执行。"
    @Published var status = "正在读取…"
    @Published var diagnostics = ""
    @Published var copied = false

    private let runner = CommandRunner()

    /// 工具只支持查看全部权限 + 授权/撤销摄像头与麦克风。
    /// 权限下拉框固定只有这两项，不从扫描到的记录动态扩展。
    var services: [String] {
        return ["kTCCServiceCamera", "kTCCServiceMicrophone"]
    }

    var visibleClients: [String] {
        guard !search.isEmpty else { return clients }
        let query = search.lowercased()
        return clients.filter {
            $0.lowercased().contains(query) || displayName($0).lowercased().contains(query)
        }
    }

    /// 只列用户应用；com.apple.* 等系统组件由 macOS 默认管理，不提供操作入口。
    var userClients: [String] {
        visibleClients.filter { !systemAppIDs.contains($0) }
    }

    var rowsForSelected: [TCCRecord] {
        guard let client = selectedClient else { return [] }
        return records.filter { $0.client == client }
            .sorted {
                ServiceCatalog.displayName(for: $0.service) < ServiceCatalog.displayName(for: $1.service)
            }
    }

    func displayName(_ id: String) -> String {
        appNames[id] ?? URL(fileURLWithPath: id).lastPathComponent
    }

    /// 主线程按需取图标并缓存，避免扫描阶段批量调用 AppKit。
    func icon(for client: String) -> NSImage? {
        if let cached = iconCache[client] { return cached }
        guard let path = appPaths[client] else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[client] = image
        return image
    }

    func load() async {
        status = "正在读取用户级 TCC.db…"
        let user = await TCCDatabaseReader.read(store: .user, runner: runner)
        status = "正在读取系统级 TCC.db…"
        let system = await TCCDatabaseReader.read(store: .system, runner: runner)
        status = "正在枚举已安装应用…"
        let apps = await Task.detached { AppEnumerator.enumerate() }.value

        var names: [String: String] = [:]
        var paths: [String: String] = [:]
        var systemIDs = Set<String>()
        for app in apps {
            names[app.bundleID] = app.name
            if let first = app.paths.first { paths[app.bundleID] = first }
            if app.isApplePlatform { systemIDs.insert(app.bundleID) }
        }
        appNames = names
        appPaths = paths
        iconCache.removeAll()
        records = user.records + system.records

        var all = Set(names.keys)
        for record in records {
            all.insert(record.client)
            if record.client.hasPrefix("com.apple.") || record.client.hasPrefix("/System") {
                systemIDs.insert(record.client)
            }
        }
        systemAppIDs = systemIDs
        clients = all.sorted {
            displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending
        }

        status = "用户级 \(user.records.count) 条 / 系统级 \(system.records.count) 条 · 共 \(userClients.count) 个应用"
        if selectedClient == nil || !userClients.contains(selectedClient!) {
            selectedClient = userClients.first
        }

        var lines: [String] = []
        for (label, outcome) in [("用户级", user), ("系统级", system)] where !outcome.readable {
            if let e = outcome.error { lines.append("\(label)：\(e)") }
            if let n = outcome.note { lines.append("  \(n)") }
        }
        diagnostics = lines.joined(separator: "\n")
        if !diagnostics.isEmpty {
            status += " · 部分库读取异常（见下方诊断）"
        }
    }

    // MARK: - 三条命令（只生成文本）

    func makeBackup() {
        command = BackupTemplate.command
        note = """
【仅生成、未执行】把 用户级 + 系统级 两个 TCC.db 及存在的 WAL/SHM 备份到
~/Desktop/TCC-backup-<时间戳>/，末尾 ls -la + shasum 供核对。
运行任何写库命令前建议先做。不改动原件、不提权。
"""
        copied = false
    }

    func makeRevoke() {
        guard let client = selectedClient,
              ServiceCatalog.isValidBundleID(client),
              let serviceName = ServiceCatalog.tccutilName(for: selectedService) else {
            command = ""
            note = "选中的应用或权限不合规，拒绝生成命令。"
            copied = false
            return
        }
        // tccutil 接受短名（Camera / Microphone），不是库里的 kTCCServiceCamera。
        command = "/usr/bin/tccutil reset \(serviceName) \(client)"
        note = """
【官方方式 · 仅生成、未执行】撤销 = 清除该 App 在该权限上的决定，状态回到「未决定」，
下次真正访问摄像头/麦克风时会重新弹窗。tccutil 只有 reset，不能授权。
"""
        copied = false
    }

    func makeGrant() {
        guard let client = selectedClient,
              ServiceCatalog.isValidBundleID(client),
              ServiceCatalog.isValidService(selectedService) else {
            command = ""
            note = "选中的应用或权限不合规，拒绝生成命令。"
            copied = false
            return
        }

        // 写一条带真实 csreq 的完整记录（等价于系统弹窗授权产物）。
        // 找不到 App 路径就无法取签名要求 —— 拒绝生成，绝不退回 csreq=NULL。
        guard let appPath = appPaths[client] else {
            command = ""
            note = "找不到该 App 的安装路径（可能未安装或不在扫描目录），无法读取签名要求，拒绝生成命令。请改用系统设置手动授权。"
            copied = false
            return
        }

        command = GrantCommand.make(service: selectedService, client: client, appPath: appPath)
        note = """
【摄像头/麦克风 · EXPERIMENTAL 非官方方式 · 仅生成、未执行 · 有风险】
• 仅限本人拥有并管理的设备，用于诊断与恢复自己的权限记录；不得用于他人机器。
• 命令会从 App 现场读取真实代码签名要求（csreq）写入，而非空的 csreq=NULL —— 实测这样才与系统授权等价、能被 tccd 采信。
• 若读不到签名要求，命令会自行中止，绝不写入无效记录。
• 17 个列名来自 macOS 26.7.1 的 access 表，其他版本未测试；运行前先核对 .schema access。
• 需要终端具备「完全磁盘访问权限」；不需要 sudo（用户级库属主是当前用户）。
• 先执行「备份 TCC.db」；不要对系统级库使用；后果自负。
• 更稳妥的官方路径：启动 App → 在 App 内真正使用摄像头/麦克风触发弹窗 → 点允许。
详见 README.md / SECURITY.md。
"""
        copied = false
    }

    func copy() {
        guard !command.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
    }
}

// MARK: - 界面

struct RootView: View {
    @StateObject private var store = AppState()

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("搜索应用 / Bundle ID", text: $store.search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List {
                    Section("应用 (\(store.userClients.count))") {
                        ForEach(store.userClients, id: \.self) { client in
                            clientRow(client)
                        }
                    }
                }
            }
            .frame(minWidth: 280)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(store.status).font(.caption).foregroundStyle(.secondary)

                    if !store.diagnostics.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("读取诊断").font(.caption.weight(.medium)).foregroundStyle(.red)
                            Text(store.diagnostics)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if let client = store.selectedClient {
                        Text(store.displayName(client)).font(.title2.bold())
                        Text(client).font(.caption.monospaced()).textSelection(.enabled)
                    } else {
                        Text("选择左侧应用").font(.title2)
                    }

                    Divider()

                    HStack {
                        Picker("权限", selection: $store.selectedService) {
                            ForEach(store.services, id: \.self) { service in
                                Text(ServiceCatalog.displayName(for: service)).tag(service)
                            }
                        }
                        .frame(width: 210)
                        Button("撤销权限") { store.makeRevoke() }
                        Button("授权权限") { store.makeGrant() }
                        Button("备份 TCC.db") { store.makeBackup() }
                        Button("刷新") { Task { await store.load() } }
                    }

                    HStack {
                        Text("生成的命令（复制到自己的终端运行，本工具不执行）").font(.caption)
                        Spacer()
                        Button("复制命令") { store.copy() }
                        if store.copied {
                            Text("已复制").font(.caption).foregroundStyle(.green)
                        }
                    }

                    Text(store.command.isEmpty ? "点上方按钮生成命令" : store.command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text(store.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Text("该应用已有的权限记录").font(.headline)
                    if store.rowsForSelected.isEmpty {
                        Text("无记录（从未申请过任何权限）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.rowsForSelected) { row in
                            HStack {
                                Text(ServiceCatalog.displayName(for: row.service))
                                    .frame(width: 170, alignment: .leading)
                                Text(row.state.label)
                                    .frame(width: 90, alignment: .leading)
                                Text(row.store.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .task { await store.load() }
    }

    private func clientRow(_ client: String) -> some View {
        Button {
            store.selectedClient = client
        } label: {
            HStack(spacing: 8) {
                if let image = store.icon(for: client) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: "app.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.displayName(client)).lineLimit(1)
                    Text(client)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(store.selectedClient == client
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear)
    }
}
