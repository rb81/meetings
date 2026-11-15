import Darwin
import Foundation
import os

/// Looks after the cache macOS keeps for the speech models.
///
/// The first time a model is loaded, Core ML optimizes it for this Mac and saves the result in
/// `~/Library/Caches/<app>/com.apple.e5rt.e5bundlecache`, so later launches are quick. If the app quits or is stopped
/// while that's happening, the half-finished copy is left behind. For the speech model that's about 450 MB each time,
/// and Core ML never cleans them up. This removes those leftovers, and the copies made for an older macOS.
enum CacheJanitor {
    private static let log = Logger(subsystem: "com.rakan.Meetings", category: "storage")
    private static let folderName = "com.apple.e5rt.e5bundlecache"

    /// Where Core ML keeps its optimized models for this app. There can be more than one.
    static var cacheFolders: [URL] {
        let identifier = Bundle.main.bundleIdentifier ?? "madness.meetings"
        var roots: [URL] = []
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(caches.appendingPathComponent(identifier, isDirectory: true))
        }
        if let temporary = darwinCacheDirectory {
            roots.append(temporary.appendingPathComponent(identifier, isDirectory: true))
        }
        return roots
            .map { $0.appendingPathComponent(folderName, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Cleans up in the background, so launching isn't slowed down.
    static func sweepInBackground() {
        Task.detached(priority: .utility) {
            let freed = sweep()
            if freed > 0 {
                log.info("Removed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file), privacy: .public) of leftover model cache")
            }
        }
    }

    /// Removes half-finished copies from processes that have ended, and copies made for an older macOS.
    /// Returns how many bytes were freed.
    @discardableResult
    static func sweep() -> Int64 {
        var freed: Int64 = 0
        for folder in cacheFolders {
            freed += removeStaleBuilds(in: folder)
            for leftover in abandonedCopies(in: folder) {
                freed += remove(leftover)
            }
        }
        return freed
    }

    /// Empties the cache, apart from anything a running copy of the app is writing right now.
    /// The models are optimized again the next time they load, which makes that launch slower.
    @discardableResult
    static func clear() -> Int64 {
        var freed: Int64 = 0
        for folder in cacheFolders {
            let busy = halfFinishedCopies(in: folder).filter { writerProcess(of: $0.lastPathComponent).map(isRunning) == true }
            freed += removeEverything(in: folder, keeping: busy)
        }
        return freed
    }

    /// The space the cache takes up now.
    static func size() -> Int64 {
        cacheFolders.reduce(0) { $0 + allocatedSize(of: $1) }
    }

    /// The space taken by everything inside `url`.
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Finding leftovers

    /// The process that was writing a half-finished copy, read from names like `ABC.tmp.2246_0.bundle`.
    static func writerProcess(of name: String) -> pid_t? {
        guard let match = name.firstMatch(of: /\.tmp\.(\d+)_\d+/) else { return nil }
        return pid_t(match.1)
    }

    /// Half-finished copies whose process has ended.
    static func abandonedCopies(in folder: URL, isRunning: (pid_t) -> Bool = isRunning) -> [URL] {
        halfFinishedCopies(in: folder).filter { item in
            writerProcess(of: item.lastPathComponent).map { !isRunning($0) } == true
        }
    }

    /// Every half-finished copy, finished writing or not. They sit a few folders deep, under the macOS build and a hash.
    static func halfFinishedCopies(in folder: URL) -> [URL] {
        var found: [URL] = []
        var queue: [(URL, Int)] = [(folder, 0)]
        while let (current, depth) = queue.popLast() {
            for item in contents(of: current) {
                if writerProcess(of: item.lastPathComponent) != nil {
                    found.append(item)
                } else if depth < 3, isDirectory(item), item.pathExtension != "bundle" {
                    queue.append((item, depth + 1))
                }
            }
        }
        return found
    }

    /// Folders made for an older macOS. Only removed once a folder for this macOS exists, so a naming change in a
    /// future macOS can never make this wipe the cache in use.
    private static func removeStaleBuilds(in folder: URL) -> Int64 {
        guard let build = osBuild else { return 0 }
        let builds = contents(of: folder).filter(isDirectory)
        guard builds.contains(where: { $0.lastPathComponent == build }) else { return 0 }

        return builds
            .filter { $0.lastPathComponent != build && looksLikeBuild($0.lastPathComponent) }
            .reduce(0) { $0 + remove($1) }
    }

    /// macOS build numbers look like `25B78` or `26B131`.
    static func looksLikeBuild(_ name: String) -> Bool {
        name.wholeMatch(of: /\d{2}[A-Z]\d{1,4}[a-z]?/) != nil
    }

    /// Removes everything inside `folder` except `busy` items and the folders that lead to them.
    private static func removeEverything(in folder: URL, keeping busy: [URL]) -> Int64 {
        let busyPaths = busy.map(\.standardizedFileURL.path)
        return contents(of: folder).reduce(0) { total, item in
            let path = item.standardizedFileURL.path
            if busyPaths.contains(path) { return total }
            if busyPaths.contains(where: { $0.hasPrefix(path + "/") }) {
                return total + removeEverything(in: item, keeping: busy)
            }
            return total + remove(item)
        }
    }

    // MARK: - System

    static func isRunning(_ process: pid_t) -> Bool {
        if process == getpid() { return true }
        // Signal 0 checks the process exists without touching it. EPERM means it exists but belongs to someone else.
        return kill(process, 0) == 0 || errno == EPERM
    }

    static var osBuild: String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }

    private static var darwinCacheDirectory: URL? {
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, length) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    }

    private static func remove(_ url: URL) -> Int64 {
        let size = isDirectory(url) ? allocatedSize(of: url) : allocatedSize(ofFile: url)
        do {
            try FileManager.default.removeItem(at: url)
            return size
        } catch {
            log.error("Couldn't remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    private static func allocatedSize(ofFile url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
}
