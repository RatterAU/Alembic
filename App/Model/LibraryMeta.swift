import AVFoundation
import CryptoKit
import Foundation
import QuickLookThumbnailing
import UIKit

/// What Alembic remembers about each downloaded file, written when the download
/// finishes: its duration and the cover image yt-dlp found. The library uses it
/// so rows appear instantly, including for MKV/WebM/Opus files that iOS itself
/// can't make thumbnails for.
@MainActor
final class LibraryMeta {
    static let shared = LibraryMeta()

    struct Entry: Codable {
        var title: String?
        var duration: Double?
        var thumbnail: String?
    }

    private var entries: [String: Entry] = [:]
    private let file = Store.supportFolder.appendingPathComponent("library.json")

    private init() {
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func entry(for url: URL) -> Entry? { entries[url.lastPathComponent] }

    func record(job: Job, duration: Double?) {
        for file in job.files {
            entries[file.lastPathComponent] = Entry(title: job.title, duration: duration, thumbnail: job.thumbnail)
        }
        save()
    }

    func forget(_ url: URL) {
        entries[url.lastPathComponent] = nil
        save()
    }

    func rename(_ old: URL, to new: URL) {
        entries[new.lastPathComponent] = entries[old.lastPathComponent]
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}

/// Thumbnails and durations for library rows, made once per file version and
/// kept in memory (and cover images on disk), so scrolling doesn't redo the work.
actor LibraryThumbnails {
    static let shared = LibraryThumbnails()

    struct Info { let image: UIImage?; let duration: Double? }

    private let memory = NSCache<NSString, Box>()
    private final class Box { let info: Info; init(_ i: Info) { info = i } }
    private let folder = Store.cachesFolder.appendingPathComponent("thumbs")

    func info(for item: LibraryItem, meta: LibraryMeta.Entry?) async -> Info {
        let key = "\(item.url.path)|\(item.date.timeIntervalSince1970)|\(item.size)" as NSString
        if let hit = memory.object(forKey: key) { return hit.info }

        var image: UIImage?
        if ["mp4", "m4v", "mov", "m4a", "mp3"].contains(item.ext) {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 168, height: 104),
                                                       scale: 3, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
        if image == nil, let remote = meta?.thumbnail {
            image = await cover(remote)
        }
        var duration = meta?.duration
        if duration == nil, ["mp4", "m4v", "mov", "m4a", "mp3", "wav", "flac"].contains(item.ext),
           let d = try? await AVURLAsset(url: item.url).load(.duration), d.isNumeric {
            duration = d.seconds
        }
        let info = Info(image: image, duration: duration)
        memory.setObject(Box(info), forKey: key)
        return info
    }

    /// The cover yt-dlp found for this download, fetched once and kept in Caches.
    private func cover(_ remote: String) async -> UIImage? {
        guard let url = URL(string: remote), url.scheme == "https" else { return nil }
        let name = SHA256.hash(data: Data(remote.utf8)).map { String(format: "%02x", $0) }.joined()
        let local = folder.appendingPathComponent(name + ".jpg")
        if let data = try? Data(contentsOf: local), let image = UIImage(data: data) { return image }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 336, height: 208)) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? image.jpegData(compressionQuality: 0.8)?.write(to: local, options: .atomic)
        return image
    }
}
