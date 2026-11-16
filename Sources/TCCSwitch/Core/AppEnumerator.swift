import Foundation

/// 只读枚举本机 .app。纯文件遍历，不加载图标（图标在主线程按需取），不启动任何 App。
enum AppEnumerator {

    static let roots: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        NSString(string: "~/Applications").expandingTildeInPath
    ]

    static func enumerate() -> [AppRecord] {
        var result: [String: AppRecord] = [:]
        let fm = FileManager.default

        for root in roots {
            guard fm.fileExists(atPath: root) else { continue }
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                let relative = url.path.hasPrefix(root)
                    ? String(url.path.dropFirst(root.count))
                    : url.path
                if relative.split(separator: "/").count > 3 {
                    enumerator.skipDescendants()
                    continue
                }

                guard url.pathExtension == "app",
                      let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.isEmpty else { continue }

                let info = bundle.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let isApple = url.path.hasPrefix("/System") || bundleID.hasPrefix("com.apple.")

                if var existing = result[bundleID] {
                    if !existing.paths.contains(url.path) {
                        existing.paths.append(url.path)
                    }
                    result[bundleID] = existing
                } else {
                    result[bundleID] = AppRecord(
                        bundleID: bundleID,
                        name: name,
                        paths: [url.path],
                        isApplePlatform: isApple
                    )
                }
            }
        }

        return result.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
