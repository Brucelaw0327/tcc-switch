import Foundation

enum TCCDatabase {
    static let userPath: String =
        NSString(string: "~/Library/Application Support/com.apple.TCC/TCC.db").expandingTildeInPath
    static let systemPath: String =
        "/Library/Application Support/com.apple.TCC/TCC.db"
}

struct DatabaseOutcome: Sendable {
    let readable: Bool
    let records: [TCCRecord]
    let error: String?
    let note: String?
}

/// 只读读取两个 TCC.db。
/// SQL 为编译期常量、零插值；连接用 sqlite3 的 -readonly -safe 保证绝不可写。
enum TCCDatabaseReader {

    private static let requiredColumns = ["service", "client", "client_type", "auth_value"]
    private static let selectSQL = "SELECT service, client, client_type, auth_value FROM access;"

    static func read(store: Store, runner: CommandRunner) async -> DatabaseOutcome {
        let path = store == .user ? TCCDatabase.userPath : TCCDatabase.systemPath

        guard FileManager.default.fileExists(atPath: path) else {
            return DatabaseOutcome(readable: false,
                                   records: [], error: "数据库文件不存在", note: nil)
        }

        // 先探测表结构，兼容不同 macOS 版本的 access 列变化
        let pragma = await runner.run(CommandSpec(
            executable: "/usr/bin/sqlite3",
            arguments: ["-readonly", "-json", "-safe", path, "PRAGMA table_info(access);"]
        ))
        guard pragma.succeeded else {
            return await failed(path: path, runner: runner,
                                firstError: pragma.excerpt)
        }

        let columns = jsonArray(pragma.stdout).compactMap { str($0["name"]) }
        guard requiredColumns.allSatisfy({ columns.contains($0) }) else {
            return DatabaseOutcome(readable: false,
                                   records: [],
                                   error: "access 表结构不兼容：缺少 service/client/client_type/auth_value",
                                   note: nil)
        }

        let select = await runner.run(CommandSpec(
            executable: "/usr/bin/sqlite3",
            arguments: ["-readonly", "-json", "-safe", path, selectSQL]
        ))
        guard select.succeeded else {
            return DatabaseOutcome(readable: false,
                                   records: [], error: "只读查询失败：\(select.excerpt)", note: nil)
        }

        let records = jsonArray(select.stdout).map { row -> TCCRecord in
            TCCRecord(
                store: store,
                service: str(row["service"]) ?? "",
                client: str(row["client"]) ?? "",
                clientType: int(row["client_type"]) ?? 0,
                authValue: int(row["auth_value"])
            )
        }

        return DatabaseOutcome(readable: true,
                               records: records, error: nil, note: nil)
    }

    /// -readonly 打不开（常见于 WAL/SHM 缺失）时，尝试 immutable 只读 URI。
    private static func failed(path: String,
                               runner: CommandRunner,
                               firstError: String) async -> DatabaseOutcome {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:\(encoded)?mode=ro&immutable=1"
        let retry = await runner.run(CommandSpec(
            executable: "/usr/bin/sqlite3",
            arguments: ["-readonly", "-json", "-safe", uri, "SELECT count(*) AS n FROM access;"]
        ))
        if retry.succeeded {
            return DatabaseOutcome(readable: false,
                                   records: [],
                                   error: "只读主连接失败，但 immutable URI 可读：\(firstError)",
                                   note: "可能遗漏未 checkpoint 的 WAL 记录，结果仅供参考")
        }
        return DatabaseOutcome(readable: false,
                               records: [], error: firstError,
                               note: "读取 TCC.db 需要「完全磁盘访问权限」；请在系统设置中为 tcc-switch 开启后重启 App")
    }

    // MARK: - JSON 取值工具

    private static func jsonArray(_ text: String) -> [[String: Any]] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [[String: Any]] else { return [] }
        return array
    }

    private static func str(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
