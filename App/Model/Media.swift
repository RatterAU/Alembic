import Foundation

/// What `probe` returns: either a single video or a playlist.
struct ProbeResult: Decodable {
    let kind: String
    let id: String?
    let title: String?
    let uploader: String?
    let duration: Double?
    let thumbnail: String?
    let webpage_url: String?
    let extractor: String?
    let is_live: Bool?
    let chapters: [Chapter]?
    let subtitles: [String]?
    let auto_subtitles: [String]?
    let original_language: String?
    let formats: [MediaFormat]?
    let entries: [PlaylistEntry]?
    let in_playlist: Bool?

    var isPlaylist: Bool { kind == "playlist" }
    var isYouTube: Bool { (extractor ?? "").lowercased().hasPrefix("youtube") }
    /// "YoutubeTab" -> "YouTube", "Twitter" -> "X"
    var siteName: String? {
        guard var name = extractor else { return nil }
        for suffix in ["Tab", "Playlist", "Clip", "Shorts", "Post", "Video"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
        }
        switch name.lowercased() {
        case "youtube": return "YouTube"
        case "twitter": return "X"
        case "tiktok": return "TikTok"
        case "instagram": return "Instagram"
        case "reddit": return "Reddit"
        case "generic": return nil
        default: return name
        }
    }
}

struct Chapter: Decodable, Hashable {
    let title: String?
    let start: Double?
    let end: Double?
}

struct PlaylistEntry: Decodable, Hashable {
    let index: Int
    let id: String?
    let title: String?
    let url: String?
    let duration: Double?
    let thumbnail: String?
    let uploader: String?
}

struct MediaFormat: Decodable, Identifiable, Hashable {
    let format_id: String
    let format_note: String?
    let ext: String?
    let `protocol`: String?
    let vcodec: String?
    let acodec: String?
    let width: Int?
    let height: Int?
    let fps: Double?
    let tbr: Double?
    let vbr: Double?
    let abr: Double?
    let asr: Double?
    let audio_channels: Int?
    let filesize: Double?
    let filesize_approx: Double?
    let dynamic_range: String?
    let language: String?

    var id: String { format_id }
    var hasVideo: Bool { vcodec.map { $0 != "none" } ?? (height != nil) }
    var hasAudio: Bool { acodec.map { $0 != "none" } ?? false }
    var size: Double? { filesize ?? filesize_approx }
    var isDRC: Bool { format_id.contains("drc") || (format_note ?? "").lowercased().contains("drc") }
    var isHDR: Bool { (dynamic_range ?? "SDR") != "SDR" }
    /// "HDR10", "HLG", "DV"… or nil for SDR
    var hdrLabel: String? { isHDR ? (dynamic_range ?? "HDR") : nil }
    var isHLS: Bool { (`protocol` ?? "").contains("m3u8") }

    var videoFamily: VideoCodec {
        let v = (vcodec ?? "").lowercased()
        if v.hasPrefix("av01") || v.hasPrefix("av1") { return .av1 }
        if v.hasPrefix("vp09") || v.hasPrefix("vp9") { return .vp9 }
        if v.hasPrefix("avc") || v.hasPrefix("h264") { return .h264 }
        if v.hasPrefix("hvc") || v.hasPrefix("hev") || v.hasPrefix("h265") { return .hevc }
        return .auto
    }

    var audioFamily: AudioCodec {
        let a = (acodec ?? "").lowercased()
        if a.hasPrefix("opus") { return .opus }
        if a.hasPrefix("mp4a") || a.hasPrefix("aac") { return .aac }
        return .auto
    }

    var videoCodecLabel: String {
        switch videoFamily {
        case .av1: return "AV1"
        case .vp9: return "VP9"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .auto: return (vcodec ?? "?").components(separatedBy: ".").first?.uppercased() ?? "?"
        }
    }

    var audioCodecLabel: String {
        switch audioFamily {
        case .opus: return "Opus"
        case .aac: return "AAC"
        case .auto: return (acodec ?? "?").components(separatedBy: ".").first?.capitalized ?? "?"
        }
    }

    var resolutionLabel: String {
        guard let height else { return "?" }
        let fpsPart = (fps ?? 0) > 30 ? "\(Int((fps ?? 0).rounded()))" : ""
        return "\(height)p\(fpsPart)"
    }

    var bitrate: Double? { tbr ?? vbr ?? abr }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case auto, av1, vp9, hevc, h264
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Best available"
        case .av1: return "AV1"
        case .vp9: return "VP9"
        case .hevc: return "HEVC"
        case .h264: return "H.264 (plays everywhere)"
        }
    }
    var short: String {
        switch self {
        case .auto: return "Auto"
        case .av1: return "AV1"
        case .vp9: return "VP9"
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        }
    }
    /// yt-dlp -S value, for playlist downloads where streams aren't picked one by one
    var sortKey: String? {
        switch self {
        case .auto: return nil
        case .av1: return "vcodec:av01"
        case .vp9: return "vcodec:vp9"
        case .hevc: return "vcodec:h265"
        case .h264: return "vcodec:h264"
        }
    }
}

enum AudioCodec: String, CaseIterable, Identifiable {
    case auto, opus, aac
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Best available"
        case .opus: return "Opus"
        case .aac: return "AAC"
        }
    }
    var sortKey: String? {
        switch self {
        case .auto: return nil
        case .opus: return "acodec:opus"
        case .aac: return "acodec:aac"
        }
    }
}

enum Container: String, CaseIterable, Identifiable {
    case mp4, mkv, webm, mov
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    /// Why these streams can't go in this container (the merge would fail), if they can't.
    func problem(video: MediaFormat?, audio: MediaFormat?) -> String? {
        switch self {
        case .webm:
            if let v = video, ![.vp9, .av1].contains(v.videoFamily) { return "WebM only holds VP9 or AV1 video." }
            if let a = audio, a.audioFamily != .opus, !(a.acodec ?? "").lowercased().hasPrefix("vorbis") {
                return "WebM only holds Opus or Vorbis audio."
            }
        case .mov:
            if let a = audio, a.audioFamily == .opus { return "MOV can't hold Opus audio." }
            if let v = video, [.vp9, .av1].contains(v.videoFamily) { return "MOV can't hold \(v.videoCodecLabel) video." }
        case .mp4, .mkv:
            break
        }
        return nil
    }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case m4a, mp3, opus, flac, wav
    var id: String { rawValue }
    var label: String {
        switch self {
        case .m4a: return "M4A (AAC)"
        case .mp3: return "MP3"
        case .opus: return "Opus"
        case .flac: return "FLAC"
        case .wav: return "WAV"
        }
    }
    var lossless: Bool { self == .flac || self == .wav }
}

enum DownloadMode: String, CaseIterable, Identifiable {
    case video, audio
    var id: String { rawValue }
}

/// Picks streams the way a person would: the best resolution allowed, then the
/// codec they asked for, then the higher bitrate. Used to show exactly what will
/// download, and to pass yt-dlp those exact format IDs.
enum FormatPicker {
    static func videoStreams(_ formats: [MediaFormat]) -> [MediaFormat] {
        formats.filter { $0.hasVideo }
            .sorted { ($0.height ?? 0, $0.fps ?? 0, $0.bitrate ?? 0) > ($1.height ?? 0, $1.fps ?? 0, $1.bitrate ?? 0) }
    }

    static func audioStreams(_ formats: [MediaFormat]) -> [MediaFormat] {
        formats.filter { $0.hasAudio && !$0.hasVideo }
            .sorted { ($0.abr ?? $0.tbr ?? 0) > ($1.abr ?? $1.tbr ?? 0) }
    }

    static func heights(_ formats: [MediaFormat]) -> [Int] {
        Array(Set(formats.filter { $0.hasVideo }.compactMap(\.height))).sorted(by: >)
    }

    static func bestVideo(_ formats: [MediaFormat], maxHeight: Int?, codec: VideoCodec) -> MediaFormat? {
        var pool = formats.filter { $0.hasVideo && !$0.hasAudio }
        if pool.isEmpty { pool = formats.filter { $0.hasVideo } }
        if let maxHeight { pool = pool.filter { ($0.height ?? 0) <= maxHeight } }
        if codec != .auto {
            let matching = pool.filter { $0.videoFamily == codec }
            if !matching.isEmpty { pool = matching }
        }
        let rank: (MediaFormat) -> Int = { f in
            switch f.videoFamily { case .av1: 4; case .vp9: 3; case .hevc: 2; case .h264: 1; case .auto: 0 }
        }
        return pool.max { a, b in
            let ka = (a.height ?? 0, Int((a.fps ?? 0).rounded()), a.isHDR ? 0 : 1, rank(a), a.isHLS ? 0 : 1, a.bitrate ?? 0)
            let kb = (b.height ?? 0, Int((b.fps ?? 0).rounded()), b.isHDR ? 0 : 1, rank(b), b.isHLS ? 0 : 1, b.bitrate ?? 0)
            return ka < kb
        }
    }

    static func bestAudio(_ formats: [MediaFormat], codec: AudioCodec) -> MediaFormat? {
        var pool = formats.filter { $0.hasAudio && !$0.hasVideo }
        let original = pool.filter { ($0.format_note ?? "").lowercased().contains("original") }
        if !original.isEmpty { pool = original }
        let plain = pool.filter { !$0.isDRC }
        if !plain.isEmpty { pool = plain }
        if codec != .auto {
            let matching = pool.filter { $0.audioFamily == codec }
            if !matching.isEmpty { pool = matching }
        }
        return pool.max { ($0.isHLS ? 0 : 1, $0.abr ?? $0.tbr ?? 0) < ($1.isHLS ? 0 : 1, $1.abr ?? $1.tbr ?? 0) }
    }
}

extension Double {
    var bytesText: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
    var durationText: String {
        let s = Int(self.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// "1:20", "80", "1:02:03" -> seconds
func parseTime(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
    guard !parts.isEmpty, parts.count <= 3 else { return nil }
    var total = 0.0
    for part in parts {
        guard let v = Double(part), v >= 0 else { return nil }
        total = total * 60 + v
    }
    return total
}
