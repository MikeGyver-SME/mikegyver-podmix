import SwiftUI
import UniformTypeIdentifiers

/// Tab 3: WAV file(s) → MP3 via the vendored LAME encoder.
struct ConvertView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showingPicker = false
    @State private var bitrate: BitrateOption = .b192
    @State private var isWorking = false
    @State private var shareItem: ShareItem?
    @State private var alert: AlertMessage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.convertJobs.isEmpty {
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 64))
                        .foregroundStyle(Brand.navy, Brand.gold)
                    Text("No files yet")
                        .font(.title2)
                        .padding(.top, 8)
                    Text("Pick WAV files from the Files app and convert them to MP3 with the built-in LAME encoder.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    List {
                        ForEach(store.convertJobs) { job in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.sourceName)
                                    .lineLimit(1)
                                    .font(.callout)
                                HStack {
                                    Text(job.status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if let out = job.outputURL {
                                        Button("Share") { shareItem = ShareItem(url: out) }
                                            .font(.caption)
                                    }
                                }
                                if job.progress > 0 && job.progress < 1 {
                                    ProgressView(value: job.progress)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { store.convertJobs.remove(atOffsets: $0) }
                    }
                    .listStyle(.plain)
                }

                Picker("Bitrate", selection: $bitrate) {
                    ForEach(BitrateOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                HStack {
                    Button("Add WAVs") { showingPicker = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.navy)
                    Spacer()
                    Button(isWorking ? "Converting…" : "Convert all") { convertAll() }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.gold)
                        .disabled(isWorking || store.convertJobs.isEmpty)
                }
                .padding()
            }
            .navigationTitle("WAV → MP3")
            .toolbar { EditButton() }
            .sheet(isPresented: $showingPicker) {
                DocumentPicker(contentTypes: [.wav], allowsMultipleSelection: true) { urls in
                    for url in store.stage(urls) {
                        store.convertJobs.append(ConvertJob(sourceURL: url, sourceName: url.lastPathComponent))
                    }
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(urls: [item.url])
            }
            .alert("PodMix",
                   isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
                   presenting: alert) { _ in } message: { a in Text(a.text) }
        }
    }

    private func convertAll() {
        let jobs = store.convertJobs.filter { $0.outputURL == nil }
        let kbps = bitrate.rawValue
        isWorking = true
        Task.detached {
            for job in jobs {
                await MainActor.run {
                    store.updateJob(job.id) { $0.status = "Encoding…"; $0.progress = 0 }
                }
                do {
                    let base = (job.sourceName as NSString).deletingPathExtension
                    let dest = await MainActor.run { store.exportDestination(base: base, ext: "mp3") }
                    try MP3Encoder.encode(inputURL: job.sourceURL, outputURL: dest, bitrateKbps: kbps,
                        phase: { ph in
                            Task { @MainActor in
                                store.updateJob(job.id) { $0.status = ph }
                            }
                        },
                        progress: { p in
                            Task { @MainActor in
                                store.updateJob(job.id) { $0.progress = p }
                            }
                        })
                    await MainActor.run {
                        store.updateJob(job.id) { $0.status = "Done"; $0.progress = 1; $0.outputURL = dest }
                    }
                } catch {
                    await MainActor.run {
                        store.updateJob(job.id) { $0.status = "Failed: \(error.localizedDescription)" }
                    }
                }
            }
            await MainActor.run { isWorking = false }
        }
    }
}
