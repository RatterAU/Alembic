import SwiftUI

/// Downloads in progress and just finished, under the link box.
struct DownloadsSection: View {
    @Environment(Store.self) private var store
    @State private var detail: Job?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloads").font(.title3.weight(.semibold))
                Spacer()
                if store.jobs.contains(where: { !$0.isActive }) {
                    Button("Clear finished") { withAnimation { store.clearFinished() } }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(store.jobs) { job in
                    JobRow(job: job) { detail = job }
                    if job.id != store.jobs.last?.id { Divider().padding(.leading, 92) }
                }
            }
            .card(padding: 0)
        }
        .sheet(item: $detail) { JobDetail(job: $0) }
    }
}

struct JobRow: View {
    @Environment(Store.self) private var store
    let job: Job
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let onOpen {
                Button(action: onOpen) { summary }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows details and the yt-dlp log")
            } else {
                summary
            }

            Group {
                switch job.status {
                case .error, .cancelled:
                    Button { store.retry(job) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Try again")
                case .finished:
                    if let file = job.files.first {
                        ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share")
                    }
                default:
                    Button { store.cancel(job) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel download")
                        .disabled(job.cancelRequested)
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Thumbnail(url: job.thumbnail)
                .frame(width: 68, height: 40)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.subheadline.weight(.medium)).lineLimit(1)
                status
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch job.status {
        case .finished:
            if let warning = job.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else {
                Label("Saved · \(job.summary)", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).lineLimit(1)
            }
        case .error:
            Text(job.error ?? "Failed").font(.caption).foregroundStyle(.red).lineLimit(2)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        case .queued:
            Text("Waiting · \(job.summary)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .processing:
            // Processing has no byte count: show FFmpeg's own progress when it gives one.
            if let step = job.stepProgress {
                ProgressView(value: step).tint(Color("AccentColor"))
            } else {
                ProgressView().progressViewStyle(.linear).tint(Color("AccentColor"))
            }
            Text(job.phase).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        default:
            ProgressView(value: job.progress)
                .tint(Color("AccentColor"))
            Text(statusLine).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
    }

    private var statusLine: String {
        var bits = [job.phase]
        if job.status == .downloading, !job.cancelRequested {
            bits.append("\(Int(job.progress * 100))%")
            if let s = job.speed, s > 0 { bits.append(s.bytesText + "/s") }
            if let e = job.eta, e > 0 { bits.append(e.durationText + " left") }
        }
        return bits.joined(separator: " · ")
    }
}

struct JobDetail: View {
    @Environment(\.dismiss) private var dismiss
    let job: Job

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Status", value: job.status.rawValue.capitalized)
                    LabeledContent("Chosen", value: job.summary)
                    if let err = job.error {
                        Text(err).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let warning = job.warning {
                        Text(warning).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    Text(job.url).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !job.files.isEmpty {
                    Section("Files") {
                        ForEach(job.files, id: \.self) { file in
                            ShareLink(item: file) {
                                Label(file.lastPathComponent, systemImage: "doc")
                            }
                        }
                    }
                }
                Section {
                    Text(job.log.isEmpty ? "Nothing yet" : job.log.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    HStack {
                        Text("yt-dlp log")
                        Spacer()
                        Button("Copy") { UIPasteboard.general.string = job.log.joined(separator: "\n") }
                            .font(.caption)
                    }
                } footer: {
                    Text("If something fails, copy this log into an issue on GitHub.")
                }
            }
            .navigationTitle(job.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct Thumbnail: View {
    let url: String?
    var body: some View {
        if let url, let u = URL(string: url) {
            AsyncImage(url: u) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Rectangle().fill(.quaternary) }
        } else {
            Rectangle().fill(.quaternary)
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
        }
    }
}
