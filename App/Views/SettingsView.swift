import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage("maxParallel") private var maxParallel = 3
    @AppStorage("ytdlpChannel") private var channel = "stable"
    @AppStorage("autoUpdate") private var autoUpdate = true
    @State private var cacheCleared = false

    private var ready: Bool { store.engineState == .ready }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image("AppIconImage")
                            .resizable()
                            .frame(width: 58, height: 58)
                            .clipShape(.rect(cornerRadius: 13))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Alembic").font(.title3.weight(.semibold))
                            Text("yt-dlp \(store.versions?.ytdlp ?? "…")")
                                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    LabeledContent("Version", value: store.versions?.ytdlp ?? "…")
                    LabeledContent("Using", value: store.versions?.ytdlp_source == "updated" ? "Downloaded update" : "Built into the app")
                    if store.versions?.youtube_solver == false {
                        Label("YouTube's challenge solver didn't load with this yt-dlp, so some YouTube videos may fail. Go back to the built-in version below.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Picker("Release channel", selection: $channel) {
                        Text("Stable").tag("stable")
                        Text("Nightly").tag("nightly")
                    }
                    Toggle("Update automatically", isOn: $autoUpdate)
                    if let update = store.availableUpdate {
                        Button {
                            Task { await store.installUpdate(silent: false) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Install yt-dlp \(update.latest)")
                                    Text("You have \(update.current)").font(.caption).foregroundStyle(.secondary)
                                }
                                if store.updating { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(store.updating || !ready)
                        if let notes = update.notes_url.flatMap(URL.init(string:)) {
                            Link("What's new", destination: notes)
                        }
                    } else {
                        Button {
                            Task { await store.checkForUpdate() }
                        } label: {
                            HStack {
                                Text("Check for update")
                                if store.updating { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(store.updating || !ready)
                    }
                    if let message = store.updateMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if store.versions?.ytdlp_source == "updated" {
                        Button("Go back to the built-in version (\(store.versions?.ytdlp_bundled ?? ""))", role: .destructive) {
                            Task { await store.resetToBundled() }
                        }
                        .disabled(store.updating || !ready || store.jobs.contains(where: \.isActive))
                    }
                } header: {
                    Text("yt-dlp")
                } footer: {
                    Text("Sites change often, and yt-dlp keeps up. Updates come only from yt-dlp's official GitHub releases, are installed only if they carry yt-dlp's release signature, and are tested before use: if one doesn't work, the previous version stays. Nightly gets fixes first.")
                }

                Section {
                    Stepper("At once: \(maxParallel)", value: $maxParallel, in: 1...5)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Files are saved in the Files app: On My iPhone → Alembic. In LiveContainer, look in LiveContainer's folder under Data → Application. Keep Alembic open while big downloads run: iOS pauses apps in the background after a short while, and Alembic tells you when that happens.")
                }

                Section {
                    Button(cacheCleared ? "Cleared" : "Clear temporary files") {
                        Task {
                            await store.clearCache()
                            cacheCleared = true
                            try? await Task.sleep(for: .seconds(2))
                            cacheCleared = false
                        }
                    }
                    .disabled(cacheCleared || !ready)
                } footer: {
                    Text("Removes leftover partial downloads and yt-dlp's cache. Your downloads aren't touched.")
                }

                Section("About") {
                    LabeledContent("App", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    LabeledContent("FFmpeg", value: store.versions?.ffmpeg ?? "…")
                    LabeledContent("Python", value: store.versions?.python ?? "…")
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    Link(destination: URL(string: "https://github.com/RatterAU/Alembic")!) {
                        Label("Source code & help", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://github.com/RatterAU/Alembic/issues")!) {
                        Label("Report a problem", systemImage: "exclamationmark.bubble")
                    }
                }

                Section {
                    Text("No accounts, no ads, no analytics. Alembic only connects to the sites you download from, to GitHub to update yt-dlp, and, when you turn on sponsor cutting, to the SponsorBlock service.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Backdrop())
            .navigationTitle("Settings")
            .task(id: ready) { await store.loadFFmpegVersion() }
        }
    }
}

struct AcknowledgementsView: View {
    private struct Part: Identifiable {
        let name: String
        let licence: String
        let url: String
        var id: String { name }
    }

    private let parts: [Part] = [
        Part(name: "yt-dlp", licence: "Unlicense (public domain)", url: "https://github.com/yt-dlp/yt-dlp"),
        Part(name: "FFmpeg", licence: "LGPL 3.0 or later", url: "https://ffmpeg.org/legal.html"),
        Part(name: "LAME (MP3 encoder)", licence: "LGPL 2.0 or later", url: "https://lame.sourceforge.io"),
        Part(name: "Opus", licence: "BSD 3-Clause", url: "https://opus-codec.org/license/"),
        Part(name: "Mbed TLS", licence: "Apache 2.0", url: "https://github.com/Mbed-TLS/mbedtls"),
        Part(name: "Python", licence: "PSF License", url: "https://docs.python.org/3/license.html"),
        Part(name: "Python Apple Support (BeeWare)", licence: "BSD 3-Clause; includes OpenSSL (Apache 2.0), XZ, bzip2, libFFI",
             url: "https://github.com/beeware/Python-Apple-support"),
        Part(name: "Mutagen", licence: "GPL 2.0 or later", url: "https://github.com/quodlibet/mutagen"),
        Part(name: "certifi", licence: "MPL 2.0", url: "https://github.com/certifi/python-certifi"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(parts) { part in
                    Link(destination: URL(string: part.url)!) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(part.name).foregroundStyle(.primary)
                            Text(part.licence).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Alembic is built on these open-source projects. FFmpeg is included as separate, replaceable libraries; its source and the build script are in Alembic's repository.")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
