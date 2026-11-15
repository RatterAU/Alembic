import AVFoundation
import AVKit
import Photos
import SwiftUI

struct LibraryItem: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let date: Date
    var id: URL { url }
    var ext: String { url.pathExtension.lowercased() }
    var isAudio: Bool { LibraryItem.audioExts.contains(ext) }
    /// "Title [abc123] 1080p.mp4" -> "Title"
    var title: String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.replacingOccurrences(of: #"\s*\[[^\]]+\](\s+\d+p)?(\s+\(\d+\))?$"#, with: "", options: .regularExpression)
    }
    var canSaveToPhotos: Bool { ["mp4", "m4v", "mov"].contains(ext) }
    var canConvertToMP4: Bool { ["mkv", "webm"].contains(ext) }

    static let videoExts: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm"]
    static let audioExts: Set<String> = ["m4a", "mp3", "opus", "ogg", "oga", "flac", "wav", "aac"]
}

@MainActor
@Observable
final class Library {
    var items: [LibraryItem] = []
    var loaded = false

    func reload() async {
        let root = Store.downloadsFolder
        items = await Task.detached(priority: .userInitiated) { Self.scan(root) }.value
        loaded = true
    }

    nonisolated private static func scan(_ root: URL) -> [LibraryItem] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
        var found: [LibraryItem] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in e {
                if url.lastPathComponent == "Inbox" { e.skipDescendants(); continue }
                let ext = url.pathExtension.lowercased()
                guard LibraryItem.videoExts.contains(ext) || LibraryItem.audioExts.contains(ext),
                      let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                found.append(LibraryItem(url: url, size: Int64(v.fileSize ?? 0), date: v.creationDate ?? .distantPast))
            }
        }
        return found.sorted { $0.date > $1.date }
    }

    func delete(_ item: LibraryItem) {
        try? FileManager.default.removeItem(at: item.url)
        LibraryMeta.shared.forget(item.url)
        items.removeAll { $0 == item }
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

struct LibraryView: View {
    @Environment(Store.self) private var store
    @State private var library = Library()
    @State private var filter = Filter.all
    @State private var search = ""
    @State private var playing: LibraryItem?
    @State private var confirmDelete: LibraryItem?
    @State private var converting: Set<URL> = []
    @State private var toast: String?

    enum Filter: String, CaseIterable { case all = "All", video = "Video", audio = "Audio" }

    private var shown: [LibraryItem] {
        library.items.filter { item in
            (filter == .all || (filter == .audio) == item.isAudio)
                && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
        }
    }

    private var activeJobs: [Job] { store.jobs.filter(\.isActive) }

    var body: some View {
        NavigationStack {
            List {
                if !activeJobs.isEmpty {
                    Section("Downloading") {
                        ForEach(activeJobs) { JobRow(job: $0) }
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    }
                }
                if !shown.isEmpty {
                    Section {
                        ForEach(shown) { item in
                            Button { playing = item } label: {
                                LibraryRow(item: item, converting: converting.contains(item.url))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: item) }
                            .swipeActions {
                                Button(role: .destructive) { confirmDelete = item } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } footer: {
                        Text("\(library.items.count) \(library.items.count == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: library.totalSize, countStyle: .file)) · also in the Files app")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .overlay {
                if library.loaded, library.items.isEmpty, activeJobs.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: "square.stack")
                    } description: {
                        Text("Finished downloads appear here, and in the Files app.")
                    }
                } else if !library.items.isEmpty, shown.isEmpty, !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search downloads")
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .background(Backdrop())
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .confirmationDialog("Delete “\(confirmDelete?.title ?? "")”?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let item = confirmDelete { withAnimation { library.delete(item) } }
                }
            } message: {
                Text("It's removed from your iPhone, including the Files app.")
            }
        }
        .task { await library.reload() }
        .onChange(of: store.libraryRevision) { _, _ in Task { await library.reload() } }
        .fullScreenCover(item: $playing) { PlayerScreen(item: $0) }
    }

    @ViewBuilder
    private func menu(for item: LibraryItem) -> some View {
        Button { playing = item } label: { Label("Play", systemImage: "play") }
        ShareLink(item: item.url) { Label("Share or Save to Files", systemImage: "square.and.arrow.up") }
        if item.canSaveToPhotos {
            Button { Task { await saveToPhotos(item) } } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
        }
        if item.canConvertToMP4 {
            Button { Task { await convertToMP4(item) } } label: {
                Label("Convert to MP4 (no quality loss)", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(converting.contains(item.url) || store.engineState != .ready)
        }
        Divider()
        Button(role: .destructive) { confirmDelete = item } label: { Label("Delete", systemImage: "trash") }
    }

    private func saveToPhotos(_ item: LibraryItem) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { show("Allow Photos access in Settings first"); return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: item.url)
            }
            show("Saved to Photos")
        } catch {
            show("Photos couldn't take this file")
        }
    }

    private func convertToMP4(_ item: LibraryItem) async {
        converting.insert(item.url)
        defer { converting.remove(item.url) }
        struct Result: Decodable { let path: String }
        do {
            let r = try await Engine.shared.call("remux_file", ["path": item.url.path, "container": "mp4"], as: Result.self)
            LibraryMeta.shared.rename(item.url, to: URL(fileURLWithPath: r.path))
            show("Saved an MP4 copy")
            await library.reload()
        } catch {
            show(error.localizedDescription)
        }
    }

    private func show(_ message: String) {
        withAnimation(.smooth) { toast = message }
        AccessibilityNotification.Announcement(message).post()
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(.smooth) { toast = nil }
        }
    }
}

struct LibraryRow: View {
    let item: LibraryItem
    var converting = false
    @State private var image: UIImage?
    @State private var duration: Double?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.isAudio ? "music.note" : "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: item.isAudio ? 52 : 84, height: 52)
            .clipShape(.rect(cornerRadius: 10))
            .frame(width: 84, alignment: .leading)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.ext.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                    if converting {
                        ProgressView().controlSize(.mini)
                        Text("Converting…")
                    } else {
                        Text([duration?.durationText, ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file),
                              item.date.formatted(.relative(presentation: .named))]
                            .compactMap { $0 }.joined(separator: " · "))
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays the file")
        .task(id: item) {
            let meta = LibraryMeta.shared.entry(for: item.url)
            let info = await LibraryThumbnails.shared.info(for: item, meta: meta)
            image = info.image
            duration = info.duration
        }
    }
}

/// Full-screen player using Apple's own controls (AirPlay, Picture in Picture, scrubbing).
struct PlayerScreen: View {
    let item: LibraryItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var playable = true

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if playable, let player {
                    VideoPlayer(player: player) {
                        if item.isAudio {
                            VStack(spacing: 12) {
                                Image(systemName: "waveform").font(.system(size: 54)).foregroundStyle(.white.opacity(0.8))
                                Text(item.title).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
                            }
                            .padding(32)
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else if !playable {
                    ContentUnavailableView {
                        Label("Apple's player can't open \(item.ext.uppercased())", systemImage: "play.slash")
                    } description: {
                        Text(item.canConvertToMP4
                             ? "Convert it to MP4 from the Library (touch and hold it), or open it in VLC or Infuse."
                             : "Open it in VLC or Infuse instead.")
                    } actions: {
                        ShareLink(item: item.url) { Label("Open in…", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.glassProminent)
                    }
                    .foregroundStyle(.white)
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: item.url) }
            }
        }
        .task {
            let asset = AVURLAsset(url: item.url)
            playable = (try? await asset.load(.isPlayable)) ?? false
            if playable {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player = p
                p.play()
            }
        }
        .onDisappear { player?.pause() }
    }
}
