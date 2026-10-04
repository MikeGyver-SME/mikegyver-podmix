import SwiftUI
import UniformTypeIdentifiers

/// Tab 1: pick MP4s, order + trim them, stitch into one MP4.
struct StitchView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showingPicker = false
    @State private var isWorking = false
    @State private var progress = 0.0
    @State private var statusText = ""
    @State private var shareItem: ShareItem?
    @State private var alert: AlertMessage?
    @State private var expandedClip: UUID?

    var totalDuration: Double {
        store.clips.reduce(0) { $0 + $1.trimmedDuration }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.clips.isEmpty {
                    Spacer()
                    Image(systemName: "film.stack")
                        .font(.system(size: 64))
                        .foregroundStyle(Brand.navy, Brand.gold)
                    Text("No clips yet")
                        .font(.title2)
                        .padding(.top, 8)
                    Text("Pick MP4s from the Files app, then drag to reorder and trim each one.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    List {
                        ForEach(store.clips) { clip in
                            clipRow(clip)
                        }
                        .onDelete { store.clips.remove(atOffsets: $0) }
                        .onMove { store.clips.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.plain)
                }

                if isWorking {
                    VStack(spacing: 6) {
                        ProgressView(value: progress) {
                            Text(statusText).font(.caption)
                        }
                    }
                    .padding(.horizontal)
                }

                HStack {
                    Button("Add clips") { showingPicker = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.navy)
                    Spacer()
                    Text("Total \(formatDuration(totalDuration))")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .padding()

                Button("Stitch MP4") { stitch() }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.gold)
                    .disabled(store.clips.isEmpty || isWorking)
                    .padding(.bottom)
            }
            .navigationTitle("Stitch")
            .toolbar { EditButton() }
            .sheet(isPresented: $showingPicker) {
                DocumentPicker(contentTypes: [.audiovisualContent], allowsMultipleSelection: true) { urls in
                    Task { await store.addClips(urls) }
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

    // MARK: - Clip rows

    private func clipRow(_ clip: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(clip.displayName)
                    .lineLimit(1)
                    .font(.callout)
                Spacer()
                Text(formatDuration(clip.trimmedDuration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: expandedClip == clip.id ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                expandedClip = (expandedClip == clip.id) ? nil : clip.id
            }
            if expandedClip == clip.id {
                VStack(spacing: 4) {
                    HStack {
                        Text("In")
                            .font(.caption)
                            .frame(width: 28, alignment: .leading)
                        Slider(value: startBinding(for: clip), in: 0...max(0.01, clip.duration))
                        Text(formatDuration(clip.trimStart))
                            .font(.caption)
                            .frame(width: 44, alignment: .trailing)
                    }
                    HStack {
                        Text("Out")
                            .font(.caption)
                            .frame(width: 28, alignment: .leading)
                        Slider(value: endBinding(for: clip), in: 0...max(0.01, clip.duration))
                        Text(formatDuration(clip.trimEnd))
                            .font(.caption)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func startBinding(for clip: ClipItem) -> Binding<Double> {
        trimBinding(for: clip, isStart: true)
    }

    private func endBinding(for clip: ClipItem) -> Binding<Double> {
        trimBinding(for: clip, isStart: false)
    }

    private func trimBinding(for clip: ClipItem, isStart: Bool) -> Binding<Double> {
        Binding(
            get: {
                guard let idx = store.clips.firstIndex(where: { $0.id == clip.id }) else { return 0 }
                return isStart ? store.clips[idx].trimStart : store.clips[idx].trimEnd
            },
            set: { newValue in
                guard let idx = store.clips.firstIndex(where: { $0.id == clip.id }) else { return }
                let clamped = min(max(0, newValue), store.clips[idx].duration)
                if isStart {
                    store.clips[idx].trimStart = min(clamped, store.clips[idx].trimEnd)
                } else {
                    store.clips[idx].trimEnd = max(clamped, store.clips[idx].trimStart)
                }
            }
        )
    }

    // MARK: - Stitch

    private func stitch() {
        let clips = store.clips
        isWorking = true
        progress = 0
        statusText = "Building timeline…"
        Task.detached {
            do {
                let stitched = try await StitchEngine.build(clips: clips)
                await MainActor.run { statusText = "Exporting MP4…" }
                let dest = await MainActor.run { store.exportDestination(base: "stitched", ext: "mp4") }
                try await Exporter.exportVideo(
                    composition: stitched.composition,
                    videoComposition: stitched.videoComposition,
                    audioMix: nil,
                    to: dest) { p in
                        Task { @MainActor in progress = p }
                    }
                await MainActor.run {
                    isWorking = false
                    store.lastStitchedURL = dest
                    shareItem = ShareItem(url: dest)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    alert = AlertMessage(text: error.localizedDescription)
                }
            }
        }
    }
}
