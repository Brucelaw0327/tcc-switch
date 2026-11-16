import Foundation

/// B 类「仅生成、未执行」模板：备份两个 TCC.db 及其 WAL/SHM。
/// 纯常量文本，无任何来自 App / Bundle ID / 用户输入的插值 → 零注入面。
enum BackupTemplate {

    static let command = """
dst="$HOME/Desktop/TCC-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dst"; for s in "" "-wal" "-shm"; do f="$HOME/Library/Application Support/com.apple.TCC/TCC.db$s"; [ -f "$f" ] && { cp -p "$f" "$dst/TCC-user.db$s" 2>/dev/null || cp "$f" "$dst/TCC-user.db$s" || echo "失败: $f"; }; done; echo "=== 备份目录: $dst ==="; ls -la "$dst"; shasum -a 256 "$dst"/*
"""
}
