//
//  Downloader.swift
//  Resumable, background-safe model download into Application Support.
//

import Foundation

@MainActor
final class Downloader: NSObject, ObservableObject {

    struct Progress: Equatable {
        var filename: String = ""
        var received: Int64 = 0
        var total: Int64 = 0
        var overall: Double = 0        // 0...1 across the whole preset
        var finished: Bool = false
        var error: String? = nil
    }

    @Published private(set) var progress = Progress()

    private var task: URLSessionDownloadTask?
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    nonisolated static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func localURL(for file: ModelFile) -> URL {
        modelsDirectory.appendingPathComponent(file.filename)
    }

    nonisolated static func isPresent(_ file: ModelFile) -> Bool {
        // Treat anything within 2% of the expected size as complete; exact
        // byte counts drift when a repo is re-quantised.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localURL(for: file).path),
              let size = attrs[.size] as? Int64 else { return false }
        return size > Int64(Double(file.bytes) * 0.98)
    }

    nonisolated static func presetReady(_ preset: ModelManifest.Preset) -> Bool {
        preset.files.allSatisfy(isPresent)
    }

    nonisolated static func bytesOnDisk(_ preset: ModelManifest.Preset) -> Int64 {
        preset.files.reduce(0) { acc, f in
            let p = localURL(for: f).path
            let s = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0
            return acc + s
        }
    }

    /// Downloads every missing file of `preset`, one at a time.
    func download(_ preset: ModelManifest.Preset) {
        guard task == nil else { return }
        let missing = preset.files.filter { !Self.isPresent($0) }
        guard !missing.isEmpty else {
            progress = Progress(finished: true)
            return
        }
        let grandTotal = preset.files.reduce(Int64(0)) { $0 + $1.bytes }
        let already = preset.files.reduce(Int64(0)) { acc, f in
            acc + (Self.isPresent(f) ? f.bytes : min(fileSize(f), f.bytes))
        }
        chain(missing, index: 0, grandTotal: grandTotal, done: already)
    }

    private func fileSize(_ f: ModelFile) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: Self.localURL(for: f).path))?[.size] as? Int64) ?? 0
    }

    private func chain(_ files: [ModelFile], index: Int, grandTotal: Int64, done: Int64) {
        guard index < files.count else {
            progress.finished = true
            task = nil
            return
        }
        let file = files[index]
        progress.filename = file.filename
        progress.error = nil

        // Partial file from a previous run → HTTP Range resume.
        var request = URLRequest(url: file.downloadURL)
        let partial = Self.localURL(for: file).appendingPathExtension("part")
        let existing = ((try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? Int64) ?? 0
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let t = session.downloadTask(with: request)
        t.taskDescription = file.filename
        task = t
        self.pending = (files, index, grandTotal, done, file)
        t.resume()
    }

    private var pending: (files: [ModelFile], index: Int, grandTotal: Int64, done: Int64, file: ModelFile)?

    func cancel() {
        task?.cancel()
        task = nil
    }
}

extension Downloader: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            guard let p = self.pending else { return }
            let dest = Downloader.localURL(for: p.file)
            // Range resume produces a *fragment*; append instead of replace.
            let fragment = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? Int64) ?? 0
            self.append(location: location, to: dest, replacing: fragment >= p.file.bytes * 98 / 100)
            let done = p.done + fragment
            if p.index + 1 < p.files.count {
                self.chain(p.files, index: p.index + 1, grandTotal: p.grandTotal, done: done)
            } else {
                self.progress.overall = 1
                self.progress.finished = true
                self.task = nil
                self.pending = nil
            }
        }
    }

    private func append(location: URL, to dest: URL, replacing: Bool) {
        let fm = FileManager.default
        if replacing || !fm.fileExists(atPath: dest.path) {
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            // Keep a bit of headroom off the 4 GB page-cache path.
            try? fm.moveItem(at: location, to: dest)
        } else {
            if let out = try? FileHandle(forWritingTo: dest) {
                out.seekToEndOfFile()
                if let input = try? FileHandle(forReadingFrom: location) {
                    while autoreleasepool(invoking: {
                        let chunk = input.readData(ofLength: 8 << 20)
                        if chunk.isEmpty { return false }
                        out.write(chunk)
                        return true
                    }) {}
                    try? input.close()
                }
                try? out.close()
            }
            try? FileManager.default.removeItem(at: location)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard let p = self.pending else { return }
            self.progress.received = totalBytesWritten
            self.progress.total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : p.file.bytes
            let sofar = p.done + totalBytesWritten
            self.progress.overall = min(1, Double(sofar) / Double(max(1, p.grandTotal)))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.progress.error = error.localizedDescription
            self.progress.finished = true
            self.task = nil
            self.pending = nil
        }
    }
}
