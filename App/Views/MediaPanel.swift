import SwiftUI

/// A single video: what it is, and exactly what to download.
struct MediaPanel: View {
    @Environment(Store.self) private var store
    let info: ProbeResult
    let url: String
    let onQueued: () -> Void

    @AppStorage("mode") private var mode: DownloadMode = .video
    @AppStorage("videoCodec") private var videoCodec: VideoCodec = .auto
    @AppStorage("audioCodec") private var audioCodec: AudioCodec = .auto
    @AppStorage("container") private var container: Container = .mp4
    @AppStorage("audioFormat") private var audioFormat: AudioFormat = .m4a
    @AppStorage("mp3Quality") private var mp3Quality = "0"
    @AppStorage("embedThumbnail") private var embedThumbnail = true
    @AppStorage("embedMetadata") private var embedMetadata = true
    @AppStorage("sponsorBlock") private var sponsorBlock = false

    @State private var maxHeight: Int? = nil
    @State private var manual = false
    @State private var manualVideo: MediaFormat?
    @State private var manualAudio: MediaFormat?
    @State private var showStreams = false
    @State private var trim = false
    @State private var trimStart = ""
    @State private var trimEnd = ""
    @State private var subtitleLang: String? = nil
    @State private var subtitleAuto = false
    @State private var showAllSubtitles = false

    private var formats: [MediaFormat] { info.formats ?? [] }

    // MARK: selection

    private var pickedVideo: MediaFormat? {
        if manual { return manualVideo }
        // With "Auto", pick codecs the chosen container can hold.
        let codec = videoCodec == .auto && container == .mov ? .h264 : videoCodec
        return FormatPicker.bestVideo(formats, maxHeight: maxHeight, codec: codec)
    }

    private var videoModeAudioCodec: AudioCodec {
        guard audioCodec == .auto else { return audioCodec }
        switch container {
        case .mov: return .aac
        case .webm: return .opus
        default: return .auto
        }
    }

    private var pickedAudio: MediaFormat? {
        if manual { return manualAudio }
        if mode == .video, let v = pickedVideo, v.hasAudio { return nil }
        if mode == .audio {
            // Prefer a stream already in the target format, so it's saved without re-encoding.
            let codec: AudioCodec = switch audioFormat {
            case .m4a: .aac
            case .opus: .opus
            default: .auto
            }
            return FormatPicker.bestAudio(formats, codec: codec)
        }
        return FormatPicker.bestAudio(formats, codec: videoModeAudioCodec)
    }

    private var formatSpec: String {
        switch mode {
        case .audio:
            if let a = pickedAudio { return "\(a.format_id)/ba/b" }
            return "ba/b"
        case .video:
            switch (pickedVideo, pickedAudio) {
            case let (v?, a?): return "\(v.format_id)+\(a.format_id)/bv*+ba/b"
            case let (v?, nil):
                if v.hasAudio { return "\(v.format_id)/bv*+ba/b" }
                // "No separate audio" chosen by hand: exactly that, silent.
                return manual ? v.format_id : "\(v.format_id)+ba/\(v.format_id)/b"
            default: return "bv*+ba/b"
            }
        }
    }

    private var estimatedSize: Double? {
        let parts = mode == .audio ? [pickedAudio] : [pickedVideo, pickedAudio]
        let sizes = parts.compactMap { $0 }.map(\.size)
        guard !sizes.isEmpty, sizes.allSatisfy({ $0 != nil }) else { return nil }
        var total = sizes.compactMap { $0 }.reduce(0, +)
        if trim, trimProblem == nil, let d = info.duration, d > 0 {
            let s = parseTime(trimStart) ?? 0
            let e = parseTime(trimEnd) ?? d
            total *= max(0, min(e, d) - s) / d
        }
        return total
    }

    private var selectionSummary: String {
        var parts: [String] = []
        switch mode {
        case .video:
            if let v = pickedVideo {
                parts.append(v.resolutionLabel + (v.hdrLabel.map { " " + $0 } ?? ""))
                parts.append(v.videoCodecLabel + (pickedAudio.map { " + " + $0.audioCodecLabel } ?? (v.hasAudio ? " + " + v.audioCodecLabel : "")))
                let kbps = [v.bitrate, pickedAudio?.abr ?? pickedAudio?.tbr].compactMap { $0 }.reduce(0, +)
                if kbps > 0 { parts.append("\(Int(kbps)) kbps") }
            }
            parts.append(container.label)
        case .audio:
            if let a = pickedAudio {
                parts.append(a.audioCodecLabel + (a.abr.map { " \(Int($0)) kbps" } ?? ""))
            }
            parts.append("→ " + audioFormat.label)
        }
        if let size = estimatedSize { parts.append("≈ " + size.bytesText) }
        return parts.joined(separator: " · ")
    }

    /// The chosen streams can't go in the chosen container: downloading would fail.
    private var containerProblem: String? {
        guard mode == .video else { return nil }
        let v = pickedVideo, a = pickedAudio ?? (v?.hasAudio == true ? v : nil)
        return container.problem(video: v, audio: a)
    }

    /// Works, but worth knowing.
    private var containerNote: String? {
        guard mode == .video, containerProblem == nil else { return nil }
        switch container {
        case .mp4:
            if let v = pickedVideo, v.videoFamily == .vp9 { return "VP9 in MP4 may not play in Apple's player. VLC or Infuse will play it." }
        case .mkv, .webm:
            return "Apple's player can't open \(container.label). Use VLC or Infuse, or choose MP4."
        case .mov:
            break
        }
        return nil
    }

    private var trimProblem: String? {
        guard trim else { return nil }
        let start = trimStart.trimmingCharacters(in: .whitespaces)
        let end = trimEnd.trimmingCharacters(in: .whitespaces)
        if !start.isEmpty, parseTime(start) == nil { return "“From” isn't a time. Use 1:20 or 80." }
        if !end.isEmpty, parseTime(end) == nil { return "“To” isn't a time. Use 1:20 or 80." }
        let s = parseTime(start) ?? 0
        if let e = parseTime(end), e <= s { return "The end has to be after the start." }
        if let d = info.duration, s >= d { return "The video is only \(d.durationText) long." }
        return nil
    }

    // MARK: view

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("Download", selection: $mode) {
                Label("Video", systemImage: "film").tag(DownloadMode.video)
                Label("Audio only", systemImage: "waveform").tag(DownloadMode.audio)
            }
            .pickerStyle(.segmented)

            if formats.isEmpty {
                Text("This site didn't list its formats, so yt-dlp will choose the best one.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if mode == .video {
                videoOptions
            } else {
                audioOptions
            }

            extras

            VStack(alignment: .leading, spacing: 10) {
                Text(selectionSummary)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                if let problem = containerProblem {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        HStack {
                            Button("Use MP4") { withAnimation { container = .mp4 } }
                            Button("Use MKV") { withAnimation { container = .mkv } }
                        }
                        .buttonStyle(.glass)
                        .font(.footnote)
                    }
                } else if let note = containerNote {
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(action: queue) {
                    Label("Download", systemImage: "arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(info.is_live == true || containerProblem != nil || trimProblem != nil || store.updating)
                if info.is_live == true {
                    Text("This is a live stream. Live downloads aren't supported yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .card()
        .sheet(isPresented: $showStreams) {
            StreamPicker(formats: formats, video: $manualVideo, audio: $manualAudio, mode: mode)
        }
        .sheet(isPresented: $showAllSubtitles) {
            SubtitlePicker(manual: info.subtitles ?? [], auto: info.auto_subtitles ?? [],
                           original: info.original_language) { lang, auto in
                subtitleLang = lang
                subtitleAuto = auto
            }
        }
        .onAppear {
            manualVideo = FormatPicker.bestVideo(formats, maxHeight: nil, codec: videoCodec)
            manualAudio = FormatPicker.bestAudio(formats, codec: audioCodec)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let thumb = info.thumbnail, let thumbURL = URL(string: thumb) {
                AsyncImage(url: thumbURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 16))
                .overlay(alignment: .bottomTrailing) {
                    if let d = info.duration {
                        Text(d.durationText)
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: .capsule)
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
            }
            Text(info.title ?? "Untitled")
                .font(.title3.weight(.semibold))
                .lineLimit(3)
            HStack(spacing: 6) {
                if let uploader = info.uploader { Text(uploader) }
                if let site = info.siteName { Text("·"); Text(site) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var videoOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $manual.animation(.smooth)) {
                Text("Choose exact streams")
            }
            if manual {
                Button { showStreams = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(manualVideo.map { "\($0.resolutionLabel) \($0.videoCodecLabel) · \($0.ext ?? "")" } ?? "No video")
                            Text(manualAudio.map { "\($0.audioCodecLabel) \(Int($0.abr ?? 0)) kbps · \($0.ext ?? "")" } ?? "No separate audio")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
            } else {
                OptionRow(title: "Quality") {
                    Menu {
                        Picker("Quality", selection: $maxHeight) {
                            Text("Best available").tag(Int?.none)
                            ForEach(FormatPicker.heights(formats), id: \.self) { h in
                                Text(heightLabel(h)).tag(Int?.some(h))
                            }
                        }
                    } label: {
                        MenuLabel(maxHeight.map(heightLabel) ?? "Best")
                    }
                }
                OptionRow(title: "Video codec") {
                    Menu {
                        Picker("Video codec", selection: $videoCodec) {
                            ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                        }
                    } label: { MenuLabel(videoCodec.short) }
                }
                OptionRow(title: "Audio codec") {
                    Menu {
                        Picker("Audio codec", selection: $audioCodec) {
                            ForEach(AudioCodec.allCases) { Text($0.label).tag($0) }
                        }
                    } label: { MenuLabel(audioCodec == .auto ? "Auto" : audioCodec.label) }
                }
            }
            ContainerPicker(container: $container)
        }
    }

    @ViewBuilder
    private var audioOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            OptionRow(title: "Format") {
                Menu {
                    Picker("Format", selection: $audioFormat) {
                        ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                    }
                } label: { MenuLabel(audioFormat.label) }
            }
            if audioFormat == .mp3 {
                OptionRow(title: "MP3 quality") {
                    Menu {
                        Picker("MP3 quality", selection: $mp3Quality) {
                            Text("Best (VBR V0)").tag("0")
                            Text("320 kbps").tag("320K")
                            Text("192 kbps").tag("192K")
                            Text("128 kbps").tag("128K")
                        }
                    } label: { MenuLabel(mp3Quality == "0" ? "Best (V0)" : mp3Quality.replacingOccurrences(of: "K", with: " kbps")) }
                }
            }
            if audioFormat == .m4a, let a = pickedAudio, a.audioFamily != .aac {
                Label("No AAC stream here, so the audio is converted to AAC.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if audioFormat == .opus, let a = pickedAudio, a.audioFamily == .opus {
                Label("Saved exactly as YouTube sends it, with no re-encoding.", systemImage: "checkmark.seal")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("Choose exact stream", isOn: $manual.animation(.smooth))
            if manual {
                Button { showStreams = true } label: {
                    HStack {
                        Text(manualAudio.map { "\($0.audioCodecLabel) \(Int($0.abr ?? 0)) kbps · \($0.ext ?? "")" } ?? "Choose…")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var extras: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Toggle(isOn: $trim.animation(.smooth)) {
                Label("Only part of it", systemImage: "scissors")
            }
            if trim {
                HStack(spacing: 10) {
                    TimeField(title: "From", text: $trimStart, placeholder: "0:00")
                    TimeField(title: "To", text: $trimEnd, placeholder: info.duration?.durationText ?? "end")
                }
                if let problem = trimProblem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let chapters = info.chapters, !chapters.isEmpty {
                    Menu {
                        ForEach(Array(chapters.enumerated()), id: \.offset) { _, c in
                            Button(c.title ?? "Chapter") {
                                trimStart = (c.start ?? 0).durationText
                                trimEnd = (c.end ?? info.duration ?? 0).durationText
                            }
                        }
                    } label: {
                        Label("Pick a chapter", systemImage: "list.bullet").font(.subheadline)
                    }
                }
                Text("Only that part is downloaded. Cuts land on the nearest keyframe.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Toggle(isOn: $embedThumbnail) { Label("Cover art", systemImage: "photo") }
                .disabled(mode == .video && container == .webm || mode == .audio && audioFormat == .wav)
            Toggle(isOn: $embedMetadata) { Label("Title, artist & chapters", systemImage: "tag") }
            if mode == .video, !(info.subtitles ?? []).isEmpty || !(info.auto_subtitles ?? []).isEmpty {
                OptionRow(title: "Subtitles", icon: "captions.bubble") {
                    Menu {
                        Button("None") { subtitleLang = nil }
                        if let subs = info.subtitles, !subs.isEmpty {
                            Section("Made by the uploader") {
                                ForEach(subs.prefix(12), id: \.self) { lang in
                                    Button(languageName(lang)) { subtitleLang = lang; subtitleAuto = false }
                                }
                            }
                        }
                        let quick = quickAutoLanguages
                        if !quick.isEmpty {
                            Section("Automatic") {
                                ForEach(quick, id: \.self) { lang in
                                    Button(languageName(lang) + (lang == info.original_language ? " (original)" : "")) {
                                        subtitleLang = lang; subtitleAuto = true
                                    }
                                }
                            }
                        }
                        Button("All languages…") { showAllSubtitles = true }
                    } label: {
                        MenuLabel(subtitleLang.map { languageName($0) + (subtitleAuto ? " (auto)" : "") } ?? "None")
                    }
                }
            }
            if info.isYouTube {
                Toggle(isOn: $sponsorBlock) { Label("Cut out sponsor segments", systemImage: "forward.end") }
            }
        }
    }

    // MARK: actions

    private func queue() {
        var options: [String: Any] = [
            "mode": mode.rawValue,
            "format": formatSpec,
            "embed_thumbnail": embedThumbnail && !(mode == .video && container == .webm) && !(mode == .audio && audioFormat == .wav),
            "embed_metadata": embedMetadata,
        ]
        if mode == .video {
            options["container"] = container.rawValue
            if let lang = subtitleLang {
                options["subtitles"] = ["langs": [lang], "auto": subtitleAuto]
            }
        } else {
            options["audio_format"] = audioFormat.rawValue
            if audioFormat == .mp3 { options["audio_quality"] = mp3Quality }
        }
        if trim {
            var section: [String: Any] = ["start": parseTime(trimStart) ?? 0]
            if let end = parseTime(trimEnd) { section["end"] = end }
            options["section"] = section
        }
        if sponsorBlock, info.isYouTube { options["sponsorblock"] = ["remove": ["sponsor", "selfpromo", "interaction"]] }

        store.enqueue(url: info.webpage_url ?? url, title: info.title ?? url, thumbnail: info.thumbnail,
                      summary: selectionSummary, options: options)
        onQueued()
    }

    /// The original language and the languages this iPhone uses, first.
    private var quickAutoLanguages: [String] {
        let auto = info.auto_subtitles ?? []
        var wanted: [String] = []
        if let o = info.original_language { wanted.append(o) }
        for id in Locale.preferredLanguages {
            let code = Locale(identifier: id).language.languageCode?.identifier ?? id
            wanted.append(code)
        }
        var seen = Set<String>()
        return wanted.filter { auto.contains($0) && seen.insert($0).inserted }
    }

    private func heightLabel(_ h: Int) -> String {
        switch h {
        case 4320: return "8K (4320p)"
        case 2160: return "4K (2160p)"
        case 1440: return "1440p"
        default: return "\(h)p"
        }
    }
}

func languageName(_ code: String) -> String {
    let base = code.components(separatedBy: "-").first ?? code
    let name = Locale.current.localizedString(forLanguageCode: base) ?? code
    return code.contains("-") ? "\(name) (\(code))" : name
}

struct OptionRow<Content: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        HStack {
            if let icon { Label(title, systemImage: icon) } else { Text(title) }
            Spacer()
            content
        }
    }
}

struct MenuLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .foregroundStyle(Color("AccentColor"))
    }
}

struct TimeField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .keyboardType(.numbersAndPunctuation)
                .monospacedDigit()
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
        }
    }
}

/// Every stream yt-dlp found, like `yt-dlp -F`, to pick video and audio separately.
struct StreamPicker: View {
    let formats: [MediaFormat]
    @Binding var video: MediaFormat?
    @Binding var audio: MediaFormat?
    let mode: DownloadMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if mode == .video {
                    Section {
                        ForEach(FormatPicker.videoStreams(formats)) { f in
                            StreamRow(format: f, selected: video?.id == f.id) {
                                video = f
                                if f.hasAudio { audio = nil }
                            }
                        }
                    } header: {
                        Text("Video")
                    } footer: {
                        Text("Streams marked “+ audio” already contain sound.")
                    }
                }
                Section("Audio") {
                    if mode == .video {
                        StreamRow(title: "No separate audio", detail: video?.hasAudio == true ? "Use the video's own sound" : "Video only, silent",
                                  selected: audio == nil) { audio = nil }
                    }
                    ForEach(FormatPicker.audioStreams(formats)) { f in
                        StreamRow(format: f, selected: audio?.id == f.id) { audio = f }
                    }
                }
            }
            .navigationTitle("Streams")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct StreamRow: View {
    var format: MediaFormat? = nil
    var title: String? = nil
    var detail: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title ?? primary).font(.body.weight(.medium))
                    Text(detail ?? secondary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color("AccentColor")).fontWeight(.semibold)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var primary: String {
        guard let f = format else { return "" }
        if f.hasVideo {
            return "\(f.resolutionLabel)\(f.isHDR ? " HDR" : "")  \(f.videoCodecLabel)\(f.hasAudio ? " + audio" : "")"
        }
        let lang = f.language.map { " · \(languageName($0))" } ?? ""
        return "\(f.audioCodecLabel) \(Int(f.abr ?? f.tbr ?? 0)) kbps\(lang)"
    }

    private var secondary: String {
        guard let f = format else { return "" }
        var bits = ["#\(f.format_id)", f.ext ?? ""]
        if let size = f.size { bits.append(size.bytesText) }
        if let br = f.bitrate, f.hasVideo { bits.append("\(Int(br)) kbps") }
        if let fps = f.fps, f.hasVideo { bits.append("\(Int(fps.rounded())) fps") }
        if let hdr = f.hdrLabel { bits.append(hdr) }
        if let ch = f.audio_channels, !f.hasVideo, ch != 2 { bits.append("\(ch) ch") }
        if let note = f.format_note, !note.isEmpty { bits.append(note) }
        if f.isHLS { bits.append("HLS") }
        return bits.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// MP4 / MKV / WebM / MOV. Segmented normally; a menu at large text sizes.
struct ContainerPicker: View {
    @Binding var container: Container
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            OptionRow(title: "Container") {
                Menu {
                    Picker("Container", selection: $container) {
                        ForEach(Container.allCases) { Text($0.label).tag($0) }
                    }
                } label: { MenuLabel(container.label) }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Container")
                Picker("Container", selection: $container) {
                    ForEach(Container.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

/// Every subtitle language, searchable (YouTube offers 150+ automatic translations).
struct SubtitlePicker: View {
    let manual: [String]
    let auto: [String]
    let original: String?
    let onPick: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private func matches(_ code: String) -> Bool {
        search.isEmpty || languageName(code).localizedCaseInsensitiveContains(search) || code.localizedCaseInsensitiveContains(search)
    }

    private func sorted(_ codes: [String]) -> [String] {
        codes.filter(matches).sorted { languageName($0).localizedCompare(languageName($1)) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if !sorted(manual).isEmpty {
                    Section("Made by the uploader") {
                        ForEach(sorted(manual), id: \.self) { code in
                            Button(languageName(code)) { onPick(code, false); dismiss() }
                        }
                    }
                }
                if !sorted(auto).isEmpty {
                    Section {
                        ForEach(sorted(auto), id: \.self) { code in
                            Button(languageName(code) + (code == original ? " (original)" : "")) { onPick(code, true); dismiss() }
                        }
                    } header: {
                        Text("Automatic")
                    } footer: {
                        Text("Made by YouTube's speech recognition, then machine-translated.")
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Language")
            .navigationTitle("Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
