import SwiftUI

/// A playlist: tick the items you want, choose one quality for all of them.
struct PlaylistPanel: View {
    @Environment(Store.self) private var store
    let info: ProbeResult
    let onQueued: () -> Void

    @AppStorage("mode") private var mode: DownloadMode = .video
    @AppStorage("videoCodec") private var videoCodec: VideoCodec = .auto
    @AppStorage("audioCodec") private var audioCodec: AudioCodec = .auto
    @AppStorage("container") private var container: Container = .mp4
    @AppStorage("audioFormat") private var audioFormat: AudioFormat = .m4a
    @AppStorage("embedThumbnail") private var embedThumbnail = true
    @AppStorage("embedMetadata") private var embedMetadata = true
    @State private var maxHeight = 1080
    @State private var selected: Set<Int> = []

    private var entries: [PlaylistEntry] { info.entries ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                if let t = info.thumbnail, let u = URL(string: t) {
                    AsyncImage(url: u) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.secondary.opacity(0.2) }
                        .frame(width: 112, height: 63)
                        .clipShape(.rect(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title ?? "Playlist").font(.headline).lineLimit(2)
                    Text("\(entries.count) items" + (info.uploader.map { " · \($0)" } ?? ""))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Picker("Download", selection: $mode) {
                Text("Video").tag(DownloadMode.video)
                Text("Audio only").tag(DownloadMode.audio)
            }
            .pickerStyle(.segmented)

            if mode == .video {
                OptionRow(title: "Quality") {
                    Menu {
                        Picker("Quality", selection: $maxHeight) {
                            ForEach([4320, 2160, 1440, 1080, 720, 480, 360], id: \.self) { Text("Up to \($0)p").tag($0) }
                        }
                    } label: { MenuLabel("Up to \(maxHeight)p") }
                }
                OptionRow(title: "Video codec") {
                    Menu {
                        Picker("Video codec", selection: $videoCodec) {
                            ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                        }
                    } label: { MenuLabel(videoCodec.short) }
                }
                ContainerPicker(container: $container)
            } else {
                OptionRow(title: "Format") {
                    Menu {
                        Picker("Format", selection: $audioFormat) {
                            ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                        }
                    } label: { MenuLabel(audioFormat.label) }
                }
            }

            HStack {
                Text("\(selected.count) of \(entries.count) selected").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(selected.count == entries.count ? "Select none" : "Select all") {
                    selected = selected.count == entries.count ? [] : Set(entries.map(\.index))
                }
                .font(.subheadline.weight(.medium))
            }

            LazyVStack(spacing: 0) {
                ForEach(entries, id: \.index) { entry in
                    Button {
                        if selected.contains(entry.index) { selected.remove(entry.index) } else { selected.insert(entry.index) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(entry.index) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected.contains(entry.index) ? Color("AccentColor") : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title ?? "Item \(entry.index)").font(.subheadline).lineLimit(2)
                                if let d = entry.duration {
                                    Text(d.durationText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected.contains(entry.index) ? .isSelected : [])
                    Divider()
                }
            }

            Button(action: queue) {
                Label("Download \(selected.count) item\(selected.count == 1 ? "" : "s")", systemImage: "arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(selected.isEmpty || store.updating)
        }
        .card()
        .onAppear { selected = Set(entries.map(\.index)) }
    }

    private func queue() {
        // With "Auto", prefer codecs the chosen container can hold.
        let video = videoCodec != .auto ? videoCodec : container == .mov ? .h264 : container == .webm ? .vp9 : .auto
        let audio = audioCodec != .auto ? audioCodec : container == .mov ? .aac : container == .webm ? .opus : .auto
        let sort = [video.sortKey, audio.sortKey].compactMap { $0 }.joined(separator: ",")
        for entry in entries where selected.contains(entry.index) {
            guard let url = entry.url else { continue }
            var options: [String: Any] = [
                "mode": mode.rawValue,
                "embed_thumbnail": embedThumbnail && !(mode == .video && container == .webm) && !(mode == .audio && audioFormat == .wav),
                "embed_metadata": embedMetadata,
            ]
            let summary: String
            if mode == .video {
                options["format"] = "bv*[height<=\(maxHeight)]+ba/b[height<=\(maxHeight)]/bv*+ba/b"
                options["container"] = container.rawValue
                if !sort.isEmpty { options["sort"] = sort }
                summary = "Up to \(maxHeight)p · \(videoCodec.short) · \(container.label)"
            } else {
                options["format"] = "ba/b"
                options["audio_format"] = audioFormat.rawValue
                summary = audioFormat.label
            }
            store.enqueue(url: url, title: entry.title ?? url, thumbnail: entry.thumbnail ?? info.thumbnail,
                          summary: summary, options: options)
        }
        onQueued()
    }
}
