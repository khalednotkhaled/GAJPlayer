import SwiftUI
import AVFoundation
import Accelerate
import MediaPlayer
import UniformTypeIdentifiers
import PhotosUI
import WidgetKit
import UIKit

// MARK: - Data Models
struct LyricLine: Identifiable, Hashable, Codable {
    var id = UUID()
    let time: Double
    let text: String
}

struct TrackBookmark: Identifiable, Hashable, Codable {
    var id = UUID()
    let time: Double
    var label: String
}

struct Song: Identifiable, Hashable, Codable {
    var id: String { fileName }
    let fileName: String
    var title: String
    var artist: String
    var album: String
    var era: String
    var trackNumber: Int
    var bpm: Int?
    var musicalKey: String?
    var notes: String?
    var isFavorite: Bool
    var playCount: Int
    var lastPlayed: Date?
    var bookmarks: [TrackBookmark]
    var rawLyrics: String?
    var syncedLyrics: [LyricLine]
    var artworkData: Data?

    var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music")
            .appendingPathComponent(fileName)
    }

    var artworkImage: UIImage? {
        guard let data = artworkData else { return nil }
        return UIImage(data: data)
    }
}

struct AlbumGroup: Identifiable, Hashable {
    var id: String { title + "|" + artist }
    let title: String
    let artist: String
    let era: String
    let artworkData: Data?
    var songs: [Song]

    var artworkImage: UIImage? {
        guard let data = artworkData else { return nil }
        return UIImage(data: data)
    }
}

struct Playlist: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var subtitle: String
    var songFileNames: [String]
}

enum VisualPlayerStyle: String, CaseIterable, Identifiable {
    case coverSleeve = "Sleeve"
    case cdWalkman = "CD Player"
    case sideVinyl = "Side Vinyl"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .coverSleeve: return "square.fill"
        case .cdWalkman:   return "opticaldisc.fill"
        case .sideVinyl:   return "record.circle.fill"
        }
    }
}

enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat Studio"
    case bass808 = "808 Bass Boost"
    case mpcWarmth = "MPC 2000XL Warmth"
    case vocalCrisp = "Ye Vocal Presence"
    case chopped = "Chopped & Screwed"

    var id: String { rawValue }

    var gains: [Float] {
        switch self {
        case .flat:       return [0, 0, 0, 0, 0]
        case .bass808:    return [7.5, 4.5, -1.0, 1.5, 2.5]
        case .mpcWarmth:  return [4.0, 3.5, 1.5, -1.5, -3.0]
        case .vocalCrisp: return [-1.0, 0.5, 3.5, 4.5, 3.0]
        case .chopped:    return [8.0, 5.0, -2.0, -3.0, -4.5]
        }
    }
}

// MARK: - Dominant Color Extractor
extension UIImage {
    func dominantColor() -> Color {
        guard let inputImage = CIImage(image: self) else { return .orange }
        let extentVector = CIVector(
            x: inputImage.extent.origin.x,
            y: inputImage.extent.origin.y,
            z: inputImage.extent.size.width,
            w: inputImage.extent.size.height
        )
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]
        ),
        let outputImage = filter.outputImage else { return .orange }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0

        let maxC = max(r, max(g, b))
        let boost = maxC < 0.25 ? 2.2 : (maxC < 0.5 ? 1.35 : 1.0)
        return Color(
            red: min(r * boost, 1.0),
            green: min(g * boost, 1.0),
            blue: min(b * boost, 1.0)
        )
    }
}

// MARK: - Haptics Helper
enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

// MARK: - Cloud Lyrics Fetcher (LRCLIB Synced + Genius/OVH Fallback)
enum CloudLyricsFetcher {
    struct LRCLibResponse: Decodable {
        let trackName: String?
        let artistName: String?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    static func cleanTrackTitle(_ raw: String) -> String {
        // Strip common leak tags like [V2], (feat. ...), (Ref), track numbers so search hits cleanly
        var s = raw
        let patterns = [
            #"^\d+[\s\.\-_]+"#,
            #"\[.*?\]"#,
            #"\((?:feat|ft|prod|v\d|ref|leak|og|mumble|demo).*?\)"#
        ]
        for pat in patterns {
            s = s.replacingOccurrences(of: pat, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fetchLyrics(title: String, artist: String) async -> String? {
        let cleanTitle = cleanTrackTitle(title)
        let cleanArtist = artist.lowercased() == "ye" ? "Kanye West" : artist

        // 1. Query LRCLIB for timestamped .LRC or plain lyrics
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: "\(cleanArtist) \(cleanTitle)")
        ]

        if let url = comps?.url {
            var request = URLRequest(url: url)
            request.setValue("GAJVaultPlayer/2.0 (iOS)", forHTTPHeaderField: "User-Agent")
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let results = try? JSONDecoder().decode([LRCLibResponse].self, from: data),
               let best = results.first {
                if let synced = best.syncedLyrics, !synced.isEmpty {
                    return synced
                }
                if let plain = best.plainLyrics, !plain.isEmpty {
                    return plain
                }
            }
        }

        // 2. Fallback: Query LRCLIB by track_name only (great for unreleased Ye cuts under different artist tags)
        var titleOnlyComps = URLComponents(string: "https://lrclib.net/api/search")
        titleOnlyComps?.queryItems = [URLQueryItem(name: "track_name", value: cleanTitle)]
        if let url = titleOnlyComps?.url {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let results = try? JSONDecoder().decode([LRCLibResponse].self, from: data),
               let match = results.first(where: {
                   ($0.artistName?.localizedCaseInsensitiveContains("Kanye") == true) ||
                   ($0.artistName?.localizedCaseInsensitiveContains("Ye") == true)
               }) ?? results.first {
                if let synced = match.syncedLyrics, !synced.isEmpty { return synced }
                if let plain = match.plainLyrics, !plain.isEmpty { return plain }
            }
        }

        return nil
    }
}

// MARK: - Studio Audio Engine & Library Manager
@MainActor
class MusicPlayerManager: NSObject, ObservableObject {
    @Published var library: [Song] = []
    @Published var playlists: [Playlist] = []
    @Published var queue: [Song] = []
    @Published var currentIndex: Int = 0

    // Playback & Visual State
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0.0
    @Published var duration: Double = 1.0
    @Published var isShuffle: Bool = false
    @Published var repeatMode: RepeatMode = .none
    @Published var dominantAccent: Color = .orange
    @Published var visualStyle: VisualPlayerStyle = .cdWalkman
    @Published var isFetchingLyrics: Bool = false

    // Studio DSP Controls
    @Published var playbackRate: Float = 1.0 { didSet { applyDSPSettings() } }
    @Published var pitchCents: Float = 0.0 { didSet { applyDSPSettings() } }
    @Published var isTapeModeLinked: Bool = false { didSet { applyDSPSettings() } }
    @Published var eqGains: [Float] = [0, 0, 0, 0, 0] { didSet { applyEQSettings() } }
    @Published var selectedEQPreset: EQPreset = .flat

    // A-B Loop State
    @Published var loopStart: Double? = nil
    @Published var loopEnd: Double? = nil

    // Live 16-Band FFT Spectrum
    @Published var spectrumBars: [Float] = Array(repeating: 0.08, count: 16)

    // Sleep Timer
    @Published var sleepTimerRemaining: Int? = nil
    private var sleepTimerTask: Task<Void, Never>? = nil

    enum RepeatMode {
        case none, all, one
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchNode = AVAudioUnitTimePitch()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 5)

    private var audioFile: AVAudioFile?
    private var sampleRate: Double = 44100.0
    private var totalFrames: AVAudioFramePosition = 0
    private var seekFrameOffset: AVAudioFramePosition = 0
    private var scheduleGeneration: Int = 0
    private var displayLinkTimer: Timer?
    private var isTapInstalled = false

    let eqFrequencies: [Float] = [60, 230, 910, 3600, 14000]
    let eqLabels: [String] = ["60Hz", "230Hz", "910Hz", "3.6k", "14k"]

    var currentSong: Song? {
        guard currentIndex >= 0 && currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    var albums: [AlbumGroup] {
        let grouped = Dictionary(grouping: library) { $0.album }
        return grouped.map { albumTitle, tracks in
            let sorted = tracks.sorted {
                if $0.trackNumber == $1.trackNumber { return $0.title < $1.title }
                return $0.trackNumber < $1.trackNumber
            }
            let artist = sorted.first?.artist ?? "Ye"
            let era = sorted.first?.era ?? "Good Ass Job Era"
            let art = sorted.compactMap { $0.artworkData }.first
            return AlbumGroup(title: albumTitle, artist: artist, era: era, artworkData: art, songs: sorted)
        }.sorted { $0.title < $1.title }
    }

    override init() {
        super.init()
        setupAudioSession()
        setupAudioEngineGraph()
        setupRemoteTransportControls()
        loadPersistedState()
        Task { await scanDocumentsDirectoryForNewFiles() }
        startProgressTimer()
    }

    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("AudioSession error: \(error)")
        }
    }

    private func setupAudioEngineGraph() {
        engine.attach(playerNode)
        engine.attach(timePitchNode)
        engine.attach(eqNode)

        for i in 0..<5 {
            let band = eqNode.bands[i]
            band.filterType = (i == 0) ? .lowShelf : (i == 4 ? .highShelf : .parametric)
            band.frequency = eqFrequencies[i]
            band.bandwidth = 1.0
            band.gain = 0.0
            band.bypass = false
        }

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: timePitchNode, format: format)
        engine.connect(timePitchNode, to: eqNode, format: format)
        engine.connect(eqNode, to: engine.mainMixerNode, format: format)

        installSpectrumTap()
        try? engine.start()
    }

    private func installSpectrumTap() {
        guard !isTapInstalled else { return }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }

        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var bars = [Float](repeating: 0.08, count: 16)
            let chunkSize = max(1, frameLength / 16)
            for b in 0..<16 {
                let start = b * chunkSize
                var sum: Float = 0
                for i in start..<min(start + chunkSize, frameLength) {
                    let s = channelData[i]
                    sum += s * s
                }
                let rms = sqrt(sum / Float(chunkSize))
                let scaled = min(1.0, max(0.08, rms * (3.8 + Float(b) * 0.25)))
                bars[b] = scaled
            }

            Task { @MainActor [weak self] in
                guard let self = self, self.isPlaying else { return }
                withAnimation(.linear(duration: 0.08)) {
                    self.spectrumBars = bars
                }
            }
        }
        isTapInstalled = true
    }

    private func applyDSPSettings() {
        timePitchNode.rate = playbackRate
        if isTapeModeLinked {
            timePitchNode.pitch = 1200.0 * log2(max(0.25, playbackRate))
        } else {
            timePitchNode.pitch = pitchCents
        }
        updateNowPlayingInfo()
    }

    private func applyEQSettings() {
        for i in 0..<min(5, eqGains.count) {
            eqNode.bands[i].gain = eqGains[i]
        }
    }

    func applyPreset(_ preset: EQPreset) {
        selectedEQPreset = preset
        eqGains = preset.gains
        if preset == .chopped {
            isTapeModeLinked = true
            playbackRate = 0.82
        } else if isTapeModeLinked && playbackRate == 0.82 {
            playbackRate = 1.0
            isTapeModeLinked = false
            pitchCents = 0
        }
        Haptics.light()
    }

    func resetDSP() {
        isTapeModeLinked = false
        playbackRate = 1.0
        pitchCents = 0.0
        selectedEQPreset = .flat
        eqGains = [0, 0, 0, 0, 0]
        Haptics.medium()
    }

    // MARK: - Playback & Scheduling
    func startQueue(_ songs: [Song], startingAt song: Song) {
        guard !songs.isEmpty else { return }
        self.queue = isShuffle ? songs.shuffled() : songs
        if let idx = self.queue.firstIndex(where: { $0.id == song.id }) {
            self.currentIndex = idx
        } else {
            self.currentIndex = 0
        }
        playCurrent()
    }

    func playNextInQueue(_ song: Song) {
        if queue.isEmpty {
            startQueue([song], startingAt: song)
            return
        }
        let insertIndex = min(currentIndex + 1, queue.count)
        queue.insert(song, at: insertIndex)
        Haptics.success()
    }

    func addToEndOfQueue(_ song: Song) {
        if queue.isEmpty {
            startQueue([song], startingAt: song)
            return
        }
        queue.append(song)
        Haptics.light()
    }

    func playCurrent() {
        guard let song = currentSong else { return }
        loopStart = nil
        loopEnd = nil

        do {
            let file = try AVAudioFile(forReading: song.fileURL)
            self.audioFile = file
            self.sampleRate = file.processingFormat.sampleRate
            self.totalFrames = file.length
            self.duration = max(1.0, Double(totalFrames) / sampleRate)
            self.seekFrameOffset = 0
            self.progress = 0.0

            engine.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitchNode)
            engine.disconnectNodeOutput(eqNode)

            engine.connect(playerNode, to: timePitchNode, format: file.processingFormat)
            engine.connect(timePitchNode, to: eqNode, format: file.processingFormat)
            engine.connect(eqNode, to: engine.mainMixerNode, format: file.processingFormat)

            try engine.start()
            scheduleFromFrame(0, autoPlay: true)

            incrementPlayStat(for: song)
            if let img = song.artworkImage {
                withAnimation(.easeInOut(duration: 0.6)) {
                    dominantAccent = img.dominantColor()
                }
            } else {
                withAnimation(.easeInOut(duration: 0.6)) {
                    dominantAccent = .orange
                }
            }

            syncStateToHomeWidget(song: song)
            updateNowPlayingInfo()
        } catch {
            print("Failed to load audio file: \(error)")
        }
    }

    private func scheduleFromFrame(_ startFrame: AVAudioFramePosition, autoPlay: Bool) {
        guard let file = audioFile else { return }
        scheduleGeneration += 1
        let currentGen = scheduleGeneration

        playerNode.stop()
        let clampedStart = max(0, min(startFrame, totalFrames))
        let framesToPlay = AVAudioFrameCount(max(0, totalFrames - clampedStart))
        seekFrameOffset = clampedStart

        guard framesToPlay > 0 else {
            handleTrackFinished()
            return
        }

        playerNode.scheduleSegment(
            file,
            startingFrame: clampedStart,
            frameCount: framesToPlay,
            at: nil
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, self.scheduleGeneration == currentGen else { return }
                self.handleTrackFinished()
            }
        }

        if autoPlay {
            if !engine.isRunning { try? engine.start() }
            playerNode.play()
            isPlaying = true
        }
    }

    private func handleTrackFinished() {
        guard isPlaying else { return }
        if repeatMode == .one {
            seek(to: 0)
            resume()
        } else if currentIndex + 1 < queue.count {
            currentIndex += 1
            playCurrent()
        } else if repeatMode == .all && !queue.isEmpty {
            currentIndex = 0
            playCurrent()
        } else {
            isPlaying = false
            seek(to: 0)
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
        if let song = currentSong { syncStateToHomeWidget(song: song) }
        Haptics.light()
    }

    func resume() {
        guard audioFile != nil else {
            if !queue.isEmpty { playCurrent() }
            return
        }
        if !engine.isRunning { try? engine.start() }
        playerNode.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
        spectrumBars = Array(repeating: 0.08, count: 16)
        updateNowPlayingInfo()
    }

    func nextTrack() {
        guard !queue.isEmpty else { return }
        Haptics.light()
        if currentIndex + 1 < queue.count {
            currentIndex += 1
        } else {
            currentIndex = 0
        }
        playCurrent()
    }

    func previousTrack() {
        guard !queue.isEmpty else { return }
        Haptics.light()
        if progress > 3.0 {
            seek(to: 0)
        } else if currentIndex - 1 >= 0 {
            currentIndex -= 1
            playCurrent()
        } else {
            currentIndex = queue.count - 1
            playCurrent()
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        let targetFrame = AVAudioFramePosition(clamped * sampleRate)
        progress = clamped
        scheduleFromFrame(targetFrame, autoPlay: isPlaying)
        updateNowPlayingInfo()
    }

    private func startProgressTimer() {
        displayLinkTimer?.invalidate()
        displayLinkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isPlaying else { return }
                if let nodeTime = self.playerNode.lastRenderTime,
                   let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime) {
                    let currentFrame = self.seekFrameOffset + playerTime.sampleTime
                    let secs = Double(currentFrame) / max(1.0, self.sampleRate)
                    self.progress = min(self.duration, max(0, secs))

                    if let start = self.loopStart, let end = self.loopEnd, self.progress >= end {
                        self.seek(to: start)
                    }
                }
            }
        }
    }

    // MARK: - One-Tap Cloud Lyrics Fetcher
    func fetchCloudLyrics(for song: Song) async -> String? {
        isFetchingLyrics = true
        defer { isFetchingLyrics = false }

        guard let fetched = await CloudLyricsFetcher.fetchLyrics(title: song.title, artist: song.artist) else {
            return nil
        }

        updateSongMetadata(
            originalSong: song,
            newTitle: song.title,
            newArtist: song.artist,
            newAlbum: song.album,
            newEra: song.era,
            newTrackNumber: song.trackNumber,
            newBPM: song.bpm,
            newKey: song.musicalKey,
            newNotes: song.notes,
            newArtworkData: song.artworkData,
            newRawLyrics: fetched
        )
        return fetched
    }

    // MARK: - Home Screen Widget Sync
    private func syncStateToHomeWidget(song: Song) {
        let defaults = UserDefaults(suiteName: "group.com.custom.gajplayer") ?? .standard
        defaults.set(song.title, forKey: "widget_title")
        defaults.set(song.artist, forKey: "widget_artist")
        defaults.set(song.album, forKey: "widget_album")
        defaults.set(song.era, forKey: "widget_era")
        defaults.set(isPlaying, forKey: "widget_isPlaying")
        if let art = song.artworkImage, let thumb = art.jpegData(compressionQuality: 0.4) {
            defaults.set(thumb, forKey: "widget_art")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Sleep Timer
    func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        guard let mins = minutes else {
            sleepTimerRemaining = nil
            return
        }
        sleepTimerRemaining = mins * 60
        sleepTimerTask = Task {
            while let rem = sleepTimerRemaining, rem > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                sleepTimerRemaining = rem - 1
                if sleepTimerRemaining == 0 {
                    pause()
                    sleepTimerRemaining = nil
                }
            }
        }
    }

    // MARK: - Lock Screen Controls
    func setupRemoteTransportControls() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        cc.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.nextTrack() }; return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previousTrack() }; return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let pos = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: pos.positionTime) }
            return .success
        }
    }

    func updateNowPlayingInfo() {
        guard let song = currentSong else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0
        ]
        if let image = song.artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Metadata, Bookmarks, Favorites & Stats
    private func incrementPlayStat(for song: Song) {
        if let idx = library.firstIndex(where: { $0.fileName == song.fileName }) {
            library[idx].playCount += 1
            library[idx].lastPlayed = Date()
            if let qIdx = queue.firstIndex(where: { $0.fileName == song.fileName }) {
                queue[qIdx] = library[idx]
            }
            savePersistedState()
        }
    }

    func toggleFavorite(_ song: Song) {
        guard let idx = library.firstIndex(where: { $0.fileName == song.fileName }) else { return }
        library[idx].isFavorite.toggle()
        if let qIdx = queue.firstIndex(where: { $0.fileName == song.fileName }) {
            queue[qIdx] = library[idx]
        }
        Haptics.light()
        savePersistedState()
    }

    func addBookmark(to song: Song, label: String, at time: Double) {
        guard let idx = library.firstIndex(where: { $0.fileName == song.fileName }) else { return }
        let bm = TrackBookmark(time: time, label: label.isEmpty ? "Chop @ \(Self.formatClock(time))" : label)
        library[idx].bookmarks.append(bm)
        library[idx].bookmarks.sort { $0.time < $1.time }
        if let qIdx = queue.firstIndex(where: { $0.fileName == song.fileName }) {
            queue[qIdx] = library[idx]
        }
        Haptics.success()
        savePersistedState()
    }

    func updateSongMetadata(
        originalSong: Song,
        newTitle: String,
        newArtist: String,
        newAlbum: String,
        newEra: String,
        newTrackNumber: Int,
        newBPM: Int?,
        newKey: String?,
        newNotes: String?,
        newArtworkData: Data?,
        newRawLyrics: String?
    ) {
        let cleanedLyrics = (newRawLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true) ? nil : newRawLyrics
        let parsedSynced = Self.parseLRC(cleanedLyrics)

        let updatedSong = Song(
            fileName: originalSong.fileName,
            title: newTitle.trimmingCharacters(in: .whitespaces).isEmpty ? originalSong.title : newTitle,
            artist: newArtist.trimmingCharacters(in: .whitespaces).isEmpty ? "Ye" : newArtist,
            album: newAlbum.trimmingCharacters(in: .whitespaces).isEmpty ? "Good Ass Job" : newAlbum,
            era: newEra.trimmingCharacters(in: .whitespaces).isEmpty ? "GAJ (2008–2010)" : newEra,
            trackNumber: newTrackNumber,
            bpm: newBPM,
            musicalKey: newKey,
            notes: newNotes,
            isFavorite: originalSong.isFavorite,
            playCount: originalSong.playCount,
            lastPlayed: originalSong.lastPlayed,
            bookmarks: originalSong.bookmarks,
            rawLyrics: cleanedLyrics,
            syncedLyrics: parsedSynced,
            artworkData: newArtworkData
        )

        if let libIdx = library.firstIndex(where: { $0.fileName == originalSong.fileName }) {
            library[libIdx] = updatedSong
        }
        if let qIdx = queue.firstIndex(where: { $0.fileName == originalSong.fileName }) {
            queue[qIdx] = updatedSong
        }

        if currentSong?.fileName == updatedSong.fileName, let img = updatedSong.artworkImage {
            dominantAccent = img.dominantColor()
        }

        sortLibrary()
        savePersistedState()
        updateNowPlayingInfo()
        Haptics.success()
    }

    func updateAlbumBatch(
        originalAlbumTitle: String,
        newAlbumTitle: String,
        newArtist: String,
        newEra: String,
        newArtworkData: Data?,
        overwriteArtwork: Bool
    ) {
        let cleanTitle = newAlbumTitle.trimmingCharacters(in: .whitespaces)
        let cleanArtist = newArtist.trimmingCharacters(in: .whitespaces)
        let cleanEra = newEra.trimmingCharacters(in: .whitespaces)

        for idx in library.indices where library[idx].album == originalAlbumTitle {
            if !cleanTitle.isEmpty { library[idx].album = cleanTitle }
            if !cleanArtist.isEmpty { library[idx].artist = cleanArtist }
            if !cleanEra.isEmpty { library[idx].era = cleanEra }
            if overwriteArtwork { library[idx].artworkData = newArtworkData }

            if let qIdx = queue.firstIndex(where: { $0.fileName == library[idx].fileName }) {
                queue[qIdx] = library[idx]
            }
        }

        sortLibrary()
        savePersistedState()
        updateNowPlayingInfo()
        Haptics.success()
    }

    private func sortLibrary() {
        library.sort {
            if $0.album == $1.album {
                if $0.trackNumber == $1.trackNumber { return $0.title < $1.title }
                return $0.trackNumber < $1.trackNumber
            }
            return $0.title < $1.title
        }
    }

    // MARK: - Auto Watchfolder Scanner & File Importer
    func scanDocumentsDirectoryForNewFiles() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let musicDir = docs.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)

        if let rootItems = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for item in rootItems where item.lastPathComponent != "Music" && item.lastPathComponent != "library_state_v2.json" {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        await importFiles(urls: [item])
                    } else {
                        let dest = musicDir.appendingPathComponent(item.lastPathComponent)
                        try? FileManager.default.moveItem(at: item, to: dest)
                    }
                }
            }
        }

        await importFiles(urls: [musicDir])
    }

    func importFiles(urls: [URL]) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let musicDir = docs.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)

        var allDiscoveredURLs: [URL] = []

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let fileURL as URL in enumerator {
                        allDiscoveredURLs.append(fileURL)
                    }
                }
            } else {
                allDiscoveredURLs.append(url)
            }
        }

        let audioExts = ["mp3", "m4a", "flac", "wav", "aac", "alac", "aiff"]
        let lrcFiles = Dictionary(grouping: allDiscoveredURLs.filter { $0.pathExtension.lowercased() == "lrc" }) {
            $0.deletingPathExtension().lastPathComponent
        }

        for fileURL in allDiscoveredURLs where audioExts.contains(fileURL.pathExtension.lowercased()) {
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

            let destURL = musicDir.appendingPathComponent(fileURL.lastPathComponent)
            if fileURL.standardizedFileURL != destURL.standardizedFileURL && !FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.copyItem(at: fileURL, to: destURL)
            }

            let baseName = fileURL.deletingPathExtension().lastPathComponent
            var lrcString: String? = nil
            if let matchingLRC = lrcFiles[baseName]?.first {
                let lrcScoped = matchingLRC.startAccessingSecurityScopedResource()
                lrcString = try? String(contentsOf: matchingLRC, encoding: .utf8)
                if lrcScoped { matchingLRC.stopAccessingSecurityScopedResource() }
            }

            if let existingIdx = library.firstIndex(where: { $0.fileName == destURL.lastPathComponent }) {
                if let lrc = lrcString, library[existingIdx].rawLyrics == nil {
                    library[existingIdx].rawLyrics = lrc
                    library[existingIdx].syncedLyrics = Self.parseLRC(lrc)
                }
            } else if let parsedSong = await parseMetadata(from: destURL, externalLRC: lrcString) {
                library.append(parsedSong)
            }
        }

        sortLibrary()
        savePersistedState()
    }

    private func parseMetadata(from url: URL, externalLRC: String?) async -> Song? {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Ye"
        var album = "Good Ass Job"
        var trackNum = 99
        var artData: Data? = nil
        var embeddedLyrics: String? = try? await asset.load(.lyrics)

        if let common = try? await asset.load(.commonMetadata) {
            for item in common {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let val = try? await item.load(.stringValue), !val.isEmpty { title = val }
                case .commonKeyArtist:
                    if let val = try? await item.load(.stringValue), !val.isEmpty { artist = val }
                case .commonKeyAlbumName:
                    if let val = try? await item.load(.stringValue), !val.isEmpty { album = val }
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) {
                        if let img = UIImage(data: data), let compressed = img.jpegData(compressionQuality: 0.78) {
                            artData = compressed
                        } else {
                            artData = data
                        }
                    }
                default: break
                }
            }
        }

        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let items = try? await asset.loadMetadata(for: format) {
                    for item in items {
                        if item.identifier == .id3MetadataTrackNumber || item.identifier == .iTunesMetadataTrackNumber {
                            if let str = try? await item.load(.stringValue) {
                                let clean = str.components(separatedBy: "/").first ?? str
                                if let num = Int(clean) { trackNum = num }
                            } else if let num = try? await item.load(.numberValue) {
                                trackNum = num.intValue
                            }
                        }
                        if embeddedLyrics == nil, item.identifier == .id3MetadataUnsynchronizedLyric {
                            embeddedLyrics = try? await item.load(.stringValue)
                        }
                    }
                }
            }
        }

        let finalRawLyrics = externalLRC ?? embeddedLyrics
        let synced = Self.parseLRC(finalRawLyrics)

        return Song(
            fileName: url.lastPathComponent,
            title: title,
            artist: artist,
            album: album,
            era: "GAJ (2008–2010)",
            trackNumber: trackNum,
            bpm: nil,
            musicalKey: nil,
            notes: nil,
            isFavorite: false,
            playCount: 0,
            lastPlayed: nil,
            bookmarks: [],
            rawLyrics: finalRawLyrics,
            syncedLyrics: synced,
            artworkData: artData
        )
    }

    static func parseLRC(_ text: String?) -> [LyricLine] {
        guard let text = text else { return [] }
        var result: [LyricLine] = []
        let pattern = #"\[(\d{2}):(\d{2}(?:\.\d{1,3})?)\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for line in text.components(separatedBy: .newlines) {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, range: nsRange),
               let minRange = Range(match.range(at: 1), in: line),
               let secRange = Range(match.range(at: 2), in: line),
               let txtRange = Range(match.range(at: 3), in: line) {
                let mins = Double(line[minRange]) ?? 0
                let secs = Double(line[secRange]) ?? 0
                let lyricText = String(line[txtRange]).trimmingCharacters(in: .whitespaces)
                if !lyricText.isEmpty {
                    result.append(LyricLine(time: mins * 60 + secs, text: lyricText))
                }
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    static func formatClock(_ secs: Double) -> String {
        guard secs.isFinite && secs >= 0 else { return "0:00" }
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Playlists & Persistence
    func createPlaylist(name: String, subtitle: String = "Custom Comp") {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        playlists.append(Playlist(name: name, subtitle: subtitle, songFileNames: []))
        savePersistedState()
    }

    func toggleSong(_ song: Song, in playlist: Playlist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        if playlists[idx].songFileNames.contains(song.fileName) {
            playlists[idx].songFileNames.removeAll { $0 == song.fileName }
        } else {
            playlists[idx].songFileNames.append(song.fileName)
        }
        savePersistedState()
    }

    func deleteSong(_ song: Song) {
        try? FileManager.default.removeItem(at: song.fileURL)
        library.removeAll { $0.id == song.id }
        queue.removeAll { $0.id == song.id }
        savePersistedState()
    }

    private var stateFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library_state_v2.json")
    }

    struct PersistedState: Codable {
        let library: [Song]
        let playlists: [Playlist]
    }

    func savePersistedState() {
        let state = PersistedState(library: library, playlists: playlists)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFileURL)
        }
    }

    func loadPersistedState() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        self.library = state.library.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        self.playlists = state.playlists
    }
}

// MARK: - App Entry
@main
struct GAJPlayerApp: App {
    @StateObject private var manager = MusicPlayerManager()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(manager)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Root Tab View & Floating Mini-Player
struct MainTabView: View {
    @EnvironmentObject var manager: MusicPlayerManager
    @State private var showingImporter = false
    @State private var showingNowPlaying = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                TracksTabView(showingImporter: $showingImporter)
                    .tabItem { Label("Vault", systemImage: "opticaldisc.fill") }

                AlbumsTabView()
                    .tabItem { Label("Albums", systemImage: "square.stack.3d.down.right.fill") }

                PlaylistsTabView()
                    .tabItem { Label("Comps", systemImage: "music.note.list") }

                VaultStatsTabView()
                    .tabItem { Label("Studio Stats", systemImage: "waveform.path.ecg") }
            }
            .tint(manager.dominantAccent)

            if let current = manager.currentSong {
                MiniPlayerBar(song: current, showingNowPlaying: $showingNowPlaying)
                    .padding(.bottom, 52)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio, .folder, UTType(filenameExtension: "lrc") ?? .plainText],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await manager.importFiles(urls: urls) }
            }
        }
        .fullScreenCover(isPresented: $showingNowPlaying) {
            NowPlayingSheet()
                .environmentObject(manager)
        }
    }
}

// MARK: - Tab 1: Vault Tracks List
struct TracksTabView: View {
    @EnvironmentObject var manager: MusicPlayerManager
    @Binding var showingImporter: Bool
    @State private var searchText = ""
    @State private var filterMode: FilterMode = .all
    @State private var songToEdit: Song?

    enum FilterMode: String, CaseIterable {
        case all = "All Tracks"
        case favorites = "Grails ★"
        case withLyrics = "Synced Lyrics"
    }

    var filteredSongs: [Song] {
        var base = manager.library
        if filterMode == .favorites { base = base.filter { $0.isFavorite } }
        if filterMode == .withLyrics { base = base.filter { $0.rawLyrics != nil } }

        if searchText.isEmpty { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText) ||
            $0.album.localizedCaseInsensitiveContains(searchText) ||
            $0.era.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if manager.library.isEmpty {
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(manager.dominantAccent.opacity(0.15))
                                .frame(width: 130, height: 130)
                            Image(systemName: "opticaldisc.fill")
                                .font(.system(size: 72))
                                .foregroundStyle(manager.dominantAccent.gradient)
                        }
                        Text("Good Ass Job Vault")
                            .font(.title2.bold())
                        Text("Import your tagged GAJ folder from the iOS Files app, or drop audio & .lrc files straight into GAJ Vault via iTunes USB File Sharing.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import Folder or Audio Files", systemImage: "folder.fill.badge.plus")
                                .font(.headline)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 14)
                                .background(manager.dominantAccent)
                                .foregroundColor(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                } else {
                    List {
                        Section {
                            VStack(spacing: 12) {
                                Picker("Filter", selection: $filterMode) {
                                    ForEach(FilterMode.allCases, id: \.self) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                HStack(spacing: 12) {
                                    Button {
                                        if let first = filteredSongs.first {
                                            manager.isShuffle = false
                                            manager.startQueue(filteredSongs, startingAt: first)
                                        }
                                    } label: {
                                        Label("Play All (\(filteredSongs.count))", systemImage: "play.fill")
                                            .font(.subheadline.bold())
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(manager.dominantAccent)
                                            .foregroundColor(.black)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        if let random = filteredSongs.randomElement() {
                                            manager.isShuffle = true
                                            manager.startQueue(filteredSongs, startingAt: random)
                                        }
                                    } label: {
                                        Label("Shuffle Vault", systemImage: "shuffle")
                                            .font(.subheadline.bold())
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(Color.white.opacity(0.1))
                                            .foregroundColor(.white)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(filteredSongs) { song in
                            SongRow(song: song) {
                                manager.startQueue(filteredSongs, startingAt: song)
                            }
                            .contextMenu {
                                Button {
                                    manager.playNextInQueue(song)
                                } label: {
                                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                Button {
                                    manager.addToEndOfQueue(song)
                                } label: {
                                    Label("Add to Queue", systemImage: "text.append")
                                }
                                Button {
                                    Task { _ = await manager.fetchCloudLyrics(for: song) }
                                } label: {
                                    Label("Auto-Fetch Synced Lyrics", systemImage: "sparkles")
                                }
                                Button {
                                    manager.toggleFavorite(song)
                                } label: {
                                    Label(song.isFavorite ? "Unmark Grail" : "Mark as Grail ★", systemImage: song.isFavorite ? "star.slash" : "star.fill")
                                }
                                Divider()
                                Button {
                                    songToEdit = song
                                } label: {
                                    Label("Studio Tag & Lyrics Editor", systemImage: "slider.horizontal.3")
                                }
                                Button(role: .destructive) {
                                    manager.deleteSong(song)
                                } label: {
                                    Label("Delete from Vault", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    manager.playNextInQueue(song)
                                } label: {
                                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                .tint(manager.dominantAccent)

                                Button {
                                    songToEdit = song
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    manager.deleteSong(song)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    manager.toggleFavorite(song)
                                } label: {
                                    Label("Grail", systemImage: "star.fill")
                                }
                                .tint(.yellow)
                            }
                        }
                        Color.clear.frame(height: 90).listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await manager.scanDocumentsDirectoryForNewFiles()
                    }
                    .searchable(text: $searchText, prompt: "Search tracks, eras, albums...")
                }
            }
            .navigationTitle("GAJ Vault")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await manager.scanDocumentsDirectoryForNewFiles() }
                    } label: {
                        Image(systemName: "arrow.clockwise.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImporter = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(item: $songToEdit) { song in
                SongMetadataEditorSheet(song: song)
                    .environmentObject(manager)
            }
        }
    }
}

// MARK: - Tab 2: Era & Albums Grid
struct AlbumsTabView: View {
    @EnvironmentObject var manager: MusicPlayerManager
    let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(manager.albums) { album in
                        NavigationLink(value: album.title) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(image: album.artworkImage, size: 165, cornerRadius: 14)
                                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                                Text(album.title)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                HStack {
                                    Text(album.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(album.era)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(manager.dominantAccent.opacity(0.2))
                                        .foregroundColor(manager.dominantAccent)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding()
                .padding(.bottom, 95)
            }
            .navigationTitle("Eras & Albums")
            .navigationDestination(for: String.self) { albumTitle in
                AlbumDetailView(albumTitle: albumTitle)
            }
        }
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject var manager: MusicPlayerManager
    let albumTitle: String
    @State private var songToEdit: Song?
    @State private var showingBatchEditor = false

    var currentAlbum: AlbumGroup? {
        manager.albums.first { $0.title == albumTitle } ?? manager.albums.first
    }

    var body: some View {
        Group {
            if let album = currentAlbum {
                List {
                    VStack(spacing: 14) {
                        ArtworkView(image: album.artworkImage, size: 230, cornerRadius: 18)
                            .shadow(color: .black.opacity(0.55), radius: 16, y: 8)

                        Text(album.era.uppercased())
                            .font(.caption.bold())
                            .tracking(1.4)
                            .foregroundColor(manager.dominantAccent)

                        Text(album.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        Text("\(album.artist) • \(album.songs.count) tracks")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack(spacing: 12) {
                            Button {
                                if let first = album.songs.first {
                                    manager.isShuffle = false
                                    manager.startQueue(album.songs, startingAt: first)
                                }
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(manager.dominantAccent)
                                    .foregroundColor(.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)

                            Button {
                                if let rand = album.songs.randomElement() {
                                    manager.isShuffle = true
                                    manager.startQueue(album.songs, startingAt: rand)
                                }
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.white.opacity(0.12))
                                    .foregroundColor(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                    .listRowSeparator(.hidden)

                    ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
                        HStack(spacing: 14) {
                            Text("\(song.trackNumber < 99 ? song.trackNumber : index + 1)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(manager.currentSong?.id == song.id ? manager.dominantAccent : .secondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(song.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(manager.currentSong?.id == song.id ? manager.dominantAccent : .primary)
                                        .lineLimit(1)
                                    if song.isFavorite {
                                        Image(systemName: "star.fill")
                                            .font(.caption2)
                                            .foregroundColor(.yellow)
                                    }
                                }
                                HStack(spacing: 6) {
                                    Text(song.artist)
                                    if let bpm = song.bpm { Text("• \(bpm) BPM") }
                                    if let key = song.musicalKey, !key.isEmpty { Text("• \(key)") }
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            if !song.syncedLyrics.isEmpty {
                                Image(systemName: "waveform.badge.mic")
                                    .font(.caption)
                                    .foregroundColor(manager.dominantAccent)
                            } else if song.rawLyrics != nil {
                                Image(systemName: "quote.bubble.fill")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            manager.startQueue(album.songs, startingAt: song)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                songToEdit = song
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(manager.dominantAccent)
                        }
                    }
                    Color.clear.frame(height: 90).listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingBatchEditor = true
                        } label: {
                            Label("Batch Edit Album", systemImage: "square.and.pencil")
                        }
                    }
                }
                .sheet(isPresented: $showingBatchEditor) {
                    AlbumBatchEditorSheet(album: album)
                        .environmentObject(manager)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $songToEdit) { song in
            SongMetadataEditorSheet(song: song)
                .environmentObject(manager)
        }
    }
}

// MARK: - Tab 3: Custom Comps & Playlists
struct PlaylistsTabView: View {
    @EnvironmentObject var manager: MusicPlayerManager
    @State private var showingNewAlert = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistSubtitle = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(manager.playlists) { playlist in
                    NavigationLink(value: playlist) {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(manager.dominantAccent.opacity(0.2))
                                .frame(width: 56, height: 56)
                                .overlay(Image(systemName: "opticaldisc").font(.title2).foregroundColor(manager.dominantAccent))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name).font(.headline)
                                Text("\(playlist.subtitle) • \(playlist.songFileNames.count) tracks")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Color.clear.frame(height: 90).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .navigationTitle("Custom Comps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNewAlert = true } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .alert("New Custom Comp", isPresented: $showingNewAlert) {
                TextField("Comp Title (e.g. GAJ 2009 Tracklist)", text: $newPlaylistName)
                TextField("Era / Subtitle", text: $newPlaylistSubtitle)
                Button("Create") {
                    manager.createPlaylist(
                        name: newPlaylistName,
                        subtitle: newPlaylistSubtitle.isEmpty ? "Custom Comp" : newPlaylistSubtitle
                    )
                    newPlaylistName = ""
                    newPlaylistSubtitle = ""
                }
                Button("Cancel", role: .cancel) {}
            }
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlistID: playlist.id)
            }
        }
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject var manager: MusicPlayerManager
    let playlistID: UUID
    @State private var showingSongPicker = false

    var currentPlaylist: Playlist? {
        manager.playlists.first { $0.id == playlistID }
    }

    var playlistSongs: [Song] {
        guard let pl = currentPlaylist else { return [] }
        return pl.songFileNames.compactMap { fileName in
            manager.library.first { $0.fileName == fileName }
        }
    }

    var body: some View {
        List {
            ForEach(playlistSongs) { song in
                SongRow(song: song) {
                    manager.startQueue(playlistSongs, startingAt: song)
                }
            }
            Color.clear.frame(height: 90).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle(currentPlaylist?.name ?? "Comp")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add / Remove") { showingSongPicker = true }
            }
        }
        .sheet(isPresented: $showingSongPicker) {
            if let pl = currentPlaylist {
                NavigationStack {
                    List(manager.library) { song in
                        let isAdded = pl.songFileNames.contains(song.fileName)
                        Button {
                            manager.toggleSong(song, in: pl)
                        } label: {
                            HStack {
                                Text(song.title).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: isAdded ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(manager.dominantAccent)
                            }
                        }
                    }
                    .navigationTitle("Manage Comp Tracks")
                }
            }
        }
    }
}

// MARK: - Tab 4: Vault & Listening Analytics
struct VaultStatsTabView: View {
    @EnvironmentObject var manager: MusicPlayerManager

    var totalPlays: Int {
        manager.library.reduce(0) { $0 + $1.playCount }
    }

    var topTracks: [Song] {
        manager.library.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Vault Overview") {
                    HStack {
                        StatCard(title: "Tracks Indexed", value: "\(manager.library.count)", icon: "music.note")
                        StatCard(title: "Total Spins", value: "\(totalPlays)", icon: "flame.fill")
                        StatCard(title: "Grails ★", value: "\(manager.library.filter { $0.isFavorite }.count)", icon: "star.fill")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Most Spun Vault Tracks") {
                    if topTracks.isEmpty {
                        Text("Play some tracks in your vault to rank your rotation.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(topTracks.prefix(15).enumerated()), id: \.element.id) { idx, song in
                            HStack(spacing: 12) {
                                Text("#\(idx + 1)")
                                    .font(.headline.monospacedDigit())
                                    .foregroundColor(manager.dominantAccent)
                                    .frame(width: 30)
                                ArtworkView(image: song.artworkImage, size: 44, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title).font(.subheadline.bold()).lineLimit(1)
                                    Text(song.album).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(song.playCount) plays")
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08))
                                    .clipShape(Capsule())
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                manager.startQueue(topTracks, startingAt: song)
                            }
                        }
                    }
                }
                Color.clear.frame(height: 90).listRowSeparator(.hidden)
            }
            .navigationTitle("Studio Stats")
        }
    }
}

struct StatCard: View {
    @EnvironmentObject var manager: MusicPlayerManager
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(manager.dominantAccent)
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(4)
    }
}

// MARK: - Studio Now Playing Full-Screen View
struct NowPlayingSheet: View {
    @EnvironmentObject var manager: MusicPlayerManager
    @Environment(\.dismiss) var dismiss

    enum CenterDisplayMode {
        case artwork, lyrics, dspStudio, queue
    }

    @State private var displayMode: CenterDisplayMode = .artwork
    @State private var editingCurrentSong: Song?
    @State private var newBookmarkNote: String = ""
    @State private var showingBookmarkAlert: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    manager.dominantAccent.opacity(0.55),
                    Color.black,
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let art = manager.currentSong?.artworkImage {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 75)
                    .overlay(Color.black.opacity(0.62))
                    .ignoresSafeArea()
            }

            VStack(spacing: 14) {
                // Top Bar: Dismiss, Live FFT Visualizer, Edit
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3.bold())
                            .foregroundColor(.white.opacity(0.8))
                            .padding(10)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }

                    Spacer()

                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<16, id: \.self) { idx in
                            Capsule()
                                .fill(manager.dominantAccent)
                                .frame(width: 3.5, height: max(4, CGFloat(manager.spectrumBars[idx]) * 24))
                        }
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Capsule())

                    Spacer()

                    if let current = manager.currentSong {
                        Button {
                            editingCurrentSong = current
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                // 3-Way Physical Deck Style Switcher (Sleeve | CD Player | Side Vinyl)
                if displayMode == .artwork {
                    HStack(spacing: 8) {
                        ForEach(VisualPlayerStyle.allCases) { style in
                            Button {
                                Haptics.light()
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                                    manager.visualStyle = style
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: style.icon)
                                        .font(.caption)
                                    Text(style.rawValue)
                                        .font(.caption.bold())
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(manager.visualStyle == style ? manager.dominantAccent : Color.white.opacity(0.1))
                                .foregroundColor(manager.visualStyle == style ? .black : .white.opacity(0.8))
                                .clipShape(Capsule())
                            }
                        }
                    }
                }

                // Center Interactive Stage
                Group {
                    switch displayMode {
                    case .artwork:
                        ArtworkStageView()
                    case .lyrics:
                        LyricsView(song: manager.currentSong, currentTime: manager.progress) { seekTime in
                            manager.seek(to: seekTime)
                        }
                    case .dspStudio:
                        DSPStudioPanelView()
                    case .queue:
                        QueuePanelView()
                    }
                }
                .frame(maxHeight: .infinity)

                // Track Info, Favorite & Bookmark Chop Button
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(manager.currentSong?.title ?? "Not Playing")
                                .font(.title2.bold())
                                .foregroundColor(.white)
                                .lineLimit(1)
                            if manager.playbackRate != 1.0 || manager.pitchCents != 0 {
                                Text(String(format: "%.2fx", manager.playbackRate))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(manager.dominantAccent)
                                    .foregroundColor(.black)
                                    .clipShape(Capsule())
                            }
                        }
                        Text("\(manager.currentSong?.artist ?? "") — \(manager.currentSong?.album ?? "")")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()

                    if let song = manager.currentSong {
                        Button {
                            showingBookmarkAlert = true
                        } label: {
                            Image(systemName: "bookmark.fill")
                                .font(.title3)
                                .foregroundColor(.white.opacity(0.85))
                                .padding(9)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }

                        Button {
                            manager.toggleFavorite(song)
                        } label: {
                            Image(systemName: song.isFavorite ? "star.fill" : "star")
                                .font(.title3)
                                .foregroundColor(song.isFavorite ? .yellow : .white.opacity(0.85))
                                .padding(9)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 26)

                // Bookmarks Strip
                if let bookmarks = manager.currentSong?.bookmarks, !bookmarks.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(bookmarks) { bm in
                                Button {
                                    manager.seek(to: bm.time)
                                    Haptics.light()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "pin.fill").font(.caption2)
                                        Text("\(bm.label) (\(MusicPlayerManager.formatClock(bm.time)))")
                                            .font(.caption.bold())
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(manager.dominantAccent.opacity(0.25))
                                    .foregroundColor(manager.dominantAccent)
                                    .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 26)
                    }
                }

                // Scrubber + A-B Loop Bar
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { min(manager.progress, manager.duration) },
                            set: { manager.seek(to: $0) }
                        ),
                        in: 0...max(manager.duration, 1.0)
                    )
                    .tint(manager.dominantAccent)

                    HStack {
                        Text(MusicPlayerManager.formatClock(manager.progress))
                        Spacer()
                        Button {
                            if manager.loopStart == nil {
                                manager.loopStart = manager.progress
                                Haptics.light()
                            } else if manager.loopEnd == nil {
                                manager.loopEnd = max(manager.progress, (manager.loopStart ?? 0) + 1.0)
                                Haptics.success()
                            } else {
                                manager.loopStart = nil
                                manager.loopEnd = nil
                                Haptics.light()
                            }
                        } label: {
                            Text(loopBadgeText)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(manager.loopStart != nil ? manager.dominantAccent : Color.white.opacity(0.12))
                                .foregroundColor(manager.loopStart != nil ? .black : .white.opacity(0.75))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Text("-" + MusicPlayerManager.formatClock(max(0, manager.duration - manager.progress)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.65))
                }
                .padding(.horizontal, 26)

                // Primary Transport Controls
                HStack(spacing: 38) {
                    Button {
                        manager.isShuffle.toggle()
                        Haptics.light()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.title3)
                            .foregroundColor(manager.isShuffle ? manager.dominantAccent : .white.opacity(0.5))
                    }

                    Button { manager.previousTrack() } label: {
                        Image(systemName: "backward.fill").font(.title)
                    }

                    Button { manager.togglePlayPause() } label: {
                        Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(manager.dominantAccent)
                            .shadow(color: manager.dominantAccent.opacity(0.5), radius: 12)
                    }

                    Button { manager.nextTrack() } label: {
                        Image(systemName: "forward.fill").font(.title)
                    }

                    Button {
                        switch manager.repeatMode {
                        case .none: manager.repeatMode = .all
                        case .all: manager.repeatMode = .one
                        case .one: manager.repeatMode = .none
                        }
                        Haptics.light()
                    } label: {
                        Image(systemName: manager.repeatMode == .one ? "repeat.1" : "repeat")
                            .font(.title3)
                            .foregroundColor(manager.repeatMode == .none ? .white.opacity(0.5) : manager.dominantAccent)
                    }
                }
                .foregroundColor(.white)

                // Bottom Mode Dock
                HStack(spacing: 28) {
                    ModeDockButton(
                        icon: manager.visualStyle.icon,
                        label: "Deck",
                        isActive: displayMode == .artwork,
                        accent: manager.dominantAccent
                    ) {
                        withAnimation(.spring()) { displayMode = .artwork }
                    }

                    ModeDockButton(
                        icon: "quote.bubble.fill",
                        label: "Lyrics",
                        isActive: displayMode == .lyrics,
                        accent: manager.dominantAccent
                    ) {
                        withAnimation(.spring()) { displayMode = .lyrics }
                    }

                    ModeDockButton(
                        icon: "dial.high.fill",
                        label: "DSP / Chop",
                        isActive: displayMode == .dspStudio,
                        accent: manager.dominantAccent
                    ) {
                        withAnimation(.spring()) { displayMode = .dspStudio }
                    }

                    ModeDockButton(
                        icon: "list.bullet.below.rectangle",
                        label: "Queue",
                        isActive: displayMode == .queue,
                        accent: manager.dominantAccent
                    ) {
                        withAnimation(.spring()) { displayMode = .queue }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        .alert("Bookmark Timestamp", isPresented: $showingBookmarkAlert) {
            TextField("Label (e.g. Beat Switch / Sample Chop)", text: $newBookmarkNote)
            Button("Save Stamp") {
                if let song = manager.currentSong {
                    manager.addBookmark(to: song, label: newBookmarkNote, at: manager.progress)
                }
                newBookmarkNote = ""
            }
            Button("Cancel", role: .cancel) { newBookmarkNote = "" }
        }
        .sheet(item: $editingCurrentSong) { song in
            SongMetadataEditorSheet(song: song)
                .environmentObject(manager)
        }
    }

    private var loopBadgeText: String {
        if let s = manager.loopStart, let e = manager.loopEnd {
            return "A-B \(MusicPlayerManager.formatClock(s))–\(MusicPlayerManager.formatClock(e))"
        } else if let s = manager.loopStart {
            return "A: \(MusicPlayerManager.formatClock(s)) (Tap for B)"
        } else {
            return "A-B Loop"
        }
    }
}

struct ModeDockButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.headline)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(isActive ? accent : .white.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isActive ? Color.white.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - 3-Mode Physical Media Stage (Sleeve | CD Walkman | Side-Out Vinyl)
struct ArtworkStageView: View {
    @EnvironmentObject var manager: MusicPlayerManager

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let angle = manager.isPlaying ? (time * 52.0 * Double(manager.playbackRate)).truncatingRemainder(dividingBy: 360) : 0

            VStack {
                Spacer()
                switch manager.visualStyle {
                case .coverSleeve:
                    // MODE 1: Classic Floating Album Cover
                    ArtworkView(image: manager.currentSong?.artworkImage, size: 300, cornerRadius: 22)
                        .scaleEffect(manager.isPlaying ? 1.0 : 0.88)
                        .shadow(color: manager.dominantAccent.opacity(manager.isPlaying ? 0.5 : 0.15), radius: 28, y: 14)
                        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: manager.isPlaying)

                case .cdWalkman:
                    // MODE 2: Transparent Portable CD Player Deck with Album Cover in Center
                    ZStack {
                        // Outer Brushed Polycarbonate CD Player Chassis
                        RoundedRectangle(cornerRadius: 38)
                            .fill(
                                LinearGradient(
                                    colors: [Color(white: 0.22), Color(white: 0.09), Color(white: 0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 315, height: 315)
                            .overlay(
                                RoundedRectangle(cornerRadius: 38)
                                    .stroke(
                                        LinearGradient(
                                            colors: [.white.opacity(0.35), .white.opacity(0.05), manager.dominantAccent.opacity(0.4)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 2
                                    )
                            )
                            .shadow(color: .black.opacity(0.75), radius: 24, y: 14)

                        // Corner Chassis Screws
                        ForEach(0..<4, id: \.self) { corner in
                            Circle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 8, height: 8)
                                .offset(
                                    x: corner % 2 == 0 ? -134 : 134,
                                    y: corner < 2 ? -134 : 134
                                )
                        }

                        // Diagonal Optical Laser Sled Channel
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.75))
                            .frame(width: 110, height: 22)
                            .overlay(
                                Circle()
                                    .fill(manager.isPlaying ? Color.red : Color.red.opacity(0.25))
                                    .frame(width: 8, height: 8)
                                    .shadow(color: .red, radius: manager.isPlaying ? 6 : 0)
                                    .offset(x: 24)
                            )
                            .rotationEffect(.degrees(-38))
                            .offset(x: 52, y: 52)

                        // Spinning Optical Compact Disc
                        ZStack {
                            // Silver Reflective Base
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [Color(white: 0.9), Color(white: 0.65), Color(white: 0.85), Color(white: 0.5)],
                                        center: .center,
                                        startRadius: 15,
                                        endRadius: 125
                                    )
                                )
                                .frame(width: 248, height: 248)

                            // Iridescent Rainbow Prismatic Sheen
                            Circle()
                                .fill(
                                    AngularGradient(
                                        gradient: Gradient(colors: [
                                            .clear, .cyan.opacity(0.32), .purple.opacity(0.32),
                                            .pink.opacity(0.25), .clear, .green.opacity(0.28),
                                            .yellow.opacity(0.25), .clear
                                        ]),
                                        center: .center
                                    )
                                )
                                .frame(width: 248, height: 248)

                            // Album Cover Printed on CD Center Label (146pt)
                            ArtworkView(image: manager.currentSong?.artworkImage, size: 148, cornerRadius: 74)
                                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 2))

                            // Clear Polycarbonate Inner Clamping Ring
                            Circle()
                                .fill(Color(white: 0.88).opacity(0.9))
                                .frame(width: 44, height: 44)
                                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1.5))

                            // Motor Spindle Center Hole
                            Circle()
                                .fill(Color(white: 0.12))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
                        }
                        .rotationEffect(.degrees(angle))
                        .shadow(color: .black.opacity(0.55), radius: 10)

                        // Transparent Smoked Acrylic Lid Window Glare
                        Circle()
                            .stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                            .frame(width: 262, height: 262)
                            .overlay(
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [.white.opacity(0.16), .clear, .clear],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )

                        // Top-Left Retro LCD Digital Status Readout
                        HStack(spacing: 6) {
                            Circle()
                                .fill(manager.isPlaying ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text("DISC • \(String(format: "%02d", manager.currentSong?.trackNumber ?? 1)) • \(MusicPlayerManager.formatClock(manager.progress))")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(manager.dominantAccent)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.8))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                        .offset(x: -68, y: -130)
                    }

                case .sideVinyl:
                    // MODE 3: Album Jacket with Half-Out Spinning Vinyl Record to the Side
                    ZStack {
                        // Spinning Grooved 12" Vinyl Disc Sliding Out to the Right
                        ZStack {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [Color(white: 0.16), Color.black, Color(white: 0.11), Color.black],
                                        center: .center,
                                        startRadius: 15,
                                        endRadius: 120
                                    )
                                )
                                .frame(width: 236, height: 236)
                                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1).frame(width: 200, height: 200))
                                .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 1).frame(width: 165, height: 165))
                                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1).frame(width: 130, height: 130))
                                .shadow(color: .black.opacity(0.75), radius: 18, x: 8, y: 10)

                            // Vinyl Sheen Reflection
                            Circle()
                                .fill(
                                    AngularGradient(
                                        colors: [.clear, .white.opacity(0.12), .clear, .white.opacity(0.12), .clear],
                                        center: .center
                                    )
                                )
                                .frame(width: 236, height: 236)

                            // Album Cover on Center Vinyl Record Label
                            ArtworkView(image: manager.currentSong?.artworkImage, size: 86, cornerRadius: 43)
                                .overlay(Circle().stroke(Color.black, lineWidth: 3))

                            Circle()
                                .fill(Color.black)
                                .frame(width: 12, height: 12)
                        }
                        .rotationEffect(.degrees(angle))
                        .offset(x: manager.isPlaying ? 74 : 46)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: manager.isPlaying)

                        // Left-Anchored Cardboard Album Sleeve Jacket
                        ArtworkView(image: manager.currentSong?.artworkImage, size: 242, cornerRadius: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.85), radius: 18, x: 6, y: 8)
                            .offset(x: -44)
                    }
                    .frame(width: 340, height: 265)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Tap deck to cycle through Sleeve -> CD Player -> Side Vinyl
                Haptics.light()
                let all = VisualPlayerStyle.allCases
                if let idx = all.firstIndex(of: manager.visualStyle) {
                    let next = all[(idx + 1) % all.count]
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                        manager.visualStyle = next
                    }
                }
            }
        }
    }
}

// MARK: - Center Stage 2: Real-Time DSP Studio
struct DSPStudioPanelView: View {
    @EnvironmentObject var manager: MusicPlayerManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Real-Time DSP Studio", systemImage: "waveform.path.ecg")
                        .font(.headline)
                        .foregroundColor(manager.dominantAccent)
                    Spacer()
                    Button("Reset All") {
                        manager.resetDSP()
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                }

                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Vinyl / MPC Tape Mode (Link Speed & Pitch)", isOn: $manager.isTapeModeLinked)
                        .font(.subheadline.bold())
                        .tint(manager.dominantAccent)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Playback Speed")
                            Spacer()
                            Text(String(format: "%.2fx", manager.playbackRate))
                                .monospacedDigit()
                                .foregroundColor(manager.dominantAccent)
                        }
                        .font(.caption.bold())
                        Slider(value: $manager.playbackRate, in: 0.5...1.5, step: 0.01)
                            .tint(manager.dominantAccent)
                    }

                    if !manager.isTapeModeLinked {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Pitch Shift (Semitones)")
                                Spacer()
                                Text(String(format: "%+.1f st", manager.pitchCents / 100.0))
                                    .monospacedDigit()
                                    .foregroundColor(manager.dominantAccent)
                            }
                            .font(.caption.bold())
                            Slider(value: $manager.pitchCents, in: -1200...1200, step: 50)
                                .tint(manager.dominantAccent)
                        }
                    }
                }
                .padding()
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 12) {
                    Text("EQ Presets")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(EQPreset.allCases) { preset in
                                Button {
                                    manager.applyPreset(preset)
                                } label: {
                                    Text(preset.rawValue)
                                        .font(.caption.bold())
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(manager.selectedEQPreset == preset ? manager.dominantAccent : Color.white.opacity(0.1))
                                        .foregroundColor(manager.selectedEQPreset == preset ? .black : .white)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    HStack(spacing: 16) {
                        ForEach(0..<5, id: \.self) { bandIdx in
                            VStack(spacing: 6) {
                                Text(String(format: "%+.0fdB", manager.eqGains[bandIdx]))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)

                                Slider(
                                    value: Binding(
                                        get: { manager.eqGains[bandIdx] },
                                        set: { manager.eqGains[bandIdx] = $0 }
                                    ),
                                    in: -12...12
                                )
                                .tint(manager.dominantAccent)

                                Text(manager.eqLabels[bandIdx])
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding()
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Center Stage 3: Live Up Next Queue Manager
struct QueuePanelView: View {
    @EnvironmentObject var manager: MusicPlayerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Up Next in Queue (\(manager.queue.count))")
                    .font(.headline)
                Spacer()
                if let rem = manager.sleepTimerRemaining {
                    Text("Sleep: \(MusicPlayerManager.formatClock(Double(rem)))")
                        .font(.caption.bold())
                        .foregroundColor(manager.dominantAccent)
                } else {
                    Menu("Sleep Timer") {
                        Button("15 Minutes") { manager.setSleepTimer(minutes: 15) }
                        Button("30 Minutes") { manager.setSleepTimer(minutes: 30) }
                        Button("60 Minutes") { manager.setSleepTimer(minutes: 60) }
                        Button("Turn Off") { manager.setSleepTimer(minutes: nil) }
                    }
                    .font(.caption.bold())
                    .foregroundColor(manager.dominantAccent)
                }
            }
            .padding(.horizontal, 24)

            List {
                ForEach(Array(manager.queue.enumerated()), id: \.element.id) { index, song in
                    HStack(spacing: 12) {
                        if index == manager.currentIndex {
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(manager.dominantAccent)
                        } else {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text(song.title)
                                .font(.subheadline.bold())
                                .foregroundColor(index == manager.currentIndex ? manager.dominantAccent : .white)
                                .lineLimit(1)
                            Text(song.artist)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                    .onTapGesture {
                        manager.currentIndex = index
                        manager.playCurrent()
                    }
                }
                .onMove { indices, newOffset in
                    manager.queue.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Center Stage 4: Interactive Synced Lyrics View + Cloud Fetch Button
struct LyricsView: View {
    @EnvironmentObject var manager: MusicPlayerManager
    let song: Song?
    let currentTime: Double
    let onTapLine: (Double) -> Void
    @State private var fetchStatusMessage: String?

    var activeLineID: UUID? {
        guard let synced = song?.syncedLyrics, !synced.isEmpty else { return nil }
        return synced.last(where: { $0.time <= currentTime })?.id ?? synced.first?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let synced = song?.syncedLyrics, !synced.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(synced) { line in
                            let isCurrent = line.id == activeLineID
                            Text(line.text)
                                .font(isCurrent ? .title2.bold() : .title3.weight(.semibold))
                                .foregroundColor(isCurrent ? .white : .white.opacity(0.32))
                                .scaleEffect(isCurrent ? 1.03 : 1.0, anchor: .leading)
                                .blur(radius: isCurrent ? 0 : 0.4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                                .onTapGesture {
                                    Haptics.light()
                                    onTapLine(line.time)
                                }
                                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isCurrent)
                        }
                    }
                    .padding(28)
                    .onChange(of: activeLineID) { newID in
                        if let id = newID {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                } else if let raw = song?.rawLyrics, !raw.isEmpty {
                    Text(raw)
                        .font(.title3.weight(.medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineSpacing(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 44))
                            .foregroundColor(manager.dominantAccent)
                        Text("No Lyrics Linked Yet")
                            .font(.headline)

                        if let song = song {
                            Button {
                                Task {
                                    fetchStatusMessage = nil
                                    let res = await manager.fetchCloudLyrics(for: song)
                                    if res == nil {
                                        fetchStatusMessage = "No match found online—use the Studio Editor in the top-right to paste lyrics."
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if manager.isFetchingLyrics {
                                        ProgressView().tint(.black)
                                    } else {
                                        Image(systemName: "sparkles")
                                    }
                                    Text(manager.isFetchingLyrics ? "Searching LRCLIB & Genius..." : "Auto-Fetch Synced Lyrics")
                                        .font(.subheadline.bold())
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(manager.dominantAccent)
                                .foregroundColor(.black)
                                .clipShape(Capsule())
                            }
                            .disabled(manager.isFetchingLyrics)
                        }

                        if let msg = fetchStatusMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("Pulls synced [mm:ss.xx] LRC or plain lyrics automatically, or tap the top-right Studio Editor to paste & tap-sync your own.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(40)
                }
            }
        }
    }
}

// MARK: - Studio Metadata + Interactive Tap-to-Sync LRC Editor
struct SongMetadataEditorSheet: View {
    @EnvironmentObject var manager: MusicPlayerManager
    @Environment(\.dismiss) var dismiss
    let song: Song

    enum EditorTab: String, CaseIterable {
        case metadata = "Track Tags"
        case rawLyrics = "Lyrics / LRC"
        case tapSync = "Live Tap Sync"
    }

    @State private var selectedTab: EditorTab = .metadata
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var era: String
    @State private var trackNumberString: String
    @State private var bpmString: String
    @State private var musicalKey: String
    @State private var notes: String
    @State private var rawLyrics: String
    @State private var artworkData: Data?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var tapSyncIndex: Int = 0
    @State private var isFetchingInEditor = false

    init(song: Song) {
        self.song = song
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
        _album = State(initialValue: song.album)
        _era = State(initialValue: song.era)
        _trackNumberString = State(initialValue: song.trackNumber < 99 ? "\(song.trackNumber)" : "1")
        _bpmString = State(initialValue: song.bpm != nil ? "\(song.bpm!)" : "")
        _musicalKey = State(initialValue: song.musicalKey ?? "")
        _notes = State(initialValue: song.notes ?? "")
        _rawLyrics = State(initialValue: song.rawLyrics ?? "")
        _artworkData = State(initialValue: song.artworkData)
    }

    var previewImage: UIImage? {
        guard let data = artworkData else { return nil }
        return UIImage(data: data)
    }

    var plainLyricLines: [String] {
        rawLyrics
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"\[\d{2}:\d{2}(?:\.\d{1,3})?\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $selectedTab) {
                    ForEach(EditorTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == .metadata {
                    Form {
                        Section("Cover Artwork") {
                            HStack(spacing: 16) {
                                ArtworkView(image: previewImage, size: 86, cornerRadius: 12)
                                VStack(alignment: .leading, spacing: 10) {
                                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                        Label("Choose Cover from Photos", systemImage: "photo.on.rectangle")
                                            .font(.subheadline.bold())
                                            .foregroundColor(manager.dominantAccent)
                                    }
                                    if artworkData != nil {
                                        Button(role: .destructive) {
                                            artworkData = nil
                                        } label: {
                                            Text("Remove Custom Cover")
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        Section("Core ID3 Metadata") {
                            LabeledContent("Title") {
                                TextField("Song Title", text: $title).multilineTextAlignment(.trailing)
                            }
                            LabeledContent("Artist") {
                                TextField("Artist", text: $artist).multilineTextAlignment(.trailing)
                            }
                            LabeledContent("Album") {
                                TextField("Album", text: $album).multilineTextAlignment(.trailing)
                            }
                            LabeledContent("Era") {
                                TextField("e.g. GAJ (2009 Hawaii)", text: $era).multilineTextAlignment(.trailing)
                            }
                            LabeledContent("Track #") {
                                TextField("1", text: $trackNumberString)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                            }
                        }

                        Section("Producer / Vault Notes") {
                            LabeledContent("BPM") {
                                TextField("e.g. 92", text: $bpmString)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                            }
                            LabeledContent("Key") {
                                TextField("e.g. F# Minor", text: $musicalKey)
                                    .multilineTextAlignment(.trailing)
                            }
                            TextField("Leak Version / Sample Notes", text: $notes, axis: .vertical)
                                .lineLimit(2...4)
                        }
                    }
                } else if selectedTab == .rawLyrics {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button {
                                Task {
                                    isFetchingInEditor = true
                                    if let fetched = await CloudLyricsFetcher.fetchLyrics(title: title, artist: artist) {
                                        rawLyrics = fetched
                                        Haptics.success()
                                    }
                                    isFetchingInEditor = false
                                }
                            } label: {
                                Label(isFetchingInEditor ? "Searching..." : "Auto-Fetch Lyrics", systemImage: "sparkles")
                                    .font(.caption.bold())
                                    .foregroundColor(manager.dominantAccent)
                            }
                            Spacer()
                            Button {
                                let stamp = formatLRCTimestamp(manager.progress)
                                rawLyrics = "\(stamp) " + rawLyrics
                            } label: {
                                Label("Stamp Time", systemImage: "clock.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(manager.dominantAccent)
                            }
                        }
                        .padding(.horizontal)

                        TextEditor(text: $rawLyrics)
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                            .padding(.bottom)
                    }
                } else {
                    VStack(spacing: 16) {
                        if plainLyricLines.isEmpty {
                            Text("Paste or Auto-Fetch your lyrics in the 'Lyrics / LRC' tab first, then come here to tap along to the beat.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(32)
                        } else {
                            HStack {
                                Button {
                                    if manager.currentSong?.id != song.id {
                                        manager.startQueue([song], startingAt: song)
                                    } else {
                                        manager.togglePlayPause()
                                    }
                                } label: {
                                    Label(manager.isPlaying ? "Pause Track" : "Play Track", systemImage: manager.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.subheadline.bold())
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Color.white.opacity(0.12))
                                        .clipShape(Capsule())
                                }

                                Spacer()

                                Text("Line \(min(tapSyncIndex + 1, plainLyricLines.count)) of \(plainLyricLines.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)

                                Spacer()

                                Button("Restart Sync") {
                                    tapSyncIndex = 0
                                    manager.seek(to: 0)
                                }
                                .font(.caption.bold())
                                .foregroundColor(.orange)
                            }
                            .padding(.horizontal)

                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(plainLyricLines.enumerated()), id: \.offset) { idx, line in
                                        HStack {
                                            Image(systemName: idx < tapSyncIndex ? "checkmark.circle.fill" : (idx == tapSyncIndex ? "arrow.right.circle.fill" : "circle"))
                                                .foregroundColor(idx < tapSyncIndex ? .green : (idx == tapSyncIndex ? manager.dominantAccent : .secondary))
                                            Text(line)
                                                .font(idx == tapSyncIndex ? .headline : .subheadline)
                                                .foregroundColor(idx == tapSyncIndex ? .white : .secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                            }
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal)

                            Button {
                                stampCurrentLineAndAdvance()
                            } label: {
                                HStack {
                                    Image(systemName: "hand.tap.fill")
                                    Text(tapSyncIndex < plainLyricLines.count ? "TAP ON BEAT (\(formatLRCTimestamp(manager.progress)))" : "ALL LINES SYNCED ✓")
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(tapSyncIndex < plainLyricLines.count ? manager.dominantAccent : .green)
                                .foregroundColor(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 12)
                        }
                    }
                }
            }
            .navigationTitle("Studio Track Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let parsedNum = Int(trackNumberString) ?? song.trackNumber
                        let parsedBPM = Int(bpmString)
                        manager.updateSongMetadata(
                            originalSong: song,
                            newTitle: title,
                            newArtist: artist,
                            newAlbum: album,
                            newEra: era,
                            newTrackNumber: parsedNum,
                            newBPM: parsedBPM,
                            newKey: musicalKey.isEmpty ? nil : musicalKey,
                            newNotes: notes.isEmpty ? nil : notes,
                            newArtworkData: artworkData,
                            newRawLyrics: rawLyrics
                        )
                        dismiss()
                    }
                    .bold()
                    .foregroundColor(manager.dominantAccent)
                }
            }
            .onChange(of: selectedPhotoItem) { newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let img = UIImage(data: data),
                       let compressed = img.jpegData(compressionQuality: 0.8) {
                        await MainActor.run {
                            self.artworkData = compressed
                        }
                    }
                }
            }
        }
    }

    private func stampCurrentLineAndAdvance() {
        var lines = rawLyrics
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard tapSyncIndex < lines.count else { return }
        let cleanText = lines[tapSyncIndex]
            .replacingOccurrences(of: #"\[\d{2}:\d{2}(?:\.\d{1,3})?\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        lines[tapSyncIndex] = "\(formatLRCTimestamp(manager.progress)) \(cleanText)"
        rawLyrics = lines.joined(separator: "\n")
        tapSyncIndex += 1
        Haptics.medium()
    }

    private func formatLRCTimestamp(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "[00:00.00]" }
        let mins = Int(seconds) / 60
        let secs = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "[%02d:%05.2f]", mins, secs)
    }
}

// MARK: - Batch Album Editor
struct AlbumBatchEditorSheet: View {
    @EnvironmentObject var manager: MusicPlayerManager
    @Environment(\.dismiss) var dismiss
    let album: AlbumGroup

    @State private var albumTitle: String
    @State private var artist: String
    @State private var era: String
    @State private var artworkData: Data?
    @State private var didChangeArtwork = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    init(album: AlbumGroup) {
        self.album = album
        _albumTitle = State(initialValue: album.title)
        _artist = State(initialValue: album.artist)
        _era = State(initialValue: album.era)
        _artworkData = State(initialValue: album.artworkData)
    }

    var previewImage: UIImage? {
        guard let data = artworkData else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Batch Cover Artwork (Updates all \(album.songs.count) tracks)") {
                    HStack(spacing: 16) {
                        ArtworkView(image: previewImage, size: 86, cornerRadius: 12)
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label("Pick Album Cover from Photos", systemImage: "photo.fill.on.rectangle.fill")
                                .font(.subheadline.bold())
                                .foregroundColor(manager.dominantAccent)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Album & Era Details") {
                    LabeledContent("Album Title") {
                        TextField("Album Title", text: $albumTitle).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Album Artist") {
                        TextField("Artist", text: $artist).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Era Tag") {
                        TextField("Era", text: $era).multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Batch Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save All") {
                        manager.updateAlbumBatch(
                            originalAlbumTitle: album.title,
                            newAlbumTitle: albumTitle,
                            newArtist: artist,
                            newEra: era,
                            newArtworkData: artworkData,
                            overwriteArtwork: didChangeArtwork
                        )
                        dismiss()
                    }
                    .bold()
                    .foregroundColor(manager.dominantAccent)
                }
            }
            .onChange(of: selectedPhotoItem) { newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let img = UIImage(data: data),
                       let compressed = img.jpegData(compressionQuality: 0.8) {
                        await MainActor.run {
                            self.artworkData = compressed
                            self.didChangeArtwork = true
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Reusable Rows & Mini-Player Bar
struct ArtworkView: View {
    let image: UIImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        if let img = image {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(LinearGradient(colors: [.orange.opacity(0.55), .purple.opacity(0.45), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundColor(.white.opacity(0.8))
                )
        }
    }
}

struct SongRow: View {
    @EnvironmentObject var manager: MusicPlayerManager
    let song: Song
    let onTap: () -> Void

    var isCurrent: Bool {
        manager.currentSong?.id == song.id
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: song.artworkImage, size: 52, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(song.title)
                        .font(.body.weight(.semibold))
                        .foregroundColor(isCurrent ? manager.dominantAccent : .primary)
                        .lineLimit(1)
                    if song.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                }
                Text("\(song.artist) • \(song.album)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !song.syncedLyrics.isEmpty {
                Image(systemName: "waveform.badge.mic")
                    .font(.caption)
                    .foregroundColor(manager.dominantAccent)
            } else if song.rawLyrics != nil {
                Image(systemName: "quote.bubble.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

struct MiniPlayerBar: View {
    @EnvironmentObject var manager: MusicPlayerManager
    let song: Song
    @Binding var showingNowPlaying: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ArtworkView(image: song.artworkImage, size: 44, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.subheadline.bold()).lineLimit(1)
                    Text("\(song.artist) • \(song.album)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule()
                            .fill(manager.dominantAccent)
                            .frame(width: 2.5, height: max(3, CGFloat(manager.spectrumBars[i * 3]) * 16))
                    }
                }
                .frame(height: 16)
                .padding(.trailing, 4)

                Button { manager.togglePlayPause() } label: {
                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundColor(.primary)
                }
                Button { manager.nextTrack() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.1))
                    Rectangle()
                        .fill(manager.dominantAccent)
                        .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, manager.progress / max(1.0, manager.duration)))))
                }
            }
            .frame(height: 2.5)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 10)
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
        .onTapGesture {
            Haptics.light()
            showingNowPlaying = true
        }
    }
}
