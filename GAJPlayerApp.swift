import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - App Entry
@main
struct MusiQApp: App {
    var body: some Scene {
        WindowGroup {
            MusiQRootView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Models
struct Track: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var artist: String
    var fileName: String
    var duration: TimeInterval

    var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }
}

struct Playlist: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var trackFileNames: [String] = []
    var customCoverFileName: String? = nil
}

enum VisualMode: String, CaseIterable {
    case sleeve = "Sleeve"
    case cdPlayer = "CD Player"
    case sideVinyl = "Side Vinyl"

    var icon: String {
        switch self {
        case .sleeve: return "square.fill"
        case .cdPlayer: return "opticaldisc"
        case .sideVinyl: return "record.circle"
        }
    }
}

enum EQPreset: String, CaseIterable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case vocal = "Vocal Boost"
    case lateNight = "Warm / Lo-Fi"
}

// MARK: - Fast Artwork & Metadata Cache
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()

    func artwork(for fileName: String) -> UIImage? {
        if let cached = cache.object(forKey: fileName as NSString) {
            return cached
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        let asset = AVURLAsset(url: url)
        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                if item.commonKey == .commonKeyArtwork,
                   let data = item.value as? Data,
                   let img = UIImage(data: data) {
                    cache.setObject(img, forKey: fileName as NSString)
                    return img
                }
            }
        }
        return nil
    }

    func setCustomArtwork(_ image: UIImage, for fileName: String) {
        cache.setObject(image, forKey: fileName as NSString)
    }
}

// MARK: - Isolated Playback Time Observer (Prevents Full-Screen Redraw Lag)
final class PlaybackProgressObserver: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    var isScrubbing: Bool = false
}

// MARK: - High-Performance Audio & Library Engine
final class MusiQEngine: ObservableObject {
    @Published var allTracks: [Track] = []
    @Published var playlists: [Playlist] = [] // Strictly user-created only
    @Published var currentQueue: [Track] = []
    @Published var currentIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var isShuffle: Bool = false
    @Published var isRepeat: Bool = false

    @Published var visualMode: VisualMode = .sideVinyl
    @Published var pitchCents: Float = 0 // -1200 to +1200
    @Published var playbackRate: Float = 1.0 // 0.5x to 2.0x
    @Published var eqPreset: EQPreset = .flat

    // A-B Loop state
    @Published var loopStart: Double? = nil
    @Published var loopEnd: Double? = nil

    let progress = PlaybackProgressObserver()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchNode = AVAudioUnitTimePitch()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 3)

    private var activeAudioFile: AVAudioFile?
    private var seekFrameOffset: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var totalFrames: AVAudioFramePosition = 0
    private var progressTimer: Timer?
    private var scheduleGeneration: Int = 0

    private let playlistsStorageKey = "MusiQ_User_Playlists_v1"

    var currentTrack: Track? {
        guard currentIndex >= 0 && currentIndex < currentQueue.count else { return nil }
        return currentQueue[currentIndex]
    }

    init() {
        configureAudioSession()
        setupEngineGraph()
        loadSavedPlaylists()
        scanLocalLibrary()
        setupRemoteTransportControls()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
    }

    private func setupEngineGraph() {
        engine.attach(playerNode)
        engine.attach(timePitchNode)
        engine.attach(eqNode)

        let bands = eqNode.bands
        bands[0].filterType = .lowShelf
        bands[0].frequency = 120
        bands[0].gain = 0
        bands[0].bypass = false

        bands[1].filterType = .parametric
        bands[1].frequency = 1200
        bands[1].bandwidth = 1.0
        bands[1].gain = 0
        bands[1].bypass = false

        bands[2].filterType = .highShelf
        bands[2].frequency = 6000
        bands[2].gain = 0
        bands[2].bypass = false

        engine.connect(playerNode, to: timePitchNode, format: nil)
        engine.connect(timePitchNode, to: eqNode, format: nil)
        engine.connect(eqNode, to: engine.mainMixerNode, format: nil)

        do {
            try engine.start()
        } catch {
            print("Engine start error: \(error)")
        }
    }

    // MARK: - Background File Scanning (Non-Blocking)
    func scanLocalLibrary() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let validExts: Set<String> = ["mp3", "m4a", "wav", "flac", "aac", "aiff"]

            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: docs,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            var discovered: [Track] = []

            for url in urls where validExts.contains(url.pathExtension.lowercased()) {
                let fileName = url.lastPathComponent
                let asset = AVURLAsset(url: url)
                var title = url.deletingPathExtension().lastPathComponent
                var artist = "Unknown Artist"

                for format in asset.availableMetadataFormats {
                    for item in asset.metadata(forFormat: format) {
                        if item.commonKey == .commonKeyTitle, let val = item.value as? String, !val.isEmpty {
                            title = val
                        } else if item.commonKey == .commonKeyArtist, let val = item.value as? String, !val.isEmpty {
                            artist = val
                        }
                    }
                }

                let durationSeconds = CMTimeGetSeconds(asset.duration)
                let safeDuration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 0

                discovered.append(
                    Track(
                        id: UUID(),
                        title: title,
                        artist: artist,
                        fileName: fileName,
                        duration: safeDuration
                    )
                )
            }

            discovered.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

            DispatchQueue.main.async {
                self.allTracks = discovered
                if self.currentQueue.isEmpty && !discovered.isEmpty {
                    self.currentQueue = discovered
                }
            }
        }
    }

    // MARK: - Manual Playlist Persistence
    func loadSavedPlaylists() {
        guard let data = UserDefaults.standard.data(forKey: playlistsStorageKey),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else {
            playlists = []
            return
        }
        playlists = decoded
    }

    func savePlaylists() {
        if let encoded = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(encoded, forKey: playlistsStorageKey)
        }
    }

    func createPlaylist(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists.append(Playlist(name: trimmed))
        savePlaylists()
    }

    func deletePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }

    func addTrack(_ track: Track, to playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[idx].trackFileNames.contains(track.fileName) {
            playlists[idx].trackFileNames.append(track.fileName)
            savePlaylists()
        }
    }

    func removeTrack(fileName: String, from playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].trackFileNames.removeAll { $0 == fileName }
        savePlaylists()
    }

    func tracks(for playlist: Playlist) -> [Track] {
        playlist.trackFileNames.compactMap { fileName in
            allTracks.first(where: { $0.fileName == fileName })
        }
    }

    // MARK: - Playback Controls
    func playTrack(_ track: Track, in queue: [Track]) {
        currentQueue = queue.isEmpty ? allTracks : queue
        if let idx = currentQueue.firstIndex(where: { $0.fileName == track.fileName }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }
        loadAndScheduleCurrentTrack(startFrame: 0, autoPlay: true)
    }

    private func loadAndScheduleCurrentTrack(startFrame: AVAudioFramePosition, autoPlay: Bool) {
        guard let track = currentTrack else { return }
        scheduleGeneration += 1
        let currentGen = scheduleGeneration

        playerNode.stop()
        loopStart = nil
        loopEnd = nil

        do {
            let file = try AVAudioFile(forReading: track.fileURL)
            activeAudioFile = file
            sampleRate = file.processingFormat.sampleRate
            totalFrames = file.length
            seekFrameOffset = max(0, min(startFrame, totalFrames))

            let remainingFrames = AVAudioFrameCount(max(0, totalFrames - seekFrameOffset))
            guard remainingFrames > 0 else { return }

            progress.duration = Double(totalFrames) / sampleRate
            progress.currentTime = Double(seekFrameOffset) / sampleRate

            if !engine.isRunning {
                try engine.start()
            }

            playerNode.scheduleSegment(
                file,
                startingFrame: seekFrameOffset,
                frameCount: remainingFrames,
                at: nil
            ) { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self, self.scheduleGeneration == currentGen else { return }
                    if self.isPlaying {
                        self.handleTrackCompletion()
                    }
                }
            }

            if autoPlay {
                playerNode.play()
                isPlaying = true
                startProgressTimer()
            }
            updateNowPlayingInfo()
        } catch {
            print("Playback load error: \(error)")
        }
    }

    func togglePlayPause() {
        if activeAudioFile == nil, let first = currentQueue.first ?? allTracks.first {
            playTrack(first, in: currentQueue.isEmpty ? allTracks : currentQueue)
            return
        }

        if isPlaying {
            playerNode.pause()
            isPlaying = false
            stopProgressTimer()
        } else {
            if !engine.isRunning {
                try? engine.start()
            }
            playerNode.play()
            isPlaying = true
            startProgressTimer()
        }
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        guard let file = activeAudioFile else { return }
        let targetFrame = AVAudioFramePosition(seconds * sampleRate)
        let clampedFrame = max(0, min(targetFrame, totalFrames - 100))
        seekFrameOffset = clampedFrame

        scheduleGeneration += 1
        let currentGen = scheduleGeneration

        playerNode.stop()
        let remaining = AVAudioFrameCount(max(0, totalFrames - clampedFrame))
        guard remaining > 0 else { return }

        playerNode.scheduleSegment(
            file,
            startingFrame: clampedFrame,
            frameCount: remaining,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.scheduleGeneration == currentGen else { return }
                if self.isPlaying {
                    self.handleTrackCompletion()
                }
            }
        }

        if isPlaying {
            playerNode.play()
        }
        progress.currentTime = seconds
        updateNowPlayingInfo()
    }

    func nextTrack() {
        guard !currentQueue.isEmpty else { return }
        if isShuffle && currentQueue.count > 1 {
            currentIndex = Int.random(in: 0..<currentQueue.count)
        } else {
            currentIndex = (currentIndex + 1) % currentQueue.count
        }
        loadAndScheduleCurrentTrack(startFrame: 0, autoPlay: isPlaying)
    }

    func previousTrack() {
        guard !currentQueue.isEmpty else { return }
        if progress.currentTime > 3.0 {
            seek(to: 0)
            return
        }
        currentIndex = (currentIndex - 1 + currentQueue.count) % currentQueue.count
        loadAndScheduleCurrentTrack(startFrame: 0, autoPlay: isPlaying)
    }

    private func handleTrackCompletion() {
        if isRepeat {
            loadAndScheduleCurrentTrack(startFrame: 0, autoPlay: true)
        } else {
            nextTrack()
        }
    }

    // MARK: - DSP Controls
    func setPitch(_ cents: Float) {
        pitchCents = cents
        timePitchNode.pitch = cents
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        timePitchNode.rate = rate
    }

    func setEQ(_ preset: EQPreset) {
        eqPreset = preset
        let b = eqNode.bands
        switch preset {
        case .flat:
            b[0].gain = 0; b[1].gain = 0; b[2].gain = 0
        case .bassBoost:
            b[0].gain = 8.5; b[1].gain = 1.0; b[2].gain = 1.5
        case .vocal:
            b[0].gain = -2.0; b[1].gain = 5.5; b[2].gain = 2.5
        case .lateNight:
            b[0].gain = 4.0; b[1].gain = -1.5; b[2].gain = -5.0
        }
    }

    func toggleABLoop() {
        if loopStart == nil {
            loopStart = progress.currentTime
        } else if loopEnd == nil {
            if progress.currentTime > (loopStart ?? 0) + 0.5 {
                loopEnd = progress.currentTime
            } else {
                loopStart = nil
            }
        } else {
            loopStart = nil
            loopEnd = nil
        }
    }

    // MARK: - Lightweight Progress Timer
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying, !self.progress.isScrubbing else { return }
            if let nodeTime = self.playerNode.lastRenderTime,
               let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime) {
                let currentFrame = self.seekFrameOffset + playerTime.sampleTime
                let seconds = Double(currentFrame) / self.sampleRate
                let clamped = max(0, min(seconds, self.progress.duration))
                self.progress.currentTime = clamped

                if let start = self.loopStart, let end = self.loopEnd, clamped >= end {
                    self.seek(to: start)
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Lock Screen & Control Center Integration
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextTrack()
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousTrack()
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: progress.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0
        ]
        if let art = ArtworkCache.shared.artwork(for: track.fileName) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - Looping Marquee Text (iOS Phone Call Style)
struct LoopingMarqueeText: View {
    let text: String
    let font: Font
    let textColor: Color

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let spacing: CGFloat = 48

    var body: some View {
        GeometryReader { geo in
            let overflows = textWidth > geo.size.width && geo.size.width > 0

            ZStack(alignment: .leading) {
                if overflows {
                    HStack(spacing: spacing) {
                        Text(text)
                            .font(font)
                            .foregroundColor(textColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(text)
                            .font(font)
                            .foregroundColor(textColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .offset(x: offset)
                } else {
                    Text(text)
                        .font(font)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .frame(width: geo.size.width, alignment: .center)
                }
            }
            .background(
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(GeometryReader { textGeo in
                        Color.clear
                            .onAppear {
                                textWidth = textGeo.size.width
                                containerWidth = geo.size.width
                                startScrollIfNeeded(container: geo.size.width, text: textGeo.size.width)
                            }
                            .onChange(of: text) { _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    textWidth = textGeo.size.width
                                    containerWidth = geo.size.width
                                    startScrollIfNeeded(container: geo.size.width, text: textGeo.size.width)
                                }
                            }
                    })
            )
            .clipped()
        }
        .frame(height: 30)
    }

    private func startScrollIfNeeded(container: CGFloat, text: CGFloat) {
        offset = 0
        guard text > container && container > 0 else { return }
        let totalShift = text + spacing
        let duration = Double(totalShift) / 36.0
        withAnimation(.linear(duration: duration).delay(1.0).repeatForever(autoreverses: false)) {
            offset = -totalShift
        }
    }
}

// MARK: - Root Tab View (Home/Playlists First, Songs Tab Second, YouTube Downloader Third)
struct MusiQRootView: View {
    @StateObject private var engine = MusiQEngine()
    @State private var selectedTab: Int = 0
    @State private var showFullPlayer: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                PlaylistsHomeView(engine: engine, showFullPlayer: $showFullPlayer)
                    .tabItem {
                        Label("Playlists", systemImage: "music.note.list")
                    }
                    .tag(0)

                AllSongsSearchView(engine: engine, showFullPlayer: $showFullPlayer)
                    .tabItem {
                        Label("Songs", systemImage: "music.note")
                    }
                    .tag(1)

                YouTubeDownloaderView(engine: engine)
                    .tabItem {
                        Label("YouTube DL", systemImage: "arrow.down.circle.fill")
                    }
                    .tag(2)
            }
            .tint(.purple)

            // Persistent Mini-Player Bar
            if let current = engine.currentTrack {
                MiniPlayerBar(engine: engine, track: current) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showFullPlayer = true
                    }
                }
                .padding(.bottom, 54)
            }
        }
        .fullScreenCover(isPresented: $showFullPlayer) {
            FullPlayerDeckView(engine: engine, isPresented: $showFullPlayer)
        }
    }
}

// MARK: - Tab 1: Playlists Home View (Strictly User-Created Only)
struct PlaylistsHomeView: View {
    @ObservedObject var engine: MusiQEngine
    @Binding var showFullPlayer: Bool
    @State private var showingNewPlaylistAlert = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

                if engine.playlists.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 50))
                            .foregroundColor(.purple.opacity(0.8))
                        Text("No Playlists Yet")
                            .font(.title3.bold())
                        Text("Playlists are never auto-generated.\nTap '+' to build your own custom playlists.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)

                        Button {
                            showingNewPlaylistAlert = true
                        } label: {
                            Label("Create Playlist", systemImage: "plus")
                                .font(.headline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.purple)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                        .padding(.top, 6)
                    }
                } else {
                    List {
                        ForEach(engine.playlists) { playlist in
                            NavigationLink(destination: PlaylistDetailView(engine: engine, playlistID: playlist.id, showFullPlayer: $showFullPlayer)) {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(LinearGradient(colors: [.purple.opacity(0.7), .indigo.opacity(0.4)], startAngle: .topLeading, endAngle: .bottomTrailing))
                                            .frame(width: 54, height: 54)
                                        Image(systemName: "music.note.list")
                                            .font(.title3)
                                            .foregroundColor(.white)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.name)
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        Text("\(playlist.trackFileNames.count) songs")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color.white.opacity(0.05))
                        }
                        .onDelete { indexSet in
                            indexSet.map { engine.playlists[$0] }.forEach(engine.deletePlaylist)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .padding(.bottom, engine.currentTrack != nil ? 70 : 0)
                }
            }
            .navigationTitle("MusiQ")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        engine.scanLocalLibrary()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newPlaylistName = ""
                        showingNewPlaylistAlert = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .alert("New Playlist", isPresented: $showingNewPlaylistAlert) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    engine.createPlaylist(name: newPlaylistName)
                }
            }
        }
    }
}

// MARK: - Playlist Detail View
struct PlaylistDetailView: View {
    @ObservedObject var engine: MusiQEngine
    let playlistID: UUID
    @Binding var showFullPlayer: Bool
    @State private var showSongPicker = false

    var playlist: Playlist? {
        engine.playlists.first(where: { $0.id == playlistID })
    }

    var body: some View {
        let tracks = playlist.map { engine.tracks(for: $0) } ?? []

        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

            if tracks.isEmpty {
                VStack(spacing: 12) {
                    Text("This playlist is empty.")
                        .foregroundColor(.secondary)
                    Button("Add Songs") {
                        showSongPicker = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            } else {
                List {
                    ForEach(tracks) { track in
                        TrackRowView(track: track) {
                            engine.playTrack(track, in: tracks)
                            showFullPlayer = true
                        }
                        .listRowBackground(Color.white.opacity(0.04))
                    }
                    .onDelete { offsets in
                        offsets.forEach { idx in
                            engine.removeTrack(fileName: tracks[idx].fileName, from: playlistID)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .padding(.bottom, engine.currentTrack != nil ? 70 : 0)
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSongPicker = true
                } label: {
                    Label("Add Songs", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showSongPicker) {
            NavigationStack {
                List(engine.allTracks) { track in
                    Button {
                        engine.addTrack(track, to: playlistID)
                    } label: {
                        HStack {
                            Text(track.title)
                                .foregroundColor(.white)
                            Spacer()
                            if playlist?.trackFileNames.contains(track.fileName) == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.purple)
                            }
                        }
                    }
                }
                .navigationTitle("Add to Playlist")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showSongPicker = false }
                    }
                }
            }
        }
    }
}

// MARK: - Tab 2: Global Searchable Songs Library
struct AllSongsSearchView: View {
    @ObservedObject var engine: MusiQEngine
    @Binding var showFullPlayer: Bool
    @State private var searchText: String = ""

    var filteredTracks: [Track] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return engine.allTracks
        }
        return engine.allTracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText) ||
            $0.fileName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

                if engine.allTracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Songs Found")
                            .font(.headline)
                        Text("Drop audio files into MusiQ via iTunes File Sharing or the Files app, or download tracks from the YouTube DL tab.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                        Button("Rescan Files") {
                            engine.scanLocalLibrary()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .padding(.top, 6)
                    }
                } else {
                    List(filteredTracks) { track in
                        TrackRowView(track: track) {
                            engine.playTrack(track, in: filteredTracks)
                            showFullPlayer = true
                        }
                        .contextMenu {
                            if !engine.playlists.isEmpty {
                                Menu("Add to Playlist") {
                                    ForEach(engine.playlists) { playlist in
                                        Button(playlist.name) {
                                            engine.addTrack(track, to: playlist.id)
                                        }
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.04))
                    }
                    .scrollContentBackground(.hidden)
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search any song or artist...")
                    .padding(.bottom, engine.currentTrack != nil ? 70 : 0)
                }
            }
            .navigationTitle("All Songs (\(engine.allTracks.count))")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        engine.scanLocalLibrary()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

struct TrackRowView: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let uiImage = ArtworkCache.shared.artwork(for: track.fileName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 48, height: 48)
                        .overlay(Image(systemName: "music.note").foregroundColor(.gray))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body.weight(.medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Mini Player Bar
struct MiniPlayerBar: View {
    @ObservedObject var engine: MusiQEngine
    let track: Track
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let art = ArtworkCache.shared.artwork(for: track.fileName) {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.3))
                    .frame(width: 42, height: 42)
                    .overlay(Image(systemName: "music.note").foregroundColor(.white))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                engine.togglePlayPause()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
            }

            Button {
                engine.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .onTapGesture(perform: onExpand)
    }
}

// MARK: - Full-Screen Player with Fixed Layout Constraints & Swipe-to-Dismiss
struct FullPlayerDeckView: View {
    @ObservedObject var engine: MusiQEngine
    @Binding var isPresented: Bool

    @State private var activeBottomSheet: BottomPanel? = nil
    @State private var dragOffset: CGSize = .zero

    enum BottomPanel: Identifiable {
        case dsp, queue
        var id: Int { hashValue }
    }

    var body: some View {
        GeometryReader { geo in
            let safeWidth = geo.size.width
            let artBoxSize = min(safeWidth - 96, 260)

            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.12, green: 0.09, blue: 0.15), Color(red: 0.04, green: 0.04, blue: 0.06)],
                    startAngle: .top,
                    endAngle: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 14) {
                    // Top Bar + Visual Mode Picker
                    HStack {
                        Button {
                            isPresented = false
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.title3.weight(.semibold))
                                .foregroundColor(.white.opacity(0.8))
                                .padding(8)
                        }
                        Spacer()
                        Capsule()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 42, height: 5)
                        Spacer()
                        Color.clear.frame(width: 36, height: 36)
                    }
                    .padding(.horizontal, 16)

                    // 3-Way Display Mode Switcher
                    HStack(spacing: 10) {
                        ForEach(VisualMode.allCases, id: \.self) { mode in
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    engine.visualMode = mode
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: mode.icon)
                                        .font(.caption)
                                    Text(mode.rawValue)
                                        .font(.caption.weight(.semibold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(engine.visualMode == mode ? Color.white.opacity(0.22) : Color.white.opacity(0.07))
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    // Fixed-Bounds Visualizer Container (Never Overflows Screen or Pushes Timers)
                    PlayerVisualizerStage(
                        mode: engine.visualMode,
                        track: engine.currentTrack,
                        isPlaying: engine.isPlaying,
                        boxSize: artBoxSize
                    )
                    .frame(width: safeWidth - 32, height: artBoxSize + 24)
                    .clipped()

                    Spacer(minLength: 4)

                    // Looping Marquee Title + Subtitle inside Padded Safe Box
                    VStack(spacing: 6) {
                        LoopingMarqueeText(
                            text: engine.currentTrack?.title ?? "No Track Selected",
                            font: .system(size: 22, weight: .bold),
                            textColor: .white
                        )
                        .frame(width: safeWidth - 48)

                        Text(engine.currentTrack?.artist ?? "MusiQ Local Library")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 24)

                    // Isolated Scrubber + Always-Visible Timers
                    IsolatedScrubberView(progress: engine.progress) { newSeconds in
                        engine.seek(to: newSeconds)
                    }
                    .padding(.horizontal, 24)

                    // A-B Loop Pill
                    Button {
                        engine.toggleABLoop()
                    } label: {
                        Text(abLoopLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(engine.loopStart != nil ? Color.purple : Color.white.opacity(0.12))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }

                    // Transport Controls
                    HStack(spacing: 34) {
                        Button {
                            engine.isShuffle.toggle()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.title3)
                                .foregroundColor(engine.isShuffle ? .purple : .white.opacity(0.5))
                        }

                        Button {
                            engine.previousTrack()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title)
                                .foregroundColor(.white)
                        }

                        Button {
                            engine.togglePlayPause()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.18))
                                    .frame(width: 72, height: 72)
                                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }

                        Button {
                            engine.nextTrack()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title)
                                .foregroundColor(.white)
                        }

                        Button {
                            engine.isRepeat.toggle()
                        } label: {
                            Image(systemName: "repeat")
                                .font(.title3)
                                .foregroundColor(engine.isRepeat ? .purple : .white.opacity(0.5))
                        }
                    }
                    .padding(.top, 4)

                    // Bottom Action Bar
                    HStack(spacing: 40) {
                        Button {
                            activeBottomSheet = .dsp
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "dial.high.fill")
                                Text("DSP / Pitch")
                                    .font(.caption2)
                            }
                            .foregroundColor(.white.opacity(0.8))
                        }

                        Button {
                            activeBottomSheet = .queue
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "list.bullet")
                                Text("Queue")
                                    .font(.caption2)
                            }
                            .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
            }
            .offset(x: max(0, dragOffset.width), y: max(0, dragOffset.height * 0.3))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Left-to-right swipe or downward swipe dismissal
                        if value.translation.width > 0 || value.translation.height > 0 {
                            dragOffset = value.translation
                        }
                    }
                    .onEnded { value in
                        if value.translation.width > 95 || value.translation.height > 140 {
                            isPresented = false
                        }
                        withAnimation(.spring()) {
                            dragOffset = .zero
                        }
                    }
            )
            .sheet(item: $activeBottomSheet) { panel in
                switch panel {
                case .dsp:
                    DSPControlSheet(engine: engine)
                        .presentationDetents([.medium])
                case .queue:
                    QueueSheetView(engine: engine)
                        .presentationDetents([.medium, .large])
                }
            }
        }
    }

    private var abLoopLabel: String {
        if let s = engine.loopStart, let e = engine.loopEnd {
            return String(format: "A-B Loop: %.0fs - %.0fs (Tap to Clear)", s, e)
        } else if let s = engine.loopStart {
            return String(format: "Loop A: %.0fs (Tap to Set B)", s)
        } else {
            return "A-B Loop"
        }
    }
}

// MARK: - Isolated Scrubber & Timers (Always Visible, Zero Lag)
struct IsolatedScrubberView: View {
    @ObservedObject var progress: PlaybackProgressObserver
    let onCommitSeek: (Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { min(progress.currentTime, max(progress.duration, 1)) },
                    set: { newVal in
                        progress.isScrubbing = true
                        progress.currentTime = newVal
                    }
                ),
                in: 0...max(progress.duration, 1),
                onEditingChanged: { editing in
                    progress.isScrubbing = editing
                    if !editing {
                        onCommitSeek(progress.currentTime)
                    }
                }
            )
            .tint(.white)

            HStack {
                Text(formatTime(progress.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                Text("-" + formatTime(max(0, progress.duration - progress.currentTime)))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.75))
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Constrained 3-Way Artwork Visualizer Stage
struct PlayerVisualizerStage: View {
    let mode: VisualMode
    let track: Track?
    let isPlaying: Bool
    let boxSize: CGFloat

    @State private var spinAngle: Double = 0

    var artworkImage: UIImage? {
        guard let fileName = track?.fileName else { return nil }
        return ArtworkCache.shared.artwork(for: fileName)
    }

    var body: some View {
        ZStack {
            switch mode {
            case .sleeve:
                sleeveCover(size: boxSize)

            case .cdPlayer:
                ZStack {
                    Circle()
                        .fill(
                            AngularGradient(
                                gradient: Gradient(colors: [.gray.opacity(0.4), .white.opacity(0.85), .purple.opacity(0.35), .gray.opacity(0.4)]),
                                center: .center
                            )
                        )
                        .frame(width: boxSize, height: boxSize)

                    if let img = artworkImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: boxSize * 0.92, height: boxSize * 0.92)
                            .clipShape(Circle())
                    }

                    Circle()
                        .stroke(Color.black.opacity(0.45), lineWidth: 6)
                        .frame(width: boxSize * 0.3, height: boxSize * 0.3)

                    Circle()
                        .fill(Color(red: 0.08, green: 0.08, blue: 0.1))
                        .frame(width: boxSize * 0.18, height: boxSize * 0.18)
                }
                .rotationEffect(.degrees(isPlaying ? 360 : 0))
                .animation(isPlaying ? .linear(duration: 8).repeatForever(autoreverses: false) : .default, value: isPlaying)

            case .sideVinyl:
                let sleeveDim = boxSize * 0.82
                let vinylDim = boxSize * 0.78
                HStack(spacing: -vinylDim * 0.48) {
                    sleeveCover(size: sleeveDim)
                        .zIndex(2)

                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color(white: 0.18), Color.black, Color(white: 0.12), Color.black],
                                    center: .center,
                                    startRadius: 10,
                                    endRadius: vinylDim * 0.5
                                )
                            )
                            .frame(width: vinylDim, height: vinylDim)

                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            .frame(width: vinylDim * 0.78, height: vinylDim * 0.78)

                        if let img = artworkImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: vinylDim * 0.36, height: vinylDim * 0.36)
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color.purple)
                                .frame(width: vinylDim * 0.36, height: vinylDim * 0.36)
                        }

                        Circle()
                            .fill(Color.black)
                            .frame(width: 12, height: 12)
                    }
                    .rotationEffect(.degrees(isPlaying ? 360 : 0))
                    .animation(isPlaying ? .linear(duration: 6).repeatForever(autoreverses: false) : .default, value: isPlaying)
                    .zIndex(1)
                }
            }
        }
    }

    @ViewBuilder
    private func sleeveCover(size: CGFloat) -> some View {
        if let img = artworkImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 8)
        } else {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [.purple.opacity(0.6), .indigo.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: size * 0.28))
                        .foregroundColor(.white.opacity(0.75))
                )
                .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 8)
        }
    }
}

// MARK: - DSP & EQ Sheet
struct DSPControlSheet: View {
    @ObservedObject var engine: MusiQEngine

    var body: some View {
        NavigationStack {
            Form {
                Section("EQ Preset") {
                    Picker("EQ Profile", selection: Binding(
                        get: { engine.eqPreset },
                        set: { engine.setEQ($0) }
                    )) {
                        ForEach(EQPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Playback Speed (\(String(format: "%.2fx", engine.playbackRate)))") {
                    Slider(
                        value: Binding(
                            get: { engine.playbackRate },
                            set: { engine.setRate($0) }
                        ),
                        in: 0.5...2.0,
                        step: 0.05
                    )
                    Button("Reset Speed (1.0x)") {
                        engine.setRate(1.0)
                    }
                }

                Section("Pitch Shift (\(Int(engine.pitchCents / 100)) Semitones)") {
                    Slider(
                        value: Binding(
                            get: { engine.pitchCents },
                            set: { engine.setPitch($0) }
                        ),
                        in: -1200...1200,
                        step: 100
                    )
                    Button("Reset Pitch (0 st)") {
                        engine.setPitch(0)
                    }
                }
            }
            .navigationTitle("DSP / Audio Engine")
        }
    }
}

// MARK: - Queue Sheet
struct QueueSheetView: View {
    @ObservedObject var engine: MusiQEngine

    var body: some View {
        NavigationStack {
            List(Array(engine.currentQueue.enumerated()), id: \.element.id) { idx, track in
                Button {
                    engine.playTrack(track, in: engine.currentQueue)
                } label: {
                    HStack {
                        Text(track.title)
                            .foregroundColor(idx == engine.currentIndex ? .purple : .white)
                            .fontWeight(idx == engine.currentIndex ? .bold : .regular)
                        Spacer()
                        if idx == engine.currentIndex {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundColor(.purple)
                        }
                    }
                }
            }
            .navigationTitle("Up Next")
        }
    }
}

// MARK: - Tab 3: Integrated YouTube Song & Playlist Downloader
struct YouTubeDownloaderView: View {
    @ObservedObject var engine: MusiQEngine
    @State private var urlInput: String = ""
    @State private var customTitle: String = ""
    @State private var customArtist: String = ""
    @State private var statusMessage: String = "Paste a YouTube video/playlist link or direct audio stream URL."
    @State private var isDownloading: Bool = false

    private let cobaltInstances = [
        "https://api.cobalt.tools/api/json"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("YouTube / Audio Link") {
                    TextField("https://youtube.com/watch?v=... or playlist", text: $urlInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Optional Custom Metadata") {
                    TextField("Custom Song Title (Leave blank for auto)", text: $customTitle)
                    TextField("Artist Name (Optional)", text: $customArtist)
                }

                Section {
                    Button {
                        startDownload()
                    } label: {
                        HStack {
                            Spacer()
                            if isDownloading {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Downloading & Tagging...")
                            } else {
                                Label("Download to MusiQ Library", systemImage: "arrow.down.circle.fill")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDownloading)
                }

                Section("Status") {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("YouTube Downloader")
        }
    }

    private func startDownload() {
        let trimmedURL = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetURL = URL(string: trimmedURL) else {
            statusMessage = "Invalid URL format."
            return
        }

        isDownloading = true
        statusMessage = "Fetching metadata and audio stream..."

        Task {
            do {
                // 1. Fetch Title & Thumbnail via YouTube oEmbed if YouTube URL
                var resolvedTitle = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                var thumbnailData: Data? = nil

                if trimmedURL.contains("youtube.com") || trimmedURL.contains("youtu.be") {
                    if let oembedURL = URL(string: "https://www.youtube.com/oembed?url=\(trimmedURL)&format=json"),
                       let (data, _) = try? await URLSession.shared.data(from: oembedURL),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if resolvedTitle.isEmpty, let ytTitle = json["title"] as? String {
                            resolvedTitle = ytTitle
                        }
                        if let thumbStr = json["thumbnail_url"] as? String,
                           let thumbURL = URL(string: thumbStr),
                           let (imgData, _) = try? await URLSession.shared.data(from: thumbURL) {
                            thumbnailData = imgData
                        }
                    }
                }

                if resolvedTitle.isEmpty {
                    resolvedTitle = targetURL.deletingPathExtension().lastPathComponent
                }

                // 2. Resolve direct audio stream
                let directAudioURL = try await resolveAudioStreamURL(from: targetURL)
                let (tempFileURL, _) = try await URLSession.shared.download(from: directAudioURL)

                let safeFileName = resolvedTitle
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-") + ".m4a"

                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destinationURL = docs.appendingPathComponent(safeFileName)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempFileURL, to: destinationURL)

                if let thumbData = thumbnailData, let image = UIImage(data: thumbData) {
                    ArtworkCache.shared.setCustomArtwork(image, for: safeFileName)
                }

                await MainActor.run {
                    isDownloading = false
                    statusMessage = "Saved '\(resolvedTitle)' to your Songs library!"
                    urlInput = ""
                    customTitle = ""
                    engine.scanLocalLibrary()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    statusMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func resolveAudioStreamURL(from inputURL: URL) async throws -> URL {
        let ext = inputURL.pathExtension.lowercased()
        if ["mp3", "m4a", "wav", "flac"].contains(ext) {
            return inputURL
        }

        guard let apiEndpoint = URL(string: cobaltInstances[0]) else {
            return inputURL
        }

        var request = URLRequest(url: apiEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "url": inputURL.absoluteString,
            "isAudioOnly": true,
            "aFormat": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let streamURLStr = json["url"] as? String,
           let streamURL = URL(string: streamURLStr) {
            return streamURL
        }
        throw URLError(.cannotFindHost)
    }
}
