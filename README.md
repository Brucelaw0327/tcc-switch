# tcc-switch

macOS 摄像头 / 麦克风权限的查看与命令行管理工具。

- **查看**：只读扫描两个 TCC.db，列出每个应用已有的全部权限记录。
- **撤销 / 授权**：**仅针对摄像头、麦克风**——撤销生成 `tccutil reset` 命令，授权生成写 TCC.db 的命令（实验性、**非官方**，见下）。
- 其他权限（屏幕录制、完全磁盘访问、辅助功能等）**不在本工具的操作范围内**——因为它们写在 SIP 保护的库或由独立机制管理，命令行写库无效。请到「系统设置 → 隐私与安全性」手动管理。

界面：左边是**用户应用列表**（系统自带应用由 macOS 默认管理，不列出也不提供操作），右边是该应用已有的权限记录（全部可见）；权限下拉框只有摄像头、麦克风两项，点按钮生成命令，复制到自己的终端运行。**工具内部只执行 `sqlite3 -readonly` 只读查询；界面生成的命令一律不执行**。

## 构建

```bash
cd /path/to/tcc-switch      # 换成你 clone 后的实际路径
bash make-app.sh
```

产物：**只有 `dist/tcc-switch.dmg`**。`tcc-switch.app` 只作为 DMG 卷内的内容存在，构建结束后临时目录会删除。脚本会校验当前目录是否含有 `Package.swift` / `Sources/TCCSwitch` / `Resources/Info.plist`，因此在任意路径 clone 都能构建。受限自动化环境里若报 `sandbox_apply: Operation not permitted`，用 `TCCSWITCH_DISABLE_SPM_SANDBOX=1 bash make-app.sh`。

`dist/` 与 `.build/` 默认被 `.gitignore` 忽略。DMG 里是 ad-hoc 签名、未经 Apple 公证的二进制，不随源码提交；Release 中提供的副本仅供本地测试，正式分发请自行用 Developer ID 签名并公证（下载后的打开方式见 Release 说明）。首次运行需要给 App「完全磁盘访问权限」（系统设置 → 隐私与安全性），否则读不到 TCC.db。本地构建的 App 不带下载隔离属性，直接双击即可打开。

## 三条命令（权限仅限摄像头 / 麦克风）

| 按钮 | 命令 | 说明 |
| --- | --- | --- |
| 撤销权限 | `/usr/bin/tccutil reset Camera\|Microphone <bundleID>` | 官方方式。清除决定、回到「未决定」，下次访问重新弹窗。tccutil 只能 reset，不能 grant |
| 授权权限 | 从 App 读取真实 csreq 后 `sqlite3` 写一条完整记录 | 非官方写库（带真实签名要求，实测与系统授权等价），见下 |
| 备份 TCC.db | 备份**用户级** TCC.db 及 WAL/SHM 到 `~/Desktop/TCC-backup-<时间戳>/`，存为 `TCC-user.db*` | 工具只写用户级库，备份它即可回滚；运行写库命令前先做 |

## 关于「授权」

macOS 没有让第三方程序替 App 授权权限的 API。正常流程是 App 自己调用授权 API、你在弹窗点「允许」，由 `tccd` 写入 TCC.db。

**摄像头、麦克风**能通过直接写用户级 TCC.db 生效——但关键在于必须写入**真实的代码签名要求（csreq）**，而不是 `csreq=NULL`。本工具生成的命令会用 `codesign -d -r-` + `csreq` 从目标 App 现场提取签名要求（实测产出的 blob 与系统弹窗授权逐字节一致）；读不到就中止，绝不写无效记录。

**其他权限不在本工具操作范围**：系统级服务（完全磁盘访问、辅助功能等）写在 SIP 保护的库，命令行写不进；屏幕录制在 `replayd` 的 plist；其他用户级服务写库不被采信。这些请到「系统设置 → 隐私与安全性」手动管理。

**仅限在你本人拥有并管理的设备上、用于诊断与恢复自己的权限记录；不得用于他人的机器，也不得用于绕过任何组织的管理策略。**

摄像头/麦克风写库的注意项：
- 命令为 **EXPERIMENTAL**：从 App 路径读取真实 csreq（需要 App 已签名且路径正确），读不到会自行中止；写入后若目标 App 正在运行，需完全退出重开，个别情况可能要与 `tccd` 缓存同步。
- 17 个列名硬编码自 **macOS 26.7.1** 的 `access` 表结构；**其他版本未测试**，列结构不同可能报错或使权限库异常，运行前请核对 `.schema access`。
- 需要终端有「完全磁盘访问权限」；用户级库属主是当前用户，**不需要 sudo**。
- **先备份**。不要对系统级 `/Library/.../TCC.db` 使用。后果自负。
- 更稳妥的官方路径：启动 App → 在 App 内真正使用摄像头/麦克风触发弹窗 → 点允许。

完整威胁模型、使用边界与漏洞报告方式见 [SECURITY.md](SECURITY.md)。

## 边界

- 只读扫描：`sqlite3 -readonly -json -safe`，常量 SQL 零插值；工具自身不执行 INSERT/UPDATE/DELETE。
- 不提权、不弹管理员密码框、不生成临时脚本、不联网、不改 OC/NVRAM/SIP/Gatekeeper/系统设置。
- 命令文本中的 Bundle ID 与服务名经白名单校验，不合规则拒绝生成。
- 唯一写操作是把命令复制到剪贴板。

## 许可

[MIT](LICENSE) · Copyright (c) 2026 tcc-switch contributors。软件按「原样」提供，不含任何担保。
