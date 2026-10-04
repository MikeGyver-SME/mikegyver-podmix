import SwiftUI
import UniformTypeIdentifiers

/// Tab 4: loudness-normalize an audio file to Mike's mastering presets.
struct LevelView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showingPicker = false
    @State private var audioURL: URL?
    @State private var audioName = ""
    @State private var preset: LevelPreset = .podcast
    @State private var isWorking = false
    @State private var statusText = ""
    @State private var resultText = ""
    @State private var shareItem: ShareItem?
    @State private var alert: AlertMessage?

    var body: some View {
        NavigationStack {
            Form {
                Section("Source audio") {
                    Text(audioName.isEmpty ? "None" : audioName)
                        .lineLimit(1)
                    Button("Pick audio file") { showingPicker = true }
                        .font(.callout)
                }

                Section("Target") {
                    Picker("Preset", selection: $preset) {
                        ForEach(LevelPreset.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button(isWorking ? "Working…" : "Normalize & Export (.m4a)") { normalize() }
                        .disabled(audioURL == nil || isWorking)
                } footer: {
                    Text("Measures K-weighted integrated loudness, applies the makeup gain, then soft-limits at the true-peak ceiling. Approximate — cross-check against loudify/ffmpeg two-pass for release masters.")
                }

                if isWorking {
                    Section {
                        ProgressView {
                            Text(statusText).font(.caption)
                        }
                    }
                }

                if !resultText.isEmpty {
                    Section("Result") {
                        Text(resultText)
                            .font(.callout)
                    }
                }

                Section {
                    Button("Clear staged files", role: .destructive) {
                        store.clearInbox()
                        audioURL = nil
                        audioName = ""
                        resultText = ""
                    }
                    .font(.callout)
                }
            }
            .navigationTitle("Level")
            .sheet(isPresented: $showingPicker) {
                DocumentPicker(contentTypes: [.audio]) { urls in
                    let staged = store.stage(urls)
                    if let url = staged.first {
                        audioURL = url
                        audioName = url.lastPathComponent
                        resultText = ""
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

    private func normalize() {
        guard let url = audioURL else { return }
        let target = preset
        let name = audioName
        isWorking = true
        statusText = "Measuring loudness…"
        resultText = ""
        Task.detached {
            do {
                var (left, right) = try AudioIO.readStereoFloat(url: url)
                await MainActor.run { statusText = "Applying gain + limiter…" }
                let result = LoudnessEngine.normalize(left: &left, right: &right,
                                                      targetLUFS: target.targetLUFS,
                                                      ceilingDBTP: target.ceilingDBTP)
                let base = (name as NSString).deletingPathExtension + "-leveled"
                let dest = await MainActor.run { store.exportDestination(base: base, ext: "m4a") }
                try AudioIO.writeAAC(url: dest, left: left, right: right)
                await MainActor.run {
                    isWorking = false
                    resultText = String(format: "Measured %.1f LUFS → applied %+.1f dB → target %@, −1 dBTP ceiling.",
                                        result.measuredLUFS, result.appliedGainDB, target.shortLabel)
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
