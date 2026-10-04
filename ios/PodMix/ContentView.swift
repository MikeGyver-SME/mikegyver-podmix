import SwiftUI

struct ContentView: View {
    @StateObject private var store = ProjectStore()

    var body: some View {
        TabView {
            StitchView()
                .tabItem { Label("Stitch", systemImage: "film.stack") }
            MusicView()
                .tabItem { Label("Music", systemImage: "music.note") }
            ConvertView()
                .tabItem { Label("Convert", systemImage: "arrow.triangle.2.circlepath") }
            LevelView()
                .tabItem { Label("Level", systemImage: "waveform") }
        }
        .tint(Brand.navy)
        .environmentObject(store)
    }
}
