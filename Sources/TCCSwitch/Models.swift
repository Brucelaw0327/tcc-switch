import Foundation

// MARK: - 库来源

enum Store: String, Hashable, Sendable {
    case user
    case system

    var label: String {
        switch self {
        case .user: return "用户级"
        case .system: return "系统级"
        }
    }
}

// MARK: - 服务名显示

struct Service: Identifiable, Hashable, Sendable {
    let rawValue: String
    let displayName: String
    var id: String { rawValue }

    init(_ rawValue: String, _ displayName: String) {
        self.rawValue = rawValue
        self.displayName = displayName
    }
}

enum ServiceCatalog {
    static let known: [Service] = [
        Service("kTCCServiceMicrophone", "麦克风"),
        Service("kTCCServiceCamera", "摄像头"),
        Service("kTCCServiceScreenCapture", "屏幕录制"),
        Service("kTCCServiceAccessibility", "辅助功能"),
        Service("kTCCServiceSystemPolicyAllFiles", "完全磁盘访问"),
        Service("kTCCServiceListenEvent", "输入监控"),
        Service("kTCCServiceDeveloperTool", "开发者工具"),
        Service("kTCCServiceSystemPolicySysAdminFiles", "系统管理文件"),
        Service("kTCCServiceSystemPolicyDeveloperFiles", "开发者文件"),
        Service("kTCCServiceSystemPolicyRemovableVolumes", "可移动卷"),
        Service("kTCCServiceSystemPolicyNetworkVolumes", "网络卷"),
        Service("kTCCServiceAppleEvents", "自动化"),
        Service("kTCCServiceSystemPolicyDesktopFolder", "桌面文件夹"),
        Service("kTCCServiceSystemPolicyDocumentsFolder", "文稿文件夹"),
        Service("kTCCServiceSystemPolicyDownloadsFolder", "下载文件夹"),
        Service("kTCCServiceAddressBook", "通讯录"),
        Service("kTCCServiceCalendar", "日历"),
        Service("kTCCServiceReminders", "提醒事项"),
        Service("kTCCServicePhotos", "照片"),
        Service("kTCCServicePhotosAdd", "添加照片"),
        Service("kTCCServiceSpeechRecognition", "语音识别"),
        Service("kTCCServiceSiri", "Siri"),
        Service("kTCCServiceBluetoothAlways", "蓝牙"),
        Service("kTCCServiceBluetoothPeripheral", "蓝牙外围"),
        Service("kTCCServiceMediaLibrary", "媒体资料库"),
        Service("kTCCServiceLiverpool", "Liverpool"),
        Service("kTCCServiceUbiquity", "Ubiquity(iCloud)"),
        Service("kTCCServiceWillow", "Willow")
    ]

    static func lookup(_ raw: String) -> Service? {
        known.first { $0.rawValue == raw }
    }

    static func displayName(for raw: String) -> String {
        lookup(raw)?.displayName
            ?? raw.replacingOccurrences(of: "kTCCService", with: "")
    }

    /// tccutil reset 接受的是短名（如 ScreenCapture），不是数据库里的原始
    /// service（kTCCServiceScreenCapture）。此处只做「去前缀 + 严格校验」，
    /// 输出只含字母数字，可直接安全拼进命令。
    static func tccutilName(for raw: String) -> String? {
        guard isValidService(raw) else { return nil }
        let short = raw.replacingOccurrences(of: "kTCCService", with: "")
        guard short.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return short
    }

    /// 命令生成器专用：绝不拼接不合规的 service / bundleID。
    static func isValidService(_ value: String) -> Bool {
        guard value != "All" else { return false }
        return value.range(of: #"^kTCCService[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    static func isValidBundleID(_ value: String) -> Bool {
        // 首位 '-' 会让 tccutil 把 bundleID 当成命令行选项，直接拒绝。
        guard !value.hasPrefix("-") else { return false }
        return value.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil
    }
}

// MARK: - 授权状态

enum AuthState: Hashable, Sendable {
    case noRecord       // 库中无记录
    case denied         // 0
    case unknown        // 1
    case allowed        // 2
    case limited        // 3
    case abnormal(Int)

    init(raw: Int?) {
        guard let raw else { self = .noRecord; return }
        switch raw {
        case 0: self = .denied
        case 1: self = .unknown
        case 2: self = .allowed
        case 3: self = .limited
        default: self = .abnormal(raw)
        }
    }

    var label: String {
        switch self {
        case .noRecord: return "从未请求"
        case .denied: return "已拒绝"
        case .unknown: return "未知(1)"
        case .allowed: return "已允许"
        case .limited: return "受限"
        case .abnormal(let v): return "异常(\(v))"
        }
    }
}

// MARK: - TCC 记录

struct TCCRecord: Identifiable, Hashable, Sendable {
    let store: Store
    let service: String
    let client: String
    let clientType: Int
    let authValue: Int?

    var id: String { "\(store.rawValue)|\(service)|\(client)|\(clientType)" }
    var state: AuthState { AuthState(raw: authValue) }
}

// MARK: - 已安装应用

struct AppRecord: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    var paths: [String]
    var isApplePlatform: Bool

    var id: String { bundleID }
}
