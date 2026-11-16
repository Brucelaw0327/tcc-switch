import Foundation

struct CommandSpec: Sendable {
    let executable: String
    let arguments: [String]
    var timeout: TimeInterval = 10
}

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }

    var excerpt: String {
        let combined = stdout.isEmpty ? stderr : (stderr.isEmpty ? stdout : stdout + "\n[stderr]\n" + stderr)
        return String(combined.prefix(1200))
    }
}

/// 工具内唯一外部命令出口。
/// 简化版运行时只调用 /usr/bin/sqlite3 做只读查询；全部 argv 传参，绝不拼 shell 字符串。
actor CommandRunner {

    static let allowedExecutables: Set<String> = [
        "/usr/bin/sqlite3"
    ]

    private let maxOutputBytes = 2 * 1024 * 1024

    func run(_ spec: CommandSpec) -> CommandResult {
        guard Self.allowedExecutables.contains(spec.executable) else {
            return CommandResult(status: -1, stdout: "",
                                 stderr: "拒绝执行：可执行文件不在白名单 -> \(spec.executable)")
        }
        for arg in spec.arguments where arg.contains("\u{00}") {
            return CommandResult(status: -1, stdout: "", stderr: "拒绝执行：参数含非法字符")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "",
                                 stderr: "启动失败：\(error.localizedDescription)")
        }

        let timeoutItem = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + spec.timeout, execute: timeoutItem)
        process.waitUntilExit()
        timeoutItem.cancel()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData.prefix(maxOutputBytes), encoding: .utf8) ?? ""
        let err = String(data: errData.prefix(maxOutputBytes), encoding: .utf8) ?? ""

        return CommandResult(status: process.terminationStatus, stdout: out, stderr: err)
    }
}
