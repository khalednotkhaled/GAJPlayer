import SwiftUI
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import PhotosUI

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

struct CustomTrackMetadata: Codable {
    var title: String?
    var artist: String?
}

struct Playlist: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var trackFileNames: [String] = []
}

enum VisualMode: String, CaseIterable {
    case sleeve = "Sleeve"
    case cdPlayer = "Walkman CD"
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

// MARK: - Image Auto-Cropper (1:1 Center Square & YouTube Letterbox Remover)
extension UIImage {
    func autoCroppedToSquare() -> UIImage {
        guard let cgImage = self.cgImage else { return self }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        // If 16:9 or 4:3 YouTube thumbnail (wider than tall), strip top/bottom black bars first
        var effectiveHeight = height
        if width > height * 1.25 {
            // Standard YouTube 4:3 oEmbed thumbnails (480x360) have 45px black bars top & bottom
            let aspect = width / height
            if abs(aspect - (4.0 / 3.0)) < 0.08 {
                effectiveHeight = height * 0.75
            }
        }

        let side = min(width, effectiveHeight)
        let originX = (width - side) / 2.0
        let originY = (height - side) / 2.0
        let cropRect = CGRect(x: originX.rounded(), y: originY.rounded(), width: side.rounded(), height: side.rounded())

        guard let croppedCG = cgImage.cropping(to: cropRect) else { return self }
        return UIImage(cgImage: croppedCG, scale: self.scale, orientation: self.imageOrientation)
    }
}

// MARK: - Fast Artwork & Custom Tag Cache
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    private let customMetaKey = "MusiQ_Custom_Metadata_v2"

    func artwork(for fileName: String) -> UIImage? {
        if let cached = cache.object(forKey: fileName as NSString) {
            return cached
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let customCoverURL = docs.appendingPathComponent(fileName + ".cover.jpg")
        if let data = try? Data(contentsOf: customCoverURL), let img = UIImage(data: data) {
            let squared = img.autoCroppedToSquare()
            cache.setObject(squared, forKey: fileName as NSString)
            return squared
        }

        let url = docs.appendingPathComponent(fileName)
        let asset = AVURLAsset(url: url)
        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                if item.commonKey == .commonKeyArtwork,
                   let data = item.value as? Data,
                   let img = UIImage(data: data) {
                    let squared = img.autoCroppedToSquare()
                    cache.setObject(squared, forKey: fileName as NSString)
                    return squared
                }
            }
        }
        return nil
    }

    func setCustomArtwork(_ image: UIImage, for fileName: String) {
        let squared = image.autoCroppedToSquare()
        cache.setObject(squared, forKey: fileName as NSString)
        if let data = squared.jpegData(compressionQuality: 0.9) {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let customCoverURL = docs.appendingPathComponent(fileName + ".cover.jpg")
            try? data.write(to: customCoverURL)
        }
    }

    func customMetadata(for fileName: String) -> CustomTrackMetadata? {
        guard let data = UserDefaults.standard.data(forKey: customMetaKey),
              let dict = try? JSONDecoder().decode([String: CustomTrackMetadata].self, from: data) else {
            return nil
        }
        return dict[fileName]
    }

    func saveCustomMetadata(title: String, artist: String, for fileName: String) {
        var dict: [String: CustomTrackMetadata] = [:]
        if let data = UserDefaults.standard.data(forKey: customMetaKey),
           let decoded = try? JSONDecoder().decode([String: CustomTrackMetadata].self, from: data) {
            dict = decoded
        }
        dict[fileName] = CustomTrackMetadata(title: title, artist: artist)
        if let encoded = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(encoded, forKey: customMetaKey)
        }
    }
}

// MARK: - Lyrics Storage & Auto-Fetcher
final class LyricsManager {
    static let shared = LyricsManager()
    private let storageKey = "MusiQ_Saved_Lyrics_v2"

    func getLyrics(for track: Track) -> String {
        if let dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String],
           let saved = dict[track.fileName], !saved.isEmpty {
            return saved
        }
        let asset = AVURLAsset(url: track.fileURL)
        if let embedded = asset.lyrics, !embedded.isEmpty {
            return embedded
        }
        return ""
    }

    func saveLyrics(_ text: String, for track: Track) {
        var dict = (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        dict[track.fileName] = text
        UserDefaults.standard.set(dict, forKey: storageKey)
    }

    func fetchOnlineLyrics(title: String, artist: String) async -> String? {
        let cleanTitle = title
            .replacingOccurrences(of: "(highest quality)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Official Audio)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Official Video)", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var query = cleanTitle
        if artist != "Unknown Artist" && !artist.isEmpty {
            query = "\(artist) \(cleanTitle)"
        }

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lrclib.net/api/search?q=\(encoded)") else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = results.first {
                if let plain = first["plainLyrics"] as? String, !plain.isEmpty {
                    return plain
                }
                if let synced = first["syncedLyrics"] as? String, !synced.isEmpty {
                    return synced
                }
            }
        } catch {
            print("Lyrics fetch error: \(error)")
        }
        return nil
    }
}

// MARK: - Isolated Playback Time Observer
final class PlaybackProgressObserver: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    var isScrubbing: Bool = false
}

// MARK: - High-Performance Audio, Library & Listening Tracker Engine
final class MusiQEngine: ObservableObject {
    @Published var allTracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var currentQueue: [Track] = []
    @Published var currentIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var isShuffle: Bool = false
    @Published var isRepeat: Bool = false

    @Published var visualMode: VisualMode = .sideVinyl
    @Published var pitchCents: Float = 0
    @Published var playbackRate: Float = 1.0
    @Published var eqPreset: EQPreset = .flat
    @Published var artworkRefreshID: UUID = UUID()
    @Published var playbackErrorMessage: String? = nil

    // Listening Time Tracker (fileName -> total seconds listened)
    @Published var listenedSecondsByFile: [String: Double] = [:]

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
    private var tickCounter: Int = 0

    private let playlistsStorageKey = "MusiQ_User_Playlists_v2"
    private let listeningStatsKey = "MusiQ_Listening_Seconds_v2"

    var currentTrack: Track? {
        guard currentIndex >= 0 && currentIndex < currentQueue.count else { return nil }
        return currentQueue[currentIndex]
    }

    init() {
        configureAudioSession()
        setupEngineGraph()
        loadSavedPlaylists()
        loadListeningStats()
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

    // MARK: - Listening Time Tracker Persistence
    private func loadListeningStats() {
        if let dict = UserDefaults.standard.dictionary(forKey: listeningStatsKey) as? [String: Double] {
            listenedSecondsByFile = dict
        }
    }

    private func saveListeningStats() {
        UserDefaults.standard.set(listenedSecondsByFile, forKey: listeningStatsKey)
    }

    func formattedListenTime(for fileName: String) -> String {
        let secs = Int(listenedSecondsByFile[fileName] ?? 0)
        if secs < 60 {
            return "\(secs)s"
        }
        let mins = Double(secs) / 60.0
        return String(format: "%.1f min", mins)
    }

    var totalMinutesAcrossLibrary: Double {
        listenedSecondsByFile.values.reduce(0, +) / 60.0
    }

    // MARK: - Background File Scanning
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
                // Verify file is actually readable audio and not a corrupted 0-byte or HTML stub
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let fileSize = attrs[.size] as? UInt64, fileSize > 4096 else {
                    continue
                }

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

                if let custom = ArtworkCache.shared.customMetadata(for: fileName) {
                    if let cTitle = custom.title, !cTitle.isEmpty { title = cTitle }
                    if let cArtist = custom.artist, !cArtist.isEmpty { artist = cArtist }
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
                } else {
                    self.currentQueue = self.currentQueue.compactMap { oldTrack in
                        discovered.first(where: { $0.fileName == oldTrack.fileName })
                    }
                }
                self.artworkRefreshID = UUID()
            }
        }
    }

    func deleteTrackFromDisk(_ track: Track) {
        if currentTrack?.fileName == track.fileName {
            playerNode.stop()
            activeAudioFile = nil
            isPlaying = false
        }
        try? FileManager.default.removeItem(at: track.fileURL)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: docs.appendingPathComponent(track.fileName + ".cover.jpg"))
        scanLocalLibrary()
    }

    func updateTrackTags(track: Track, newTitle: String, newArtist: String, newCover: UIImage?) {
        let cleanTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = newArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        ArtworkCache.shared.saveCustomMetadata(
            title: cleanTitle.isEmpty ? track.title : cleanTitle,
            artist: cleanArtist.isEmpty ? track.artist : cleanArtist,
            for: track.fileName
        )
        if let cover = newCover {
            ArtworkCache.shared.setCustomArtwork(cover, for: track.fileName)
        }
        scanLocalLibrary()
        updateNowPlayingInfo()
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

    // MARK: - Playback Controls (Strict Buffer Reset so Previous Track Never Bleeds Over)
    func playTrack(_ track: Track, in queue: [Track]) {
        let validQueue = queue.isEmpty ? allTracks : queue
        currentQueue = validQueue
        if let idx = currentQueue.firstIndex(where: { $0.fileName == track.fileName }) {
            currentIndex = idx
        } else {
            currentQueue.insert(track, at: 0)
            currentIndex = 0
        }
        loadAndScheduleCurrentTrack(startFrame: 0, autoPlay: true)
    }

    private func loadAndScheduleCurrentTrack(startFrame: AVAudioFramePosition, autoPlay: Bool) {
        guard let track = currentTrack else { return }
        scheduleGeneration += 1
        let currentGen = scheduleGeneration

        // Strictly clear previous audio buffer so old song can NEVER play under new title
        playerNode.stop()
        playerNode.reset()
        activeAudioFile = nil
        isPlaying = false
        playbackErrorMessage = nil
        loopStart = nil
        loopEnd = nil
        progress.currentTime = 0

        do {
            let file = try AVAudioFile(forReading: track.fileURL)
            activeAudioFile = file
            sampleRate = file.processingFormat.sampleRate
            totalFrames = file.length
            seekFrameOffset = max(0, min(startFrame, totalFrames))

            let remainingFrames = AVAudioFrameCount(max(0, totalFrames - seekFrameOffset))
            guard remainingFrames > 0 else {
                playbackErrorMessage = "Audio file is empty or corrupted."
                return
            }

            progress.duration = max(1, Double(totalFrames) / sampleRate)
            progress.currentTime = Double(seekFrameOffset) / sampleRate

            // Reconnect graph to match current file channel count cleanly
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: timePitchNode, format: file.processingFormat)

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
            isPlaying = false
            stopProgressTimer()
            playbackErrorMessage = "Corrupted audio format. Delete & re-download this track."
            print("Playback load error: \(error)")
        }
    }

    func togglePlayPause() {
        if activeAudioFile == nil, let current = currentTrack ?? allTracks.first {
            playTrack(current, in: currentQueue.isEmpty ? allTracks : currentQueue)
            return
        }

        if isPlaying {
            playerNode.pause()
            isPlaying = false
            stopProgressTimer()
            saveListeningStats()
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

    // MARK: - Progress & Listening Minutes Timer
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying, self.activeAudioFile != nil else { return }

            if let activeFile = self.currentTrack?.fileName {
                self.listenedSecondsByFile[activeFile, default: 0] += 0.25
                self.tickCounter += 1
                if self.tickCounter % 16 == 0 {
                    self.saveListeningStats()
                }
            }

            guard !self.progress.isScrubbing else { return }
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

    // MARK: - Lock Screen Controls
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

// MARK: - Continuous 60fps Spinning Disc Modifier (Walkman CD & Side Vinyl)
struct ContinuousSpinView<Content: View>: View {
    let isSpinning: Bool
    let rpm: Double
    @ViewBuilder let content: () -> Content

    @State private var accumulatedAngle: Double = 0
    @State private var lastTimestamp: Date? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isSpinning)) { context in
            content()
                .rotationEffect(.degrees(accumulatedAngle))
                .onChange(of: context.date) { newDate in
                    guard isSpinning else {
                        lastTimestamp = nil
                        return
                    }
                    if let last = lastTimestamp {
                        let delta = newDate.timeIntervalSince(last)
                        let degreesPerSecond = (rpm / 60.0) * 360.0
                        accumulatedAngle = (accumulatedAngle + delta * degreesPerSecond)
                            .truncatingRemainder(dividingBy: 360.0)
                    }
                    lastTimestamp = newDate
                }
                .onChange(of: isSpinning) { playing in
                    lastTimestamp = playing ? Date() : nil
                }
        }
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

// MARK: - Root Tab View
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

                ListeningStatsView(engine: engine)
                    .tabItem {
                        Label("Stats", systemImage: "chart.bar.fill")
                    }
                    .tag(3)
            }
            .tint(.purple)

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

// MARK: - Tab 1: Playlists Home View
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
                        Text("Playlists are only created when you make them.\nTap '+' to build a custom playlist.")
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
                                            .fill(LinearGradient(colors: [.purple.opacity(0.7), .indigo.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
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
                        TrackRowView(engine: engine, track: track) {
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
                Group {
                    if engine.allTracks.isEmpty {
                        VStack(spacing: 12) {
                            Text("No songs in library yet.")
                                .foregroundColor(.secondary)
                            Text("Import tracks in the 'Songs' tab first.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
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
    @State private var showFileImporter: Bool = false
    @State private var trackToTag: Track? = nil

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
                    VStack(spacing: 14) {
                        Image(systemName: "waveform.circle")
                            .font(.system(size: 52))
                            .foregroundColor(.purple)
                        Text("No Songs Found")
                            .font(.headline)
                        Text("Import audio files directly from your iPhone Files app, or download tracks from the YouTube DL tab.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)

                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Import from Files App", systemImage: "folder.badge.plus")
                                .font(.headline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.purple)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                        .padding(.top, 6)

                        Button("Rescan Library") {
                            engine.scanLocalLibrary()
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    }
                } else {
                    List {
                        ForEach(filteredTracks) { track in
                            TrackRowView(engine: engine, track: track) {
                                engine.playTrack(track, in: filteredTracks)
                                showFullPlayer = true
                            }
                            .contextMenu {
                                Button {
                                    trackToTag = track
                                } label: {
                                    Label("Edit Tags & Cover Art", systemImage: "tag.fill")
                                }

                                if !engine.playlists.isEmpty {
                                    Menu("Add to Playlist") {
                                        ForEach(engine.playlists) { playlist in
                                            Button(playlist.name) {
                                                engine.addTrack(track, to: playlist.id)
                                            }
                                        }
                                    }
                                }

                                Button(role: .destructive) {
                                    engine.deleteTrackFromDisk(track)
                                } label: {
                                    Label("Delete Song", systemImage: "trash")
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.04))
                        }
                        .onDelete { offsets in
                            offsets.map { filteredTracks[$0] }.forEach(engine.deleteTrackFromDisk)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search any song or artist...")
                    .padding(.bottom, engine.currentTrack != nil ? 70 : 0)
                }
            }
            .navigationTitle("All Songs (\(engine.allTracks.count))")
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
                        showFileImporter = true
                    } label: {
                        Label("Import Files", systemImage: "folder.badge.plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    for url in urls {
                        let gotAccess = url.startAccessingSecurityScopedResource()
                        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
                        let dest = docs.appendingPathComponent(url.lastPathComponent)
                        try? FileManager.default.removeItem(at: dest)
                        try? FileManager.default.copyItem(at: url, to: dest)
                    }
                    engine.scanLocalLibrary()
                case .failure(let err):
                    print("Import failed: \(err)")
                }
            }
            .sheet(item: $trackToTag) { track in
                BuiltInTagEditorSheet(engine: engine, track: track)
            }
        }
    }
}

struct TrackRowView: View {
    @ObservedObject var engine: MusiQEngine
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
                    HStack(spacing: 6) {
                        Text(track.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(engine.formattedListenTime(for: track.fileName))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.purple.opacity(0.9))
                    }
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

// MARK: - Full-Screen Player with Walkman CD, Spinning Vinyl, Lyrics, Tag Editor & Swipe Dismissal
struct FullPlayerDeckView: View {
    @ObservedObject var engine: MusiQEngine
    @Binding var isPresented: Bool

    @State private var activeBottomSheet: BottomPanel? = nil
    @State private var dragOffset: CGSize = .zero

    enum BottomPanel: Identifiable {
        case dsp, lyrics, tagEditor, queue
        var id: Int { hashValue }
    }

    var body: some View {
        GeometryReader { geo in
            let safeWidth = geo.size.width
            let artBoxSize = min(safeWidth - 88, 255)

            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.12, green: 0.09, blue: 0.15), Color(red: 0.04, green: 0.04, blue: 0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 12) {
                    // Top Bar
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
                        if let track = engine.currentTrack {
                            Text(engine.formattedListenTime(for: track.fileName))
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Capsule())
                                .foregroundColor(.purple)
                        }
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

                    Spacer(minLength: 2)

                    // Fixed-Bounds Visualizer Stage (Sleeve, Walkman CD, Side Vinyl)
                    PlayerVisualizerStage(
                        mode: engine.visualMode,
                        track: engine.currentTrack,
                        isPlaying: engine.isPlaying,
                        boxSize: artBoxSize,
                        refreshID: engine.artworkRefreshID
                    )
                    .frame(width: safeWidth - 24, height: artBoxSize + 28)
                    .clipped()

                    if let err = engine.playbackErrorMessage {
                        Text(err)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 2)

                    // Looping Marquee Title + Artist
                    VStack(spacing: 5) {
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
                            .padding(.vertical, 5)
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
                                    .frame(width: 70, height: 70)
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

                    // Bottom Action Bar (DSP, Lyrics, Tag Editor, Queue)
                    HStack(spacing: 28) {
                        Button {
                            activeBottomSheet = .dsp
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "dial.high.fill")
                                Text("DSP / Pitch")
                                    .font(.caption2)
                            }
                            .foregroundColor(.white.opacity(0.85))
                        }

                        Button {
                            activeBottomSheet = .lyrics
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "quote.bubble.fill")
                                Text("Lyrics")
                                    .font(.caption2)
                            }
                            .foregroundColor(.white.opacity(0.85))
                        }

                        Button {
                            activeBottomSheet = .tagEditor
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "tag.fill")
                                Text("Tag Editor")
                                    .font(.caption2)
                            }
                            .foregroundColor(.white.opacity(0.85))
                        }

                        Button {
                            activeBottomSheet = .queue
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "list.bullet")
                                Text("Queue")
                                    .font(.caption2)
                            }
                            .foregroundColor(.white.opacity(0.85))
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                }
            }
            .offset(x: max(0, dragOffset.width), y: max(0, dragOffset.height * 0.3))
            .gesture(
                DragGesture()
                    .onChanged { value in
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
                case .lyrics:
                    if let current = engine.currentTrack {
                        LyricsSheetView(track: current)
                            .presentationDetents([.medium, .large])
                    }
                case .tagEditor:
                    if let current = engine.currentTrack {
                        BuiltInTagEditorSheet(engine: engine, track: current)
                            .presentationDetents([.medium, .large])
                    }
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

// MARK: - Isolated Scrubber & Timers
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

// MARK: - 3-Way Visualizer Stage (Square Sleeve, Metallic Walkman CD Player, Spinning Side Vinyl)
struct PlayerVisualizerStage: View {
    let mode: VisualMode
    let track: Track?
    let isPlaying: Bool
    let boxSize: CGFloat
    let refreshID: UUID

    var artworkImage: UIImage? {
        let _ = refreshID
        guard let fileName = track?.fileName else { return nil }
        return ArtworkCache.shared.artwork(for: fileName)
    }

    var body: some View {
        ZStack {
            switch mode {
            case .sleeve:
                sleeveCover(size: boxSize)

            case .cdPlayer:
                walkmanCDUnit(size: boxSize)

            case .sideVinyl:
                let sleeveDim = boxSize * 0.80
                let vinylDim = boxSize * 0.78
                HStack(spacing: -vinylDim * 0.45) {
                    sleeveCover(size: sleeveDim)
                        .zIndex(2)

                    ContinuousSpinView(isSpinning: isPlaying, rpm: 14.0) {
                        ZStack {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [Color(white: 0.18), Color.black, Color(white: 0.14), Color.black],
                                        center: .center,
                                        startRadius: 8,
                                        endRadius: vinylDim * 0.5
                                    )
                                )
                                .frame(width: vinylDim, height: vinylDim)

                            Circle()
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                .frame(width: vinylDim * 0.82, height: vinylDim * 0.82)

                            Circle()
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                .frame(width: vinylDim * 0.64, height: vinylDim * 0.64)

                            if let img = artworkImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: vinylDim * 0.38, height: vinylDim * 0.38)
                                    .clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(Color.purple)
                                    .frame(width: vinylDim * 0.38, height: vinylDim * 0.38)
                            }

                            Circle()
                                .fill(Color.black)
                                .frame(width: 12, height: 12)
                        }
                    }
                    .zIndex(1)
                }
            }
        }
    }

    // Metallic Walkman Portable CD Player Housing + Spinning Circular CD Window
    @ViewBuilder
    private func walkmanCDUnit(size: CGFloat) -> some View {
        let discSize = size * 0.78
        ZStack {
            // Walkman Outer Brushed Metal Body
            RoundedRectangle(cornerRadius: 34)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.28), Color(white: 0.16), Color(white: 0.22), Color(white: 0.11)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 1.06, height: size * 1.02)
                .overlay(
                    RoundedRectangle(cornerRadius: 34)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.6), radius: 14, x: 0, y: 8)

            // Walkman Top-Left Status Badge & Right Clasp Detail
            VStack {
                HStack {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isPlaying ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text("WALKMAN ESP")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())

                    Spacer()

                    Text("DISC")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.purple.opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()
            }
            .frame(width: size * 1.06, height: size * 1.02)

            // Recessed Circular CD Tray & Optical Pickup Sled
            Circle()
                .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                .frame(width: discSize + 12, height: discSize + 12)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 2)
                )

            // Optical Laser Lens Slot (visible under transparent window)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.8))
                .frame(width: discSize * 0.36, height: 18)
                .offset(x: discSize * 0.22, y: discSize * 0.22)

            // Spinning Circular CD with Auto-Cropped Artwork
            ContinuousSpinView(isSpinning: isPlaying, rpm: 22.0) {
                ZStack {
                    Circle()
                        .fill(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    .gray.opacity(0.45),
                                    .white.opacity(0.9),
                                    .purple.opacity(0.4),
                                    .cyan.opacity(0.35),
                                    .gray.opacity(0.45)
                                ]),
                                center: .center
                            )
                        )
                        .frame(width: discSize, height: discSize)

                    if let img = artworkImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: discSize * 0.94, height: discSize * 0.94)
                            .clipShape(Circle())
                    }

                    // Iridescent CD sheen overlay
                    Circle()
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [.clear, .white.opacity(0.28), .clear, .purple.opacity(0.25), .clear]),
                                center: .center
                            ),
                            lineWidth: discSize * 0.45
                        )
                        .frame(width: discSize * 0.5, height: discSize * 0.5)
                        .clipShape(Circle())

                    // Center spindle clamping ring
                    Circle()
                        .fill(Color(white: 0.85).opacity(0.3))
                        .frame(width: discSize * 0.28, height: discSize * 0.28)
                    Circle()
                        .stroke(Color.black.opacity(0.55), lineWidth: 4)
                        .frame(width: discSize * 0.24, height: discSize * 0.24)
                    Circle()
                        .fill(Color(red: 0.08, green: 0.08, blue: 0.1))
                        .frame(width: discSize * 0.14, height: discSize * 0.14)
                }
            }

            // Walkman Acrylic Lid Reflection Glare
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.clear, Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: discSize + 8, height: discSize + 8)
                .allowsHitTesting(false)
        }
    }

    // 1:1 Square Auto-Cropped Album Cover
    @ViewBuilder
    private func sleeveCover(size: CGFloat) -> some View {
        if let img = artworkImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
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

// MARK: - Restored Lyrics & Notes Sheet
struct LyricsSheetView: View {
    let track: Track
    @State private var lyricsText: String = ""
    @State private var isFetching: Bool = false
    @State private var statusNote: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        fetchOnline()
                    } label: {
                        if isFetching {
                            ProgressView()
                        } else {
                            Label("Auto-Fetch", systemImage: "sparkles")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(isFetching)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                if !statusNote.isEmpty {
                    Text(statusNote)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                TextEditor(text: $lyricsText)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .padding(10)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Lyrics & Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        LyricsManager.shared.saveLyrics(lyricsText, for: track)
                        statusNote = "Saved lyrics!"
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                lyricsText = LyricsManager.shared.getLyrics(for: track)
            }
        }
    }

    private func fetchOnline() {
        isFetching = true
        statusNote = "Searching LRCLIB..."
        Task {
            if let found = await LyricsManager.shared.fetchOnlineLyrics(title: track.title, artist: track.artist) {
                await MainActor.run {
                    lyricsText = found
                    LyricsManager.shared.saveLyrics(found, for: track)
                    isFetching = false
                    statusNote = "Fetched & saved online lyrics!"
                }
            } else {
                await MainActor.run {
                    isFetching = false
                    statusNote = "No online match found. You can paste lyrics manually below."
                }
            }
        }
    }
}

// MARK: - Restored Built-In Tag & Cover Art Editor (With Auto-Square Crop)
struct BuiltInTagEditorSheet: View {
    @ObservedObject var engine: MusiQEngine
    let track: Track

    @State private var editedTitle: String = ""
    @State private var editedArtist: String = ""
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var previewImage: UIImage? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Cover Art (Auto-Cropped to 1:1 Square & Circle)") {
                    HStack(spacing: 20) {
                        Spacer()
                        // Square Preview
                        if let img = previewImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 96, height: 96)
                                .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                        }

                        // Disc Circle Preview
                        if let img = previewImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(Circle())
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Choose Cover from Photos", systemImage: "photo.on.rectangle.angled")
                    }
                    .onChange(of: selectedPhotoItem) { newItem in
                        guard let newItem = newItem else { return }
                        Task {
                            if let data = try? await newItem.loadTransferable(type: Data.self),
                               let uiImg = UIImage(data: data) {
                                await MainActor.run {
                                    previewImage = uiImg.autoCroppedToSquare()
                                }
                            }
                        }
                    }
                }

                Section("Track Metadata") {
                    TextField("Song Title", text: $editedTitle)
                    TextField("Artist", text: $editedArtist)
                }
            }
            .navigationTitle("Built-In Tag Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        engine.updateTrackTags(
                            track: track,
                            newTitle: editedTitle,
                            newArtist: editedArtist,
                            newCover: previewImage
                        )
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                editedTitle = track.title
                editedArtist = track.artist
                previewImage = ArtworkCache.shared.artwork(for: track.fileName)
            }
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

// MARK: - Tab 3: Integrated YouTube Downloader (Validates Real Audio Bytes & Auto-Crops Artwork)
struct YouTubeDownloaderView: View {
    @ObservedObject var engine: MusiQEngine
    @State private var urlInput: String = ""
    @State private var customTitle: String = ""
    @State private var customArtist: String = ""
    @State private var statusMessage: String = "Paste a YouTube link or direct audio URL."
    @State private var isDownloading: Bool = false

    private let cobaltEndpoints = [
        "https://rue-cobalt.xenon.zone/",
        "https://cobaltapi.cjs.nz/",
        "https://nuko-c.meowing.de/",
        "https://cobalt-api.lamps-dev.dev/",
        "https://capi.3kh0.net/"
    ]

    private let pipedEndpoints = [
        "https://pipedapi.kavin.rocks",
        "https://pipedapi.tokhmi.xyz",
        "https://pipedapi.moomoo.me"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("YouTube / Audio Link") {
                    TextField("https://youtu.be/... or direct audio link", text: $urlInput)
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
                                Text("Downloading & Auto-Cropping...")
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
        statusMessage = "Fetching high-res cover & resolving audio stream..."

        Task {
            do {
                var resolvedTitle = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                var resolvedArtist = customArtist.trimmingCharacters(in: .whitespacesAndNewlines)
                var thumbnailData: Data? = nil

                if trimmedURL.contains("youtube.com") || trimmedURL.contains("youtu.be") {
                    if let encoded = trimmedURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                       let oembedURL = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json"),
                       let (data, _) = try? await URLSession.shared.data(from: oembedURL),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if resolvedTitle.isEmpty, let ytTitle = json["title"] as? String {
                            resolvedTitle = ytTitle
                        }
                        if resolvedArtist.isEmpty, let ytAuthor = json["author_name"] as? String {
                            resolvedArtist = ytAuthor
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
                if resolvedTitle.isEmpty || resolvedTitle == "watch" {
                    resolvedTitle = "Track_\(Int(Date().timeIntervalSince1970))"
                }
                if resolvedArtist.isEmpty {
                    resolvedArtist = "YouTube Import"
                }

                let (tempFileURL, fileExt) = try await downloadVerifiedAudioFile(from: targetURL)

                let safeBaseName = resolvedTitle
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "?", with: "")
                    .replacingOccurrences(of: "\"", with: "")

                let safeFileName = "\(safeBaseName).\(fileExt)"
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destinationURL = docs.appendingPathComponent(safeFileName)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempFileURL, to: destinationURL)

                // Save Custom Metadata & Auto-Square-Cropped Cover Art
                ArtworkCache.shared.saveCustomMetadata(title: resolvedTitle, artist: resolvedArtist, for: safeFileName)
                if let thumbData = thumbnailData, let image = UIImage(data: thumbData) {
                    ArtworkCache.shared.setCustomArtwork(image.autoCroppedToSquare(), for: safeFileName)
                }

                await MainActor.run {
                    isDownloading = false
                    statusMessage = "✅ Saved '\(resolvedTitle)' with square-cropped cover!"
                    urlInput = ""
                    customTitle = ""
                    customArtist = ""
                    engine.scanLocalLibrary()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    statusMessage = "Download error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func extractYouTubeID(from urlString: String) -> String? {
        if let url = URL(string: urlString) {
            if url.host?.contains("youtu.be") == true {
                return url.pathComponents.dropFirst().first
            }
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
                return v
            }
        }
        return nil
    }

    // Verifies the downloaded file is real audio and returns the matching file extension (.mp3 or .m4a)
    private func downloadVerifiedAudioFile(from inputURL: URL) async throws -> (URL, String) {
        let candidateURLs = try await resolveCandidateStreamURLs(from: inputURL)

        for streamURL in candidateURLs {
            var req = URLRequest(url: streamURL)
            req.timeoutInterval = 20
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

            guard let (tempURL, response) = try? await URLSession.shared.download(for: req) else { continue }
            let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

            // Reject HTML/JSON error pages disguised as downloads
            if mime.contains("text/html") || mime.contains("application/json") {
                continue
            }

            guard let headerData = try? Data(contentsOf: tempURL, options: .mappedIfSafe),
                  headerData.count > 8192 else {
                continue
            }

            // Detect real container format from magic bytes so AVAudioFile always decodes properly
            let bytes = [UInt8](headerData.prefix(12))
            var detectedExt = "mp3"
            if bytes.count >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
                detectedExt = "m4a" // ISO Base Media / MP4 / M4A ('ftyp')
            } else if mime.contains("mp4") || mime.contains("m4a") {
                detectedExt = "m4a"
            }

            // Final verification: ensure AVAudioFile can open the downloaded file before accepting it
            let checkURL = FileManager.default.temporaryDirectory.appendingPathComponent("verify_\(UUID().uuidString).\(detectedExt)")
            try? FileManager.default.moveItem(at: tempURL, to: checkURL)
            if (try? AVAudioFile(forReading: checkURL)) != nil {
                return (checkURL, detectedExt)
            } else {
                try? FileManager.default.removeItem(at: checkURL)
            }
        }

        throw NSError(domain: "MusiQDownloader", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "All stream servers returned an unreadable format for this video. Try another link or import from the Files app."
        ])
    }

    private func resolveCandidateStreamURLs(from inputURL: URL) async throws -> [URL] {
        let ext = inputURL.pathExtension.lowercased()
        if ["mp3", "m4a", "wav", "flac", "aac"].contains(ext) {
            return [inputURL]
        }

        var results: [URL] = []

        // 1. Try Piped Streams API first (delivers native M4A audio streams directly)
        if let videoID = extractYouTubeID(from: inputURL.absoluteString) {
            for pipedBase in pipedEndpoints {
                guard let streamAPI = URL(string: "\(pipedBase)/streams/\(videoID)") else { continue }
                var req = URLRequest(url: streamAPI)
                req.timeoutInterval = 8
                if let (data, _) = try? await URLSession.shared.data(for: req),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let audioStreams = json["audioStreams"] as? [[String: Any]] {
                    // Prefer M4A / MP4 streams for native iOS AVAudioEngine decoding
                    let sorted = audioStreams.sorted { a, b in
                        let aMime = (a["mimeType"] as? String) ?? ""
                        let bMime = (b["mimeType"] as? String) ?? ""
                        return aMime.contains("mp4") && !bMime.contains("mp4")
                    }
                    for stream in sorted {
                        if let urlStr = stream["url"] as? String, let sURL = URL(string: urlStr) {
                            results.append(sURL)
                        }
                    }
                }
            }
        }

        // 2. Try Cobalt v10/v11 API instances
        for endpoint in cobaltEndpoints {
            guard let apiEndpoint = URL(string: endpoint) else { continue }
            var request = URLRequest(url: apiEndpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

            let payload: [String: Any] = [
                "url": inputURL.absoluteString,
                "downloadMode": "audio",
                "audioFormat": "mp3"
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            if let (data, _) = try? await URLSession.shared.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let streamURLStr = json["url"] as? String,
               let streamURL = URL(string: streamURLStr) {
                results.append(streamURL)
            }
        }

        if results.isEmpty {
            throw URLError(.cannotFindHost)
        }
        return results
    }
}

// MARK: - Tab 4: Listening Minutes Tracker View
struct ListeningStatsView: View {
    @ObservedObject var engine: MusiQEngine

    var sortedTracksByListenTime: [Track] {
        engine.allTracks.sorted {
            (engine.listenedSecondsByFile[$0.fileName] ?? 0) > (engine.listenedSecondsByFile[$1.fileName] ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

                List {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Total Listening Time")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f Minutes", engine.totalMinutesAcrossLibrary))
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundColor(.purple)
                            }
                            Spacer()
                            Image(systemName: "headphones.circle.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.purple.opacity(0.8))
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(Color.white.opacity(0.06))
                    }

                    Section("Minutes Listened Per Song") {
                        if sortedTracksByListenTime.isEmpty {
                            Text("No songs in library yet.")
                                .foregroundColor(.secondary)
                                .listRowBackground(Color.white.opacity(0.04))
                        } else {
                            ForEach(sortedTracksByListenTime) { track in
                                HStack(spacing: 12) {
                                    if let img = ArtworkCache.shared.artwork(for: track.fileName) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 40, height: 40)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    } else {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.white.opacity(0.1))
                                            .frame(width: 40, height: 40)
                                            .overlay(Image(systemName: "music.note").foregroundColor(.gray))
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text(engine.formattedListenTime(for: track.fileName))
                                        .font(.subheadline.monospacedDigit().weight(.semibold))
                                        .foregroundColor(.purple)
                                }
                                .listRowBackground(Color.white.opacity(0.04))
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .padding(.bottom, engine.currentTrack != nil ? 70 : 0)
            }
            .navigationTitle("Listening Tracker")
        }
    }
}
