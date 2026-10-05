import SwiftUI
import UniformTypeIdentifiers

/// Tab 2: lay an MP3 bed under the stitched video (or any picked video),
/// with volume / fades / auto-ducking, then export the mixed MP4.
struct MusicView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showingVideoPicker = false
    @State private var showingMusicPicker = false
    @State private var isWorking = false
    @State private var isMixing = false
    @State private var progress = 0.0
    @State private var statusText = ""
    @State private var shareItem: ShareItem?
    @State private var alert: AlertMessage?
    @State private var builtMix: MixEngine.Mixed?

    var voiceURL: URL? { store.videoURL ?? store.lastStitchedURL }
    var voiceName: String {
        if !store.videoName.isEmpty { return store.videoName }
        if let url = store.lastStitchedURL { return url.lastPathComponent }
        return "None"
    }

    private var mixFooterText: String {
        var text = "Ducking is best-effort: the bed dips where the voice RMS clears −35 dBFS. Voice leveling uses the approximate in-app loudness engine."
        if builtMix?.isTitleCard == true {
            text += "\n\nThe voice has no video, so the MP4 uses a branded MikeGyver Studio title card."
        }
        return text
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice video") {
                    HStack {
                        Text(voiceName)
                            .lineLimit(1)
                        Spacer()
                        if store.lastStitchedURL != nil && store.videoURL == nil {
                            Text("stitched")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Pick a different video") { showingVideoPicker = true }
                        .font(.callout)
                }

                Section("Background music (MP3)") {
                    HStack {
                        Text(store.musicName.isEmpty ? "None" : store.musicName)
                            .lineLimit(1)
                        Spacer()
                    }
                    Button("Pick MP3") { showingMusicPicker = true }
                        .font(.callout)
                }

                Section("Mix") {
                    HStack {
                        Text("Music volume")
                        Slider(value: $store.settings.musicVolume, in: 0...1)
                        Text("\(Int(store.settings.musicVolume * 100))%")
                            .frame(width: 44, alignment: .trailing)
                            .font(.caption)
                    }
                    HStack {
                        Text("Fade in")
                        Slider(value: $store.settings.fadeIn, in: 0...10, step: 0.5)
                        Text("\(store.settings.fadeIn, specifier: "%.1f")s")
                            .frame(width: 44, alignment: .trailing)
                            .font(.caption)
                    }
                    HStack {
                        Text("Fade out")
                        Slider(value: $store.settings.fadeOut, in: 0...10, step: 0.5)
                        Text("\(store.settings.fadeOut, specifier: "%.1f")s")
                            .frame(width: 44, alignment: .trailing)
                            .font(.caption)
                    }
                    Toggle("Auto-duck under voice", isOn: $store.settings.duckingEnabled)
                    Picker("Voice level", selection: $store.settings.voiceLevel) {
                        ForEach(VoiceLevelOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }

                Section {
                    Button(isMixing ? "Mixing…" : "1. Build mix") { buildMix() }
                        .disabled(voiceURL == nil || store.musicURL == nil || isWorking)
                    Button("2. Export MP4") { exportMP4() }
                        .disabled(builtMix == nil || isWorking)
                    Button("3. Export audio-only (.m4a)") { exportAudio() }
                        .disabled(builtMix == nil || isWorking)
                } footer: {
                    Text(mixFooterText)
                }

                if isWorking {
                    Section {
                        ProgressView(value: progress) {
                            Text(statusText).font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Music Bed")
            .sheet(isPresented: $showingVideoPicker) {
                DocumentPicker(contentTypes: [.audiovisualContent]) { urls in
                    let staged = store.stage(urls)
                    if let url = staged.first {
                        store.videoURL = url
                        store.videoName = url.lastPathComponent
                        builtMix = nil
                    }
                }
            }
            .sheet(isPresented: $showingMusicPicker) {
                DocumentPicker(contentTypes: [.audio]) { urls in
                    let staged = store.stage(urls)
                    if let url = staged.first {
                        store.musicURL = url
                        store.musicName = url.lastPathComponent
                        builtMix = nil
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

    // MARK: - Actions

    private func buildMix() {
        guard let voice = voiceURL, let music = store.musicURL else {
            alert = AlertMessage(text: "Pick a voice video and an MP3 first.")
            return
        }
        let settings = store.settings
        isMixing = true
        statusText = "Building mix…"
        Task.detached {
            do {
                let mixed = try await MixEngine.build(voiceURL: voice, musicURL: music, settings: settings)
                await MainActor.run {
                    builtMix = mixed
                    isMixing = false
                    store.lastMixURL = nil
                }
            } catch {
                await MainActor.run {
                    isMixing = false
                    alert = AlertMessage(text: error.localizedDescription)
                }
            }
        }
    }

    private func exportMP4() {
        guard let mixed = builtMix else { return }
        isWorking = true
        progress = 0
        statusText = "Exporting MP4…"
        Task.detached {
            do {
                let dest = await MainActor.run { store.exportDestination(base: "podmix", ext: "mp4") }
                try await Exporter.exportVideo(
                    composition: mixed.composition,
                    videoComposition: mixed.videoComposition,
                    audioMix: mixed.audioMix,
                    to: dest) { p in
                        Task { @MainActor in progress = p }
                    }
                await MainActor.run {
                    isWorking = false
                    store.lastMixURL = dest
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

    private func exportAudio() {
        guard let mixed = builtMix else { return }
        isWorking = true
        progress = 0
        statusText = "Exporting audio…"
        Task.detached {
            do {
                let dest = await MainActor.run { store.exportDestination(base: "podmix-audio", ext: "m4a") }
                try await Exporter.exportAudio(
                    composition: mixed.composition,
                    audioMix: mixed.audioMix,
                    to: dest) { p in
                        Task { @MainActor in progress = p }
                    }
                await MainActor.run {
                    isWorking = false
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
