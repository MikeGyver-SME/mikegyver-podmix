import Foundation

// MARK: - Stitch

/// One video clip in the stitch timeline.
struct ClipItem: Identifiable {
    let id = UUID()
    var url: URL
    var displayName: String
    var duration: Double
    var trimStart: Double = 0
    var trimEnd: Double

    var trimmedDuration: Double { max(0, trimEnd - trimStart) }
}

// MARK: - Mix

/// Loudness presets from Mike's standing mastering standards.
enum LevelPreset: String, CaseIterable, Identifiable {
    case podcast = "Podcast (−16 LUFS / −1 dBTP)"
    case music = "Music (−14 LUFS / −1 dBTP)"

    var id: String { rawValue }
    var targetLUFS: Double { self == .podcast ? -16.0 : -14.0 }
    var ceilingDBTP: Double { -1.0 }
    var shortLabel: String { self == .podcast ? "−16 LUFS" : "−14 LUFS" }
}

/// Voice-track level choice on the Music tab.
enum VoiceLevelOption: String, CaseIterable, Identifiable {
    case asIs = "As-is"
    case podcast = "Podcast −16 LUFS"
    case music = "Music −14 LUFS"

    var id: String { rawValue }

    var preset: LevelPreset? {
        switch self {
        case .asIs: return nil
        case .podcast: return .podcast
        case .music: return .music
        }
    }
}

struct MixSettings {
    var musicVolume: Double = 0.25
    var fadeIn: Double = 2.0
    var fadeOut: Double = 3.0
    var duckingEnabled: Bool = true
    var voiceLevel: VoiceLevelOption = .podcast
}

// MARK: - Convert

enum BitrateOption: Int, CaseIterable, Identifiable {
    case b128 = 128
    case b192 = 192
    case b320 = 320

    var id: Int { rawValue }
    var label: String { "\(rawValue) kbps" }
}

struct ConvertJob: Identifiable {
    let id = UUID()
    var sourceURL: URL
    var sourceName: String
    var status: String = "Queued"
    var progress: Double = 0
    var outputURL: URL?
}

// MARK: - Shared UI

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let text: String
}

enum AppError: LocalizedError {
    case noClips
    case noAudioTrack
    case noVideoTrack(String)
    case exportFailed(String)
    case lameFailed(String)
    case fileError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noClips:
            return "Add at least one clip first."
        case .noAudioTrack:
            return "No audio track found in that file."
        case .noVideoTrack(let name):
            return "No video track in \(name)."
        case .exportFailed(let detail):
            return "Export failed: \(detail)"
        case .lameFailed(let detail):
            return "MP3 encode failed: \(detail)"
        case .fileError(let detail):
            return "File error: \(detail)"
        case .cancelled:
            return "Cancelled."
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}
