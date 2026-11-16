import Foundation

/// 摄像头/麦克风的「授权」命令：从目标 App 读取真实代码签名要求（csreq），
/// 写一条与系统弹窗授权等价的完整记录。
///
/// 背景：直接写 csreq=NULL 的记录在签名校验正常的 Mac 上通常不被 tccd 采信。
/// 实测（macOS 26）：从 App 用 `codesign -d -r-` + `csreq` 取到的 blob 与
/// 系统授权产生的 csreq 逐字节一致，因此这里在命令里现场生成它。
///
/// 零插值安全：service/client 固定来自白名单 value+校验过的 bundleID，
/// appPath 来自本机已枚举的 .app 绝对路径；命令本身不含任何自由文本输入。
enum GrantCommand {

    static func make(service: String, client: String, appPath: String) -> String {
        """
        APP='\(appPath)'
        DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
        echo "==> 从 App 读取代码签名要求: $APP"
        REQ_HEX="$(codesign -d -r- "$APP" 2>/dev/null \\
          | sed -n 's/^designated => //p' \\
          | csreq -r /dev/stdin -b /dev/stdout 2>/dev/null \\
          | xxd -p | tr -d '\\n' | tr 'a-f' 'A-F')"
        if [ -z "$REQ_HEX" ]; then
          echo "错误：读不到该 App 的代码签名要求（应用未签名或路径不符？）。" >&2
          echo "已取消：不写入 csreq=NULL 的无效记录。" >&2
          exit 1
        fi
        echo "读取到 csreq: $((${#REQ_HEX}/2)) 字节"
        sqlite3 "$DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified, pid, pid_version, boot_uuid, last_reminded) VALUES ('\(service)', '\(client)', 0, 2, 4, 1, X'$REQ_HEX', NULL, NULL, 'UNUSED', NULL, 0, CAST(strftime('%s','now') AS INTEGER), NULL, NULL, 'UNUSED', 0);"
        echo "完成。若目标 App 正在运行，请完全退出后重开。"
        """
    }
}
