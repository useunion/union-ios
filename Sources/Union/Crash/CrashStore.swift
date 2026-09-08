import Foundation

/// Everything the handler could not collect, written while the process was healthy.
///
/// The split is forced by what a signal handler may call. `UIDevice.batteryLevel` is main-thread
/// only, free memory needs a mach call that allocates, and reading the loaded images takes dyld's
/// lock — none of it can happen at crash time. So this is sampled beforehand and paired with the
/// record by filename.
///
/// The honest consequence, and the panel says it: the device state is the **last sample before the
/// crash**, not the state at the instant of death. It is refreshed on every lifecycle transition and
/// alongside breadcrumbs, so on a normal crash it is seconds old. `uptime_ms` and `in_foreground` are
/// the exceptions — the handler can read those itself, so they come from the record.
struct CrashContextSidecar: Sendable {
    var sessionId: String?
    var context: DeviceContext
    var images: [BinaryImageWire]
    var state: DeviceStateWire
    /// Written by the app through `Union.setCrashKey`. App-authored, so kept apart from `state`.
    var customKeys: [String: String]?
    var sampledAt: Int64
}

/**
 * The part of the sidecar that changes, stored on its own.
 *
 * The image list is the large half — five hundred entries of path, uuid and load address — and it is
 * fixed for the life of the process, while the session id, the device sample and the custom keys
 * change while the app runs. One file would mean rewriting a hundred kilobytes every time a
 * breadcrumb refreshed the sample, on the main thread of somebody's app.
 */
struct CrashContextFile: Codable, Sendable {
    var sessionId: String?
    var context: DeviceContext
    var state: DeviceStateWire
    var customKeys: [String: String]?
    var sampledAt: Int64
}

/// One crash we hold on disk: the record and the sidecar that explains it.
struct PendingCrash: Sendable {
    var id: String
    var record: URL
    var sidecar: URL
}

/// The crash directory, and the two questions it has to answer: what is waiting to be sent, and
/// where does the handler write the next one.
final class CrashStore: @unchecked Sendable {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
    }

    /// `Application Support/Union/<keyHash>/crash`, beside the event queue and excluded from backups
    /// for the same reason: a restored device would otherwise replay another device's crashes.
    static func standard(directoryName: String) throws -> CrashStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Union", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("crash", isDirectory: true)
        return try CrashStore(directory: dir)
    }

    func recordURL(id: String) -> URL { directory.appendingPathComponent("\(id).ucr") }
    func sidecarURL(id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    func imagesURL(id: String) -> URL { directory.appendingPathComponent("\(id).images.json") }
    func reportURL(id: String) -> URL { directory.appendingPathComponent("\(id).report.json") }

    func writeContext(_ file: CrashContextFile, id: String) throws {
        try WireCoding.encoder.encode(file).write(to: sidecarURL(id: id), options: .atomic)
    }

    func writeImages(_ images: [BinaryImageWire], id: String) throws {
        try WireCoding.encoder.encode(images).write(to: imagesURL(id: id), options: .atomic)
    }

    /// `nil` when the two halves are not both there — a record we cannot explain is not a report we
    /// can attribute to a version, a session or a build, so it is discarded rather than sent thin.
    func loadSidecar(id: String) -> CrashContextSidecar? {
        guard let contextData = try? Data(contentsOf: sidecarURL(id: id)),
              let file = try? WireCoding.decoder.decode(CrashContextFile.self, from: contextData)
        else { return nil }
        let images = (try? Data(contentsOf: imagesURL(id: id)))
            .flatMap { try? WireCoding.decoder.decode([BinaryImageWire].self, from: $0) } ?? []
        return CrashContextSidecar(sessionId: file.sessionId, context: file.context, images: images,
                                   state: file.state, customKeys: file.customKeys,
                                   sampledAt: file.sampledAt)
    }

    /**
     * Crashes from previous launches.
     *
     * A zero-length record is the ordinary outcome — the file is created at install and only written
     * to if the process dies — so it is deleted quietly rather than reported as a corrupt report.
     * `current` is excluded because the handler still owns that descriptor.
     */
    func pending(excluding current: String?) -> [PendingCrash] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.fileSizeKey]))
            ?? []
        var found: [PendingCrash] = []
        for url in files where url.pathExtension == "ucr" {
            let id = url.deletingPathExtension().lastPathComponent
            if id == current { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size == 0 {
                discard(id: id)
                continue
            }
            found.append(PendingCrash(id: id, record: url, sidecar: sidecarURL(id: id)))
        }
        return found
    }

    /// Reports the SDK built itself — non-fatals and hangs — already in wire shape.
    func pendingReports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(".report.json") }.sorted { $0.path < $1.path }
    }

    func discard(id: String) {
        try? FileManager.default.removeItem(at: recordURL(id: id))
        try? FileManager.default.removeItem(at: sidecarURL(id: id))
        try? FileManager.default.removeItem(at: imagesURL(id: id))
    }

    func discard(url: URL) { try? FileManager.default.removeItem(at: url) }

    func write(report: CrashReportWire) throws {
        let data = try WireCoding.encoder.encode(report)
        try data.write(to: reportURL(id: report.crashId), options: .atomic)
    }

    /**
     * Keeps the directory from growing without bound.
     *
     * A device that crashes on launch, every launch, and never reaches a network would otherwise
     * accumulate one report per launch forever. The oldest are dropped first: a crash loop repeats
     * the same issue, so the newest reports say the same thing and are the ones still worth a
     * fingerprint against the current build.
     */
    func trim(max: Int) {
        let all = ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? [])
            .filter { $0.pathExtension == "ucr" || $0.lastPathComponent.hasSuffix(".report.json") }
        guard all.count > max else { return }
        let sorted = all.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        for url in sorted.prefix(all.count - max) {
            if url.pathExtension == "ucr" {
                discard(id: url.deletingPathExtension().lastPathComponent)
            } else {
                discard(url: url)
            }
        }
    }
}
