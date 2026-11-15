import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

struct Versions: Decodable, Equatable {
    var ytdlp: String
    var ytdlp_channel: String?
    var ytdlp_source: String?
    var ytdlp_bundled: String?
    var ffmpeg: String?
    var python: String?
    var youtube_solver: Bool?
    var youtube_solver_error: String?
    var notes: [String]?
}

struct UpdateCheck: Decodable, Equatable {
    let current: String
    let latest: String
    let available: Bool
    let notes_url: String?
}

@Observable
final class Job: Identifiable {
    enum Status: String { case queued, starting, downloading, processing, finished, error, cancelled }

    let id: String
    let url: String
    var title: String
    let thumbnail: String?
    let summary: String
    let options: [String: Any]
    var status: Status = .queued
    var progress: Double = 0
    /// Progress of the current processing step, when FFmpeg reports it.
    var stepProgress: Double?
    var phase: String = "Waiting"
    var speed: Double?
    var eta: Double?
    var downloaded: Double?
    var total: Double?
    var files: [URL] = []
    var error: String?
    var warning: String?
    var log: [String] = []
    var cancelRequested = false
    /// The engine accepted the start call (until then a cancel is handled here).
    var engineStarted = false
    let created = Date()

    init(id: String? = nil, url: String, title: String, thumbnail: String?, summary: String, options: [String: Any]) {
        self.id = id ?? UUID().uuidString.prefix(8).lowercased()
        self.url = url
        self.title = title
        self.thumbnail = thumbnail
        self.summary = summary
        self.options = options
    }

    var isActive: Bool { [.queued, .starting, .downloading, .processing].contains(status) }
    var isRunning: Bool { [.starting, .downloading, .processing].contains(status) }
}

enum EngineState: Equatable {
    case starting
    case ready
    case failed(String)
}

@MainActor
@Observable
final class Store {
    var engineState: EngineState = .starting
    var versions: Versions?
    var jobs: [Job] = []
    var pendingLink: String?
    var notice: String?
    var updateMessage: String?
    var availableUpdate: UpdateCheck?
    var updating = false
    var libraryRevision = 0

    @ObservationIgnored @AppStorage("maxParallel") var maxParallel = 3
    @ObservationIgnored @AppStorage("ytdlpChannel") var channel = "stable"
    @ObservationIgnored @AppStorage("autoUpdate") var autoUpdate = true
    @ObservationIgnored @AppStorage("lastUpdateCheck") var lastUpdateCheck = 0.0
    @ObservationIgnored @AppStorage("askedForNotifications") var askedForNotifications = false

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pythonStarted = false

    nonisolated static var downloadsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    nonisolated static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Engine")
    }
    nonisolated static var cachesFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBackgroundTask(renew: true) }
        }
    }

    // MARK: startup

    func start() async {
        guard engineState != .ready else { return }
        engineState = .starting
        Engine.shared.onEvent = { [weak self] event in self?.handle(event) }
        do {
            if !pythonStarted {
                try await Engine.shared.start()
                pythonStarted = true
            }
            let v = try await Engine.shared.call("init", [
                "docs": Self.downloadsFolder.path,
                "support": Self.supportFolder.path,
                "temp": Self.cachesFolder.appendingPathComponent("partial").path,
                "cache": Self.cachesFolder.path,
                "bundled_ytdlp": Bundle.main.bundleURL.appendingPathComponent("yt-dlp.zip").path,
            ], as: Versions.self)
            versions = v
            if let note = v.notes?.first { notice = note }
            engineState = .ready
            #if DEBUG
            runDebugLaunchHooks()
            #endif
            Task { await autoUpdateIfDue() }
        } catch {
            engineState = .failed(error.localizedDescription)
        }
    }

    /// Recovery from a failed start: forget any downloaded yt-dlp and try again.
    func startWithBuiltInYtdlp() async {
        try? FileManager.default.removeItem(at: Self.supportFolder.appendingPathComponent("ytdlp/active.json"))
        if pythonStarted || engineState == .starting {
            await start()
        } else {
            engineState = .failed("Close Alembic from the app switcher and open it again.")
        }
    }

    #if DEBUG
    /// Simulator testing only: `-AlembicTestLink <url>` looks a link up;
    /// `-AlembicTestJobs '<json array of {url, options}>'` queues downloads directly.
    private func runDebugLaunchHooks() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let link = value("-AlembicTestLink") { pendingLink = link }
        if let raw = value("-AlembicTestJobs"), let data = raw.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in list {
                guard let url = item["url"] as? String, let options = item["options"] as? [String: Any] else { continue }
                enqueue(url: url, title: item["title"] as? String ?? url, thumbnail: item["thumbnail"] as? String,
                        summary: item["summary"] as? String ?? "test", options: options)
            }
        }
    }
    #endif

    func loadFFmpegVersion() async {
        guard versions?.ffmpeg == nil, engineState == .ready else { return }
        struct V: Decodable { let ffmpeg: String? }
        if let v = try? await Engine.shared.call("ffmpeg_version", as: V.self) {
            versions?.ffmpeg = v.ffmpeg
        }
    }

    // MARK: downloads

    func enqueue(url: String, title: String, thumbnail: String?, summary: String, options: [String: Any]) {
        let job = Job(url: url, title: title, thumbnail: thumbnail, summary: summary, options: options)
        jobs.insert(job, at: 0)
        askForNotificationsOnce()
        pump()
    }

    func cancel(_ job: Job) {
        guard job.isActive, !job.cancelRequested else { return }
        job.cancelRequested = true
        if job.status == .queued {
            job.status = .cancelled
            job.phase = "Cancelled"
            pump()
            return
        }
        job.phase = "Cancelling…"
        // If the engine hasn't accepted the job yet, pump()'s start call cancels it.
        if job.engineStarted {
            Task { try? await Engine.shared.call("cancel", ["id": job.id]) }
        }
    }

    /// Same job id, so the engine finds the partial files it kept and resumes them;
    /// fresh stream links, since old ones may have expired.
    func retry(_ job: Job) {
        var options = job.options
        options["fresh"] = true
        let copy = Job(id: job.id, url: job.url, title: job.title, thumbnail: job.thumbnail,
                       summary: job.summary, options: options)
        if let i = jobs.firstIndex(where: { $0 === job }) { jobs[i] = copy } else { jobs.insert(copy, at: 0) }
        pump()
    }

    func remove(_ job: Job) {
        jobs.removeAll { $0 === job }
        if job.status == .error { discardPartial(job) }
    }

    func clearFinished() {
        for job in jobs where job.status == .error { discardPartial(job) }
        jobs.removeAll { !$0.isActive }
    }

    private func discardPartial(_ job: Job) {
        Task { try? await Engine.shared.call("discard", ["id": job.id]) }
    }

    private func pump() {
        let running = jobs.filter(\.isRunning).count
        let slots = max(1, maxParallel) - running
        if slots > 0 {
            for job in jobs.reversed().filter({ $0.status == .queued }).prefix(slots) {
                job.status = .starting
                job.phase = "Starting"
                var args = job.options
                args["id"] = job.id
                args["url"] = job.url
                args["title"] = job.title
                Task {
                    do {
                        var request = args
                        let cancelledEarly = job.cancelRequested
                        request["cancelled"] = cancelledEarly
                        try await Engine.shared.call("start", request)
                        if cancelledEarly {
                            job.status = .cancelled
                            job.phase = "Cancelled"
                            self.pump()
                            return
                        }
                        job.engineStarted = true
                        // Cancel tapped while the start call was on its way.
                        if job.cancelRequested {
                            try? await Engine.shared.call("cancel", ["id": job.id])
                        }
                    } catch {
                        job.status = .error
                        job.error = error.localizedDescription
                        self.pump()
                    }
                }
            }
        }
        updateBackgroundTask(renew: false)
    }

    private func handle(_ event: [String: Any]) {
        guard let id = event["id"] as? String, let job = jobs.first(where: { $0.id == id }) else { return }
        if event["type"] as? String == "log" {
            if let line = event["line"] as? String {
                job.log.append(line)
                if job.log.count > 600 { job.log.removeFirst(job.log.count - 600) }
            }
            return
        }
        let wasActive = job.isActive
        if let s = event["status"] as? String, let status = Job.Status(rawValue: s) { job.status = status }
        if let p = event["progress"] as? Double { job.progress = p }
        if event.keys.contains("step_progress") { job.stepProgress = event["step_progress"] as? Double }
        if let phase = event["phase"] as? String, !(job.cancelRequested && job.isActive) { job.phase = phase }
        if let t = event["title"] as? String, !t.isEmpty { job.title = t }
        if event.keys.contains("speed") { job.speed = event["speed"] as? Double }
        if event.keys.contains("eta") { job.eta = event["eta"] as? Double }
        if let d = event["downloaded"] as? Double { job.downloaded = d }
        if let t = event["total"] as? Double { job.total = t }
        if let files = event["files"] as? [String] { job.files = files.map { URL(fileURLWithPath: $0) } }
        if let err = event["error"] as? String { job.error = err }
        if let w = event["warning"] as? String { job.warning = w }
        if wasActive, !job.isActive {
            if job.status == .finished {
                LibraryMeta.shared.record(job: job, duration: event["duration"] as? Double)
                libraryRevision += 1
            }
            notifyIfInBackground(job)
            pump()
        }
    }

    // MARK: background

    /// iOS gives a backgrounded app a little extra time; use it while downloads run,
    /// and ask again each time the app goes to the background.
    private func updateBackgroundTask(renew: Bool) {
        let active = jobs.contains(where: \.isActive)
        if active, renew, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        if active, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.notifyPaused()
                    UIApplication.shared.endBackgroundTask(self.backgroundTask)
                    self.backgroundTask = .invalid
                }
            }
        } else if !active, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func askForNotificationsOnce() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyIfInBackground(_ job: Job) {
        guard UIApplication.shared.applicationState != .active, job.status != .cancelled else { return }
        let content = UNMutableNotificationContent()
        content.title = job.status == .finished ? "Downloaded" : "Download failed"
        content.body = job.title
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "job-\(job.id)", content: content, trigger: nil))
    }

    private func notifyPaused() {
        guard jobs.contains(where: \.isActive) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Downloads paused"
        content.body = "iOS paused Alembic in the background. Open it to carry on."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "paused", content: content, trigger: nil))
    }

    // MARK: links from other apps

    func open(_ url: URL) {
        // alembic://download?url=<link>
        guard url.scheme == "alembic" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let link = comps?.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: link), ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { return }
        pendingLink = link
    }

    // MARK: yt-dlp updates

    private func autoUpdateIfDue() async {
        guard autoUpdate, Date().timeIntervalSince1970 - lastUpdateCheck > 12 * 3600 else { return }
        lastUpdateCheck = Date().timeIntervalSince1970
        guard let check = try? await Engine.shared.call("check_update", ["channel": channel], as: UpdateCheck.self),
              check.available else { return }
        // Wait until nothing is downloading, then update quietly.
        for _ in 0..<120 where jobs.contains(where: \.isActive) {
            try? await Task.sleep(for: .seconds(30))
        }
        guard !jobs.contains(where: \.isActive) else { return }
        await installUpdate(silent: true)
    }

    func checkForUpdate() async {
        updateMessage = "Checking…"
        availableUpdate = nil
        do {
            let check = try await Engine.shared.call("check_update", ["channel": channel], as: UpdateCheck.self)
            lastUpdateCheck = Date().timeIntervalSince1970
            if check.available {
                availableUpdate = check
                updateMessage = nil
            } else {
                updateMessage = "yt-dlp \(check.current) is the latest \(channel) version"
            }
        } catch {
            updateMessage = error.localizedDescription
        }
    }

    func installUpdate(silent: Bool) async {
        guard !updating else { return }
        if jobs.contains(where: \.isActive) {
            if !silent { updateMessage = "Wait for downloads to finish, then update" }
            return
        }
        updating = true
        defer { updating = false }
        if !silent { updateMessage = "Downloading and verifying…" }
        do {
            versions = try await Engine.shared.call("install_update", ["channel": channel], as: Versions.self)
            availableUpdate = nil
            updateMessage = "Updated to yt-dlp \(versions?.ytdlp ?? "") · signature verified"
        } catch {
            if !silent { updateMessage = error.localizedDescription }
        }
    }

    func resetToBundled() async {
        updating = true
        defer { updating = false }
        do {
            versions = try await Engine.shared.call("reset_update", as: Versions.self)
            updateMessage = "Using the yt-dlp built into the app (\(versions?.ytdlp ?? ""))"
        } catch {
            updateMessage = error.localizedDescription
        }
    }

    func clearCache() async {
        _ = try? await Engine.shared.call("clear_cache")
    }
}
