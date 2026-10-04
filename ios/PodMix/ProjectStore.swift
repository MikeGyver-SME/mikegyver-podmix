import AVFoundation
import Foundation

/// Shared app state: staged inbox files, clip timeline, music choice,
/// mix settings, and convert jobs.
@MainActor
final class ProjectStore: ObservableObject {
    @Published var clips: [ClipItem] = []
    @Published var musicURL: URL?
    @Published var musicName = ""
    @Published var videoURL: URL?
    @Published var videoName = ""
    @Published var settings = MixSettings()
    @Published var convertJobs: [ConvertJob] = []
    @Published var lastStitchedURL: URL?
    @Published var lastMixURL: URL?

    let inboxURL: URL
    let exportURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        inboxURL = docs.appendingPathComponent("PodMix-Inbox", isDirectory: true)
        exportURL = docs.appendingPathComponent("PodMix-Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)
    }

    /// Copies picked files into the app inbox so AVFoundation keeps access.
    func stage(_ urls: [URL]) -> [URL] {
        urls.compactMap { url in
            let dest = inboxURL.appendingPathComponent(uniqueName(for: url.lastPathComponent))
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                return dest
            } catch {
                return nil
            }
        }
    }

    private func uniqueName(for name: String) -> String {
        var candidate = name
        var i = 1
        while FileManager.default.fileExists(atPath: inboxURL.appendingPathComponent(candidate).path) {
            candidate = "\(i)-\(name)"
            i += 1
        }
        return candidate
    }

    func addClips(_ urls: [URL]) async {
        for url in stage(urls) {
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            clips.append(ClipItem(url: url,
                                  displayName: url.lastPathComponent,
                                  duration: seconds,
                                  trimEnd: seconds))
        }
    }

    func exportDestination(base: String, ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeBase = base.replacingOccurrences(of: " ", with: "-")
        return exportURL.appendingPathComponent("\(safeBase)-\(formatter.string(from: Date())).\(ext)")
    }

    func updateJob(_ id: UUID, _ mutate: (inout ConvertJob) -> Void) {
        if let idx = convertJobs.firstIndex(where: { $0.id == id }) {
            mutate(&convertJobs[idx])
        }
    }

    func clearInbox() {
        try? FileManager.default.removeItem(at: inboxURL)
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        clips = []
        musicURL = nil; musicName = ""
        videoURL = nil; videoName = ""
        lastStitchedURL = nil; lastMixURL = nil
    }
}
