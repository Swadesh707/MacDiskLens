import Foundation

struct DiskEntry: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let name: String
    let bytes: Int64
    let allocatedBytes: Int64
    let category: String
    let isDirectory: Bool

    var displayBytes: Int64 { allocatedBytes > 0 ? allocatedBytes : bytes }
}

struct CategoryUsage: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bytes: Int64
    let itemCount: Int
}

struct ScanResult: Sendable {
    let categories: [CategoryUsage]
    let largest: [DiskEntry]
    let scannedItems: Int
    let inaccessibleItems: Int
    let elapsed: TimeInterval
    let totalBytes: Int64
    let availableBytes: Int64
}

actor DiskScanner {
    private let fileManager = FileManager.default

    private let ignoredPrefixes = [
        "/System/Volumes/VM",
        "/System/Volumes/Preboot",
        "/System/Volumes/Update",
        "/private/var/vm",
        "/.Spotlight-V100",
        "/.DocumentRevisions-V100",
        "/.TemporaryItems"
    ]

    func scan() -> ScanResult {
        let started = Date()
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .nameKey
        ]
        var entries: [DiskEntry] = []
        var totals: [String: (bytes: Int64, count: Int)] = [:]
        var inaccessible = 0
        let root = URL(fileURLWithPath: "/")
        let volumeValues = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let totalBytes = Int64(volumeValues?.volumeTotalCapacity ?? 0)
        let availableBytes = Int64(volumeValues?.volumeAvailableCapacityForImportantUsage ?? 0)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                inaccessible += 1
                return true
            }
        ) else {
            return ScanResult(categories: [], largest: [], scannedItems: 0, inaccessibleItems: 1, elapsed: Date().timeIntervalSince(started), totalBytes: totalBytes, availableBytes: availableBytes)
        }

        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            let path = url.path
            if ignoredPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                if url.hasDirectoryPath { enumerator.skipDescendants() }
                continue
            }

            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true { continue }
                let isDirectory = values.isDirectory == true
                let bytes = Int64(values.fileSize ?? 0)
                let allocated = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                guard bytes > 0 || allocated > 0 else { continue }

                let category = Self.category(for: path)
                totals[category, default: (0, 0)].bytes += max(bytes, allocated)
                totals[category, default: (0, 0)].count += 1

                entries.append(DiskEntry(
                    id: path,
                    path: path,
                    name: values.name ?? url.lastPathComponent,
                    bytes: bytes,
                    allocatedBytes: allocated,
                    category: category,
                    isDirectory: isDirectory
                ))
            } catch {
                inaccessible += 1
            }
        }

        let categories = totals.map { CategoryUsage(id: $0.key, name: $0.key, bytes: $0.value.bytes, itemCount: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
        let largest = entries
            .sorted { $0.displayBytes > $1.displayBytes }
            .prefix(500)

        return ScanResult(
            categories: categories,
            largest: Array(largest),
            scannedItems: entries.count,
            inaccessibleItems: inaccessible,
            elapsed: Date().timeIntervalSince(started),
            totalBytes: totalBytes,
            availableBytes: availableBytes
        )
    }

    private static func category(for path: String) -> String {
        let home = NSHomeDirectory()
        let lower = path.lowercased()
        let file = lower.split(separator: "/").last.map(String.init) ?? ""

        if lower.hasPrefix("/applications/") || lower.hasPrefix(home.lowercased() + "/applications/") { return "Applications" }
        if lower.hasPrefix(home.lowercased() + "/downloads/") { return "Downloads" }
        if lower.hasPrefix(home.lowercased() + "/documents/") || lower.hasPrefix(home.lowercased() + "/desktop/") { return "Documents" }
        if lower.contains("/library/developer/") || lower.contains("/xcode/") || lower.contains("/deriveddata/") { return "Developer files" }
        if lower.contains("/library/caches/") || lower.contains("/caches/") { return "Caches" }
        if lower.contains("/library/logs/") || lower.contains("/logs/") { return "Logs" }
        if ["vdi", "vmdk", "vhdx", "qcow2", "iso", "utm", "vmwarevm", "pvm"].contains(where: { file.hasSuffix("." + $0) }) { return "Virtual machines" }
        return "Other"
    }
}
