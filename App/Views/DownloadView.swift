import SwiftUI
import UIKit

struct DownloadView: View {
    @Environment(Store.self) private var store
    @State private var link = ""
    @State private var state: ProbeState = .idle
    @State private var clipboardHasLink = false
    @State private var probeID: String?
    @FocusState private var fieldFocused: Bool

    enum ProbeState {
        case idle
        case loading(String)
        case loaded(ProbeResult, String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let notice = store.notice {
                        MessageCard(icon: "info.circle.fill", tint: Color("AccentColor"), title: "yt-dlp", message: notice,
                                    action: ("OK", { withAnimation { store.notice = nil } }))
                    }
                    linkCard
                    switch store.engineState {
                    case .starting:
                        EngineStartingCard()
                    case .failed(let message):
                        MessageCard(icon: "exclamationmark.triangle.fill", tint: .orange,
                                    title: "The engine didn't start", message: message,
                                    action: ("Try with the built-in yt-dlp", { Task { await store.startWithBuiltInYtdlp() } }))
                    case .ready:
                        content
                    }
                    if !store.jobs.isEmpty { DownloadsSection() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Backdrop())
            .navigationTitle("Alembic")
            .task { await refreshClipboardHint() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshClipboardHint() }
            }
            .onChange(of: store.pendingLink, initial: true) { _, new in
                if let new {
                    link = new
                    store.pendingLink = nil
                    probe()
                }
            }
            .onChange(of: store.engineState) { _, new in
                if new == .ready, case .loading = state { probe() }
            }
            .sensoryFeedback(.success, trigger: store.libraryRevision)
        }
    }

    // MARK: link entry

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste a link", text: $link)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($fieldFocused)
                    .onSubmit { probe() }
                if !link.isEmpty {
                    Button {
                        cancelProbe()
                        link = ""
                        state = .idle
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("Clear link")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.background.secondary, in: .rect(cornerRadius: 14))

            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in
                        link = extractLink(text) ?? text
                        probe()
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .tint(Color("AccentColor"))

                Spacer()

                Button { probe() } label: {
                    Label("Look up", systemImage: "arrow.right")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.glassProminent)
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || store.updating)
            }
            if store.updating {
                Label("Updating yt-dlp…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if clipboardHasLink, link.isEmpty {
                Label("You've copied a link. Tap Paste to use it.", systemImage: "doc.on.clipboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            if store.jobs.isEmpty { WelcomeCard() }
        case .loading(let url):
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reading the link…").font(.headline)
                    Text(url).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Cancel") {
                    cancelProbe()
                    state = .idle
                }
                .buttonStyle(.glass)
            }
            .card(padding: 18)
        case .failed(let message):
            MessageCard(icon: "exclamationmark.circle.fill", tint: .orange,
                        title: "Couldn't read that link", message: message,
                        action: ("Try again", { probe() }))
        case .loaded(let info, let url):
            if info.isPlaylist {
                PlaylistPanel(info: info) { state = .idle; link = "" }
            } else {
                if info.in_playlist == true {
                    Button { probe(playlist: true) } label: {
                        Label("This video is part of a playlist. Show the whole playlist", systemImage: "list.bullet.rectangle")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.glass)
                }
                MediaPanel(info: info, url: url) {
                    state = .idle
                    link = ""
                }
                .id(url)
            }
        }
    }

    private func probe(playlist: Bool = false) {
        fieldFocused = false
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = extractLink(raw) ?? (raw.isEmpty ? nil : raw) else { return }
        cancelProbe()
        link = url
        guard url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") else {
            state = .failed("Paste a link that starts with https://")
            return
        }
        state = .loading(url)
        guard store.engineState == .ready else { return } // resumes when the engine is up
        let id = UUID().uuidString
        probeID = id
        Task {
            do {
                let info = try await Engine.shared.call("probe", ["url": url, "playlist": playlist, "probe_id": id],
                                                        as: ProbeResult.self)
                if probeID == id {
                    probeID = nil
                    withAnimation(.smooth) { state = .loaded(info, url) }
                }
            } catch {
                if probeID == id {
                    probeID = nil
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Stops a look-up that's still running, so it doesn't keep loading pages for nothing.
    private func cancelProbe() {
        guard let id = probeID else { return }
        probeID = nil
        Task { try? await Engine.shared.call("cancel_probe", ["probe_id": id]) }
    }

    private func refreshClipboardHint() async {
        let patterns = try? await UIPasteboard.general.detectedPatterns(for: [\.probableWebURL])
        clipboardHasLink = patterns?.contains(\.probableWebURL) ?? false
    }
}

/// Pulls the first http(s) link out of shared text ("Check this out https://…").
func extractLink(_ text: String) -> String? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    return detector.matches(in: text, range: range)
        .compactMap(\.url)
        .first { $0.scheme == "http" || $0.scheme == "https" }?
        .absoluteString
}

// MARK: - Small cards

extension View {
    /// Content cards sit on a plain grouped background; Liquid Glass is kept for the
    /// controls floating above content (tab bar, toolbars, buttons), as Apple advises.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
    }
}

struct Backdrop: View {
    var body: some View {
        LinearGradient(colors: [Color("AccentColor").opacity(0.18), .clear],
                       startPoint: .top, endPoint: .center)
            .ignoresSafeArea()
            .background(Color(.systemGroupedBackground))
    }
}

struct EngineStartingCard: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Starting yt-dlp…").foregroundStyle(.secondary)
        }
        .card(padding: 18)
    }
}

struct MessageCard: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var action: (String, () -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.glass)
            }
        }
        .card(padding: 18)
    }
}

struct WelcomeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste a link from YouTube, X, Instagram, Reddit, TikTok or most other sites.")
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 10) {
                Feature(icon: "film.stack", text: "Pick a preset, or any exact video and audio stream")
                Feature(icon: "scissors", text: "Download only part of a video")
                Feature(icon: "photo.on.rectangle", text: "Cover art and details saved in the file")
                Feature(icon: "folder", text: "Everything lands in the Files app")
            }
        }
        .foregroundStyle(.secondary)
        .card(padding: 18)
    }

    struct Feature: View {
        let icon: String
        let text: String
        var body: some View {
            Label {
                Text(text).font(.footnote)
            } icon: {
                Image(systemName: icon).foregroundStyle(Color("AccentColor"))
            }
        }
    }
}
