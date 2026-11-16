#!/bin/bash
# tcc-switch 构建：只产出 dist/tcc-switch.dmg。
# .app 仅作为 DMG 卷内的临时内容存在，构建结束后删除；dist/ 不保留单独的 .app。
# 注意：Swift 模块/产物名用合法标识符 TCCSwitch，对外可执行文件名为 tcc-switch。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# 目录校验：不绑定任何绝对路径，clone 到任意位置都能构建；
# 同时确保下面的 rm -rf 只作用于本项目 dist/ 下的临时目录。
if [ ! -f "$ROOT/Package.swift" ] || [ ! -d "$ROOT/Sources/TCCSwitch" ] || [ ! -f "$ROOT/Resources/Info.plist" ]; then
    echo "目录校验失败：请在 tcc-switch 项目根目录运行（需含 Package.swift / Sources/TCCSwitch / Resources/Info.plist）" >&2
    exit 1
fi

DIST="$ROOT/dist"
STAGING="$DIST/dmg-staging"           # DMG 源目录，构建后删除
APP="$STAGING/tcc-switch.app"         # 只在卷内存在
DMG="$DIST/tcc-switch.dmg"

echo "==> 关闭旧实例（仅限 tcc-switch 自身进程名）"
if pgrep -x "tcc-switch" > /dev/null 2>&1; then
    pkill -x "tcc-switch" || true
    sleep 1
fi

echo "==> swift build -c release"
# 默认使用 SwiftPM 标准沙箱。仅在受限自动化环境（嵌套 sandbox-exec 被拒）里按需关闭 manifest 沙箱；
# 这不影响生成出来的 App 的运行时权限或签名。
SPM_SANDBOX_FLAG=""
if [ "${TCCSWITCH_DISABLE_SPM_SANDBOX:-0}" = "1" ]; then
    SPM_SANDBOX_FLAG="--disable-sandbox"
    echo "    （适配受限构建环境：禁用 SwiftPM manifest 沙箱）"
fi
swift build -c release $SPM_SANDBOX_FLAG --package-path "$ROOT" --scratch-path "$ROOT/.build"

BIN="$(find "$ROOT/.build" -type f -name TCCSwitch -perm -111 2>/dev/null | head -n 1)"
if [ -z "$BIN" ]; then
    echo "找不到构建产物，请检查 swift build 输出" >&2
    exit 1
fi
echo "    二进制: $BIN"

echo "==> 装配 DMG 卷内容（临时 staging）"
rm -rf "$STAGING"
rm -f "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/tcc-switch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 固定 identifier 的 ad-hoc 签名"
codesign --force --sign - --identifier "local.tccswitch.gui" --timestamp=none "$APP"

echo "==> 卷内附加文件"
cp "$ROOT/README.md" "$STAGING/README.md"
cp "$ROOT/LICENSE" "$STAGING/LICENSE.txt"
cp "$ROOT/SECURITY.md" "$STAGING/SECURITY.md"
cat > "$STAGING/安装前必读.txt" <<'TXT'
tcc-switch 安装说明
================
1. 把 tcc-switch.app 拖到旁边的 Applications（应用程序）文件夹，
就是 macOS 软件的标准安装方式。
2. 本工具需要读取 TCC.db：请在
「系统设置 → 隐私与安全性 → 完全磁盘访问权限」
3. 重新构建会改变签名 cdhash，完全磁盘访问权限需要重新授权。
4. 本工具只读：内部只执行 sqlite3 只读查询，不执行界面生成的命令、
不写 TCC.db、不修改任何系统配置。
界面生成的命令只提供文本，需要你复制到自己的终端运行。
运行任何写库命令之前，建议先点「备份 TCC.db」。
详细安全声明与验收方法见同目录 README.md、SECURITY.md、LICENSE.txt。
TXT
ln -s /Applications "$STAGING/Applications"

echo "==> 校验"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP" 2>/dev/null || {
    echo "签名校验失败，中止 DMG 生成" >&2
    exit 1
}
codesign -dvvv --requirements - "$APP" 2>&1 | head -n 20 || true

echo "==> 生成 DMG（分发容器，非签名/公证）"
hdiutil create -volname "tcc-switch" -srcfolder "$STAGING" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGING"

echo "Created: $DMG"
echo "提示：首次运行需在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」添加从 DMG 安装后的 tcc-switch.app，然后完全退出重开。"
