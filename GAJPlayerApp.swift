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
    var customCoverKey: String? = nil
}

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    let time: TimeInterval?
    let text: String
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

// MARK: - Image Auto-Cropper & Dominant Album Color Palette Extractor
extension UIImage {
    func autoCroppedToSquare() -> UIImage {
        guard let cgImage = self.cgImage else { return self }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        var effectiveHeight = height
        if width > height * 1.25 {
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

    func extractPlayerGradientColors() -> [Color] {
        guard let cgImage = self.cgImage else {
            return [Color(red: 0.16, green: 0.10, blue: 0.22), Color(red: 0.05, green: 0.05, blue: 0.08)]
        }

        let sampleSize = 16
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var rawData = [UInt8](repeating: 0, count: sampleSize * sampleSize * bytesPerPixel)

        guard let context = CGContext(
            data: &rawData,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return [Color(red: 0.16, green: 0.10, blue: 0.22), Color(red: 0.05, green: 0.05, blue: 0.08)]
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var topR: CGFloat = 0, topG: CGFloat = 0, topB: CGFloat = 0, topWeight: CGFloat = 0
        var botR: CGFloat = 0, botG: CGFloat = 0, botB: CGFloat = 0, botWeight: CGFloat = 0

        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                let offset = (y * sampleSize + x) * bytesPerPixel
                let r = CGFloat(rawData[offset]) / 255.0
                let g = CGFloat(rawData[offset + 1]) / 255.0
                let b = CGFloat(rawData[offset + 2]) / 255.0

                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
                let brightness = (r + g + b) / 3.0

                let weight: CGFloat = 0.2 + (saturation * 2.2) + (brightness > 0.1 && brightness < 0.9 ? 0.5 : 0.0)

                if y < sampleSize / 2 {
                    topR += r * weight
                    topG += g * weight
                    topB += b * weight
                    topWeight += weight
                } else {
                    botR += r * weight
                    botG += g * weight
                    botB += b * weight
                    botWeight += weight
                }
            }
        }

        let c1 = Self.tunedBackgroundUIColor(
            r: topWeight > 0 ? topR / topWeight : 0.2,
            g: topWeight > 0 ? topG / topWeight : 0.1,
            b: topWeight > 0 ? topB / topWeight : 0.3,
            targetBrightness: 0.50
        )
        let c2 = Self.tunedBackgroundUIColor(
            r: botWeight > 0 ? botR / botWeight : 0.1,
            g: botWeight > 0 ? botG / botWeight : 0.08,
            b: botWeight > 0 ? botB / botWeight : 0.18,
            targetBrightness: 0.26
        )

        return [Color(c1), Color(c2), Color(red: 0.04, green: 0.04, blue: 0.06)]
    }

    private static func tunedBackgroundUIColor(r: CGFloat, g: CGFloat, b: CGFloat, targetBrightness: CGFloat) -> UIColor {
        let raw = UIColor(red: r, green: g, blue: b, alpha: 1.0)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        if raw.getHue(&h, saturation: &s, brightness: &br, alpha: &a) {
            let boostedSat = min(max(s * 1.35, 0.28), 0.90)
            let clampedBr = min(max(br * 0.75, 0.18), targetBrightness)
            return UIColor(hue: h, saturation: boostedSat, brightness: clampedBr, alpha: 1.0)
        }
        return raw
    }
}

// MARK: - Fast Artwork, Gradient & Custom Tag Cache
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    private var gradientCache: [String: [Color]] = [:]
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
            gradientCache[fileName] = squared.extractPlayerGradientColors()
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
                    gradientCache[fileName] = squared.extractPlayerGradientColors()
                    return squared
                }
            }
        }
        return nil
    }

    func playerGradient(for fileName: String?) -> [Color] {
        guard let fileName = fileName else {
            return [Color(red: 0.16, green: 0.10, blue: 0.24), Color(red: 0.08, green: 0.06, blue: 0.14), Color(red: 0.04, green: 0.04, blue: 0.06)]
        }
        if let cached = gradientCache[fileName] {
            return cached
        }
        if let img = artwork(for: fileName) {
            let cols = img.extractPlayerGradientColors()
            gradientCache[fileName] = cols
            return cols
        }
        return [Color(red: 0.18, green: 0.10, blue: 0.26), Color(red: 0.09, green: 0.06, blue: 0.15), Color(red: 0.04, green: 0.04, blue: 0.06)]
    }

    func setCustomArtwork(_ image: UIImage, for fileName: String) {
        let squared = image.autoCroppedToSquare()
        cache.setObject(squared, forKey: fileName as NSString)
        gradientCache[fileName] = squared.extractPlayerGradientColors()
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

// MARK: - Synced Lyrics Storage, LRC Parser & Auto-Fetcher
final class LyricsManager {
    static let shared = LyricsManager()
    private let storageKey = "MusiQ_Saved_Lyrics_v3"

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

    func parseLyrics(_ raw: String) -> [LyricLine] {
        let rawLines = raw.components(separatedBy: .newlines)
        var parsed: [LyricLine] = []

        let pattern = #"\[(\d{1,2}):(\d{2})(?:[\.:](\d{1,3}))?\](.*)"#
        let regex = try? NSRegularExpression(pattern: pattern)

        var idx = 0
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex?.firstMatch(in: trimmed, options: [], range: nsRange),
               let minRange = Range(match.range(at: 1), in: trimmed),
               let secRange = Range(match.range(at: 2), in: trimmed),
               let textRange = Range(match.range(at: 4), in: trimmed) {

                let mins = Double(trimmed[minRange]) ?? 0
                let secs = Double(trimmed[secRange]) ?? 0
                var frac: Double = 0
                if match.range(at: 3).location != NSNotFound,
                   let fracRange = Range(match.range(at: 3), in: trimmed) {
                    let fracStr = String(trimmed[fracRange])
                    let divisor = pow(10.0, Double(fracStr.count))
                    frac = (Double(fracStr) ?? 0) / divisor
                }
                let timestamp = (mins * 60.0) + secs + frac
                let lyricText = String(trimmed[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !lyricText.isEmpty {
                    parsed.append(LyricLine(index: idx, time: timestamp, text: lyricText))
                    idx += 1
                }
            } else if !trimmed.hasPrefix("[ti:") && !trimmed.hasPrefix("[ar:") && !trimmed.hasPrefix("[al:") && !trimmed.hasPrefix("[by:") && !trimmed.hasPrefix("[length:") && !trimmed.hasPrefix("[offset:") {
                parsed.append(LyricLine(index: idx, time: nil, text: trimmed))
                idx += 1
            }
        }

        return parsed
    }

    static func activeLineIndex(in lines: [LyricLine], currentTime: Double, duration: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        if lines.contains(where: { $0.time != nil }) {
            var lastMatch: Int = 0
            for (i, line) in lines.enumerated() {
                if let t = line.time, t <= currentTime + 0.15 {
                    lastMatch = i
                }
            }
            return lastMatch
        } else {
            let dur = max(duration, 1)
            let ratio = min(max(currentTime / dur, 0), 0.999)
            return Int(ratio * Double(lines.count))
        }
    }

    func fetchOnlineLyrics(title: String, artist: String) async -> String? {
        let cleanTitle = title
            .replacingOccurrences(of: "(highest quality)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Official Audio)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Official Video)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Official Music Video)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Lyrics)", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var query = cleanTitle
        if artist != "Unknown Artist" && artist != "Direct Audio Import" && !artist.isEmpty {
            query = "\(artist) \(cleanTitle)"
        }

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lrclib.net/api/search?q=\(encoded)") else {
            return nil
        }

        do {
            var req = URLRequest(url: url)
            req.setValue("MusiQ iOS Player v2.2", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               !results.isEmpty {
                if let syncedMatch = results.first(where: { ($0["syncedLyrics"] as? String)?.isEmpty == false }),
                   let synced = syncedMatch["syncedLyrics"] as? String {
                    return synced
                }
                if let plain = results.first?["plainLyrics"] as? String, !plain.isEmpty {
                    return plain
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

    @Published var currentTrackLyrics: [LyricLine] = []
    @Published var isFetchingLyricsInBackground: Bool = false

    @Published var listenedSecondsByFile: [String: Double] = [:]

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

    private let playlistsStorageKey = "MusiQ_User_Playlists_v3"
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

    /// Rebuilds the entire DSP chain at the exact sample rate (44.1kHz, 48kHz, 96kHz) of the active file so songs NEVER pitch-down or slow-down
    private func rebuildAudioGraph(for fileFormat: AVAudioFormat) {
        engine.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitchNode)
        engine.disconnectNodeOutput(eqNode)

        engine.connect(playerNode, to: timePitchNode, format: fileFormat)
        engine.connect(timePitchNode, to: eqNode, format: fileFormat)
        engine.connect(eqNode, to: engine.mainMixerNode, format: fileFormat)

        timePitchNode.pitch = pitchCents
        timePitchNode.rate = playbackRate
        setEQ(eqPreset)

        engine.prepare()
        try? engine.start()
    }

    func reloadLyricsForCurrentTrack() {
        guard let track = currentTrack else {
            currentTrackLyrics = []
            return
        }
        let saved = LyricsManager.shared.getLyrics(for: track)
        if !saved.isEmpty {
            currentTrackLyrics = LyricsManager.shared.parseLyrics(saved)
        } else {
            currentTrackLyrics = []
            isFetchingLyricsInBackground = true
            let requestedFile = track.fileName
            Task {
                if let fetched = await LyricsManager.shared.fetchOnlineLyrics(title: track.title, artist: track.artist) {
                    LyricsManager.shared.saveLyrics(fetched, for: track)
                    let parsed = LyricsManager.shared.parseLyrics(fetched)
                    await MainActor.run {
                        if self.currentTrack?.fileName == requestedFile {
                            self.currentTrackLyrics = parsed
                        }
                        self.isFetchingLyricsInBackground = false
                    }
                } else {
                    await MainActor.run {
                        self.isFetchingLyricsInBackground = false
                    }
                }
            }
        }
    }

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

    // MARK: - Playlist Management + Custom Playlist Artwork
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

    func renamePlaylist(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = trimmed
        savePlaylists()
    }

    func setPlaylistCustomCover(_ image: UIImage, for playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let key = "playlist_cover_\(playlistID.uuidString)"
        ArtworkCache.shared.setCustomArtwork(image, for: key)
        playlists[idx].customCoverKey = key
        savePlaylists()
        artworkRefreshID = UUID()
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

    // MARK: - Playback Controls (With Sample-Rate Safe Graph Rebuilder)
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

        playerNode.stop()
        playerNode.reset()
        activeAudioFile = nil
        isPlaying = false
        playbackErrorMessage = nil
        loopStart = nil
        loopEnd = nil
        progress.currentTime = 0

        reloadLyricsForCurrentTrack()

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

            // Rebuild graph using the exact file sample rate so 48kHz / 44.1kHz tracks never pitch-shift!
            rebuildAudioGraph(for: file.processingFormat)

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
            playbackErrorMessage = "Corrupted audio format. Delete & re-import this track."
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

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying, self.activeAudioFile != nil else { return }

            if let activeFile = self.currentTrack?.fileName {
                self.listenedSecondsByFile[activeFile, default: 0] += 0.15
                self.tickCounter += 1
                if self.tickCounter % 25 == 0 {
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

// MARK: - Continuous 60fps Spinning Disc Modifier
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

// MARK: - Looping Marquee Text
struct LoopingMarqueeText: View {
    let text: String
    let font: Font
    let textColor: Color
    var alignment: Alignment = .center

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
                        .frame(width: geo.size.width, alignment: alignment)
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
        .frame(height: 28)
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

// MARK: - Polished Spotify-Style Inline Lyric Line (Fixed Alignment & Smooth Crossfade)
struct SpotifyInlineLyricView: View {
    @ObservedObject var progress: PlaybackProgressObserver
    let lines: [LyricLine]
    let isFetching: Bool
    let onTap: () -> Void

    private var activeIndex: Int? {
        LyricsManager.activeLineIndex(
            in: lines,
            currentTime: progress.currentTime,
            duration: progress.duration
        )
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .leading) {
                if let idx = activeIndex {
                    let currentLine = lines[idx].text
                    Text(currentLine)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("inline_lyric_\(idx)")
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
                        .animation(.easeOut(duration: 0.24), value: idx)
                } else if isFetching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.white.opacity(0.5))
                        Text("Syncing lyrics...")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 12))
                        Text("Tap for lyrics")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.32))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 44)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Apple Music-Style Blurred Scrolling Lyrics Sheet (Refined Blur & Spacing)
struct AppleMusicLyricsSheetView: View {
    @ObservedObject var engine: MusiQEngine
    @ObservedObject var progress: PlaybackProgressObserver
    let track: Track

    @State private var showRawEditor: Bool = false
    @State private var rawLyricsDraft: String = ""
    @State private var isFetchingOnline: Bool = false
    @Environment(\.dismiss) private var dismiss

    private var activeIndex: Int? {
        LyricsManager.activeLineIndex(
            in: engine.currentTrackLyrics,
            currentTime: progress.currentTime,
            duration: progress.duration
        )
    }

    private var albumGradient: [Color] {
        ArtworkCache.shared.playerGradient(for: track.fileName)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: albumGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 12)

                // Compact Header
                HStack(spacing: 14) {
                    if let art = ArtworkCache.shared.artwork(for: track.fileName) {
                        Image(uiImage: art)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 50, height: 50)
                            .overlay(Image(systemName: "music.note").foregroundColor(.white))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }

                    Spacer()

                    Menu {
                        Button {
                            autoFetchSynced()
                        } label: {
                            Label("Auto-Fetch Synced Lyrics", systemImage: "sparkles")
                        }

                        Button {
                            rawLyricsDraft = LyricsManager.shared.getLyrics(for: track)
                            showRawEditor.toggle()
                        } label: {
                            Label(showRawEditor ? "View Synced Lyrics" : "Edit Raw Lyrics / LRC", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            dismiss()
                        } label: {
                            Label("Close Lyrics", systemImage: "xmark")
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.16))
                                .frame(width: 36, height: 36)
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)

                if showRawEditor {
                    VStack(spacing: 12) {
                        TextEditor(text: $rawLyricsDraft)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .padding(10)
                            .background(Color.black.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 20)

                        HStack(spacing: 16) {
                            Button("Cancel") {
                                showRawEditor = false
                            }
                            .foregroundColor(.white.opacity(0.75))

                            Button {
                                LyricsManager.shared.saveLyrics(rawLyricsDraft, for: track)
                                engine.reloadLyricsForCurrentTrack()
                                showRawEditor = false
                            } label: {
                                Text("Save Lyrics")
                                    .font(.headline)
                                    .padding(.horizontal, 22)
                                    .padding(.vertical, 10)
                                    .background(Color.white)
                                    .foregroundColor(.black)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.bottom, 16)
                    }
                } else {
                    if engine.currentTrackLyrics.isEmpty {
                        Spacer()
                        VStack(spacing: 14) {
                            if isFetchingOnline || engine.isFetchingLyricsInBackground {
                                ProgressView()
                                    .tint(.white)
                                Text("Searching synced lyrics...")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.7))
                            } else {
                                Image(systemName: "quote.bubble")
                                    .font(.system(size: 42))
                                    .foregroundColor(.white.opacity(0.45))
                                Text("No Synced Lyrics Found")
                                    .font(.title3.bold())
                                    .foregroundColor(.white)
                                HStack(spacing: 12) {
                                    Button {
                                        autoFetchSynced()
                                    } label: {
                                        Label("Retry Auto-Fetch", systemImage: "sparkles")
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                            .background(Color.white.opacity(0.2))
                                            .foregroundColor(.white)
                                            .clipShape(Capsule())
                                    }

                                    Button {
                                        rawLyricsDraft = ""
                                        showRawEditor = true
                                    } label: {
                                        Label("Paste Lyrics", systemImage: "doc.on.clipboard")
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                            .background(Color.white.opacity(0.14))
                                            .foregroundColor(.white)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                        Spacer()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 22) {
                                    Spacer().frame(height: 20)

                                    ForEach(engine.currentTrackLyrics) { line in
                                        let currentIdx = activeIndex ?? 0
                                        let isCurrent = (line.index == currentIdx)
                                        let distance = abs(line.index - currentIdx)

                                        Button {
                                            if let t = line.time {
                                                engine.seek(to: t)
                                            }
                                        } label: {
                                            Text(line.text)
                                                .font(.system(size: 27, weight: .bold, design: .rounded))
                                                .foregroundColor(.white.opacity(isCurrent ? 1.0 : max(0.26, 0.52 - Double(distance) * 0.07)))
                                                .blur(radius: isCurrent ? 0 : min(CGFloat(distance) * 1.1, 3.6))
                                                .scaleEffect(isCurrent ? 1.0 : 0.95, anchor: .leading)
                                                .multilineTextAlignment(.leading)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .animation(.spring(response: 0.36, dampingFraction: 0.84), value: currentIdx)
                                        }
                                        .buttonStyle(.plain)
                                        .id(line.index)
                                    }

                                    Spacer().frame(height: 140)
                                }
                                .padding(.horizontal, 26)
                            }
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: .black, location: 0.07),
                                        .init(color: .black, location: 0.88),
                                        .init(color: .clear, location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .onAppear {
                                if let idx = activeIndex {
                                    proxy.scrollTo(idx, anchor: UnitPoint(x: 0.5, y: 0.30))
                                }
                            }
                            .onChange(of: activeIndex) { newIdx in
                                guard let idx = newIdx else { return }
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                                    proxy.scrollTo(idx, anchor: UnitPoint(x: 0.5, y: 0.30))
                                }
                            }
                        }
                    }

                    // Bottom Scrubber & Transport Controls
                    VStack(spacing: 12) {
                        IsolatedScrubberView(progress: engine.progress) { newSeconds in
                            engine.seek(to: newSeconds)
                        }
                        .padding(.horizontal, 26)

                        HStack(spacing: 48) {
                            Button {
                                engine.previousTrack()
                            } label: {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundColor(.white)
                            }

                            Button {
                                engine.togglePlayPause()
                            } label: {
                                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundColor(.white)
                            }

                            Button {
                                engine.nextTrack()
                            } label: {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func autoFetchSynced() {
        isFetchingOnline = true
        Task {
            if let found = await LyricsManager.shared.fetchOnlineLyrics(title: track.title, artist: track.artist) {
                await MainActor.run {
                    LyricsManager.shared.saveLyrics(found, for: track)
                    engine.reloadLyricsForCurrentTrack()
                    isFetchingOnline = false
                }
            } else {
                await MainActor.run {
                    isFetchingOnline = false
                }
            }
        }
    }
}

// MARK: - Dynamic Playlist Cover View (Custom Photo or Automatic 2x2 Album Grid Collage)
struct PlaylistCoverThumbnail: View {
    @ObservedObject var engine: MusiQEngine
    let playlist: Playlist
    let size: CGFloat
    let cornerRadius: CGFloat

    private var playlistTracks: [Track] {
        engine.tracks(for: playlist)
    }

    private var customCoverImage: UIImage? {
        let _ = engine.artworkRefreshID
        guard let key = playlist.customCoverKey else { return nil }
        return ArtworkCache.shared.artwork(for: key)
    }

    private var trackCovers: [UIImage] {
        let _ = engine.artworkRefreshID
        var imgs: [UIImage] = []
        for t in playlistTracks {
            if let art = ArtworkCache.shared.artwork(for: t.fileName) {
                imgs.append(art)
                if imgs.count == 4 { break }
            }
        }
        return imgs
    }

    var body: some View {
        Group {
            if let custom = customCoverImage {
                Image(uiImage: custom)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else if trackCovers.count >= 4 {
                // Automatic 2x2 Album Art Grid Collage (Like Spotify Playlists)
                let half = size / 2.0
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Image(uiImage: trackCovers[0]).resizable().scaledToFill().frame(width: half, height: half).clipped()
                        Image(uiImage: trackCovers[1]).resizable().scaledToFill().frame(width: half, height: half).clipped()
                    }
                    HStack(spacing: 0) {
                        Image(uiImage: trackCovers[2]).resizable().scaledToFill().frame(width: half, height: half).clipped()
                        Image(uiImage: trackCovers[3]).resizable().scaledToFill().frame(width: half, height: half).clipped()
                    }
                }
                .frame(width: size, height: size)
            } else if let firstCover = trackCovers.first {
                Image(uiImage: firstCover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color.purple.opacity(0.75), Color.indigo.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note.list")
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
                .frame(width: size, height: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
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

                DirectAudioImporterView(engine: engine)
                    .tabItem {
                        Label("Import", systemImage: "arrow.down.circle.fill")
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

// MARK: - Tab 1: Polished Playlists Home View
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
                        Text("Create custom playlists with your own cover art or 2x2 album grids.")
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
                                    PlaylistCoverThumbnail(engine: engine, playlist: playlist, size: 58, cornerRadius: 10)

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

// MARK: - Spotify-Inspired Playlist Detail View (Custom Art, Hero Banner, Duration & Search)
struct PlaylistDetailView: View {
    @ObservedObject var engine: MusiQEngine
    let playlistID: UUID
    @Binding var showFullPlayer: Bool

    @State private var showSongPicker = false
    @State private var showRenameAlert = false
    @State private var editedName = ""
    @State private var selectedCoverPhoto: PhotosPickerItem? = nil

    var playlist: Playlist? {
        engine.playlists.first(where: { $0.id == playlistID })
    }

    var tracks: [Track] {
        playlist.map { engine.tracks(for: $0) } ?? []
    }

    private var headerGradientColors: [Color] {
        let _ = engine.artworkRefreshID
        if let customKey = playlist?.customCoverKey {
            return ArtworkCache.shared.playerGradient(for: customKey)
        }
        if let firstFile = tracks.first?.fileName {
            return ArtworkCache.shared.playerGradient(for: firstFile)
        }
        return [Color.purple.opacity(0.55), Color(red: 0.08, green: 0.07, blue: 0.12), Color(red: 0.06, green: 0.06, blue: 0.08)]
    }

    private var formattedTotalDuration: String {
        let totalSecs = Int(tracks.reduce(0) { $0 + $1.duration })
        let hours = totalSecs / 3600
        let mins = (totalSecs % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(mins) min"
        }
        return "\(max(1, mins)) min"
    }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

            List {
                // Hero Header Section
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .bottom, spacing: 18) {
                            if let pl = playlist {
                                PlaylistCoverThumbnail(engine: engine, playlist: pl, size: 128, cornerRadius: 14)
                                    .shadow(color: .black.opacity(0.55), radius: 12, x: 0, y: 6)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("CUSTOM PLAYLIST")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.65))

                                Text(playlist?.name ?? "Playlist")
                                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                                    .lineLimit(2)

                                Text("\(tracks.count) songs • \(formattedTotalDuration)")
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                            Spacer(minLength: 0)
                        }

                        // Action Bar (Play, Shuffle, Add Songs, Customize Art & Name)
                        HStack(spacing: 12) {
                            Button {
                                if let first = tracks.first {
                                    engine.isShuffle = false
                                    engine.playTrack(first, in: tracks)
                                    showFullPlayer = true
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.purple)
                                        .frame(width: 50, height: 50)
                                        .shadow(color: .purple.opacity(0.45), radius: 8, x: 0, y: 4)
                                    Image(systemName: "play.fill")
                                        .font(.title3.bold())
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(tracks.isEmpty)

                            Button {
                                if let randomTrack = tracks.randomElement() {
                                    engine.isShuffle = true
                                    engine.playTrack(randomTrack, in: tracks)
                                    showFullPlayer = true
                                }
                            } label: {
                                Image(systemName: "shuffle")
                                    .font(.headline)
                                    .foregroundColor(engine.isShuffle ? .purple : .white)
                                    .frame(width: 42, height: 42)
                                    .background(Color.white.opacity(0.12))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(tracks.isEmpty)

                            Button {
                                showSongPicker = true
                            } label: {
                                Label("Add", systemImage: "plus")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.12))
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            PhotosPicker(selection: $selectedCoverPhoto, matching: .images) {
                                Label("Cover", systemImage: "photo")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.12))
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .onChange(of: selectedCoverPhoto) { newItem in
                                guard let newItem = newItem else { return }
                                Task {
                                    if let data = try? await newItem.loadTransferable(type: Data.self),
                                       let img = UIImage(data: data) {
                                        await MainActor.run {
                                            engine.setPlaylistCustomCover(img, for: playlistID)
                                        }
                                    }
                                }
                            }

                            Button {
                                editedName = playlist?.name ?? ""
                                showRenameAlert = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.white.opacity(0.12))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)

                            Spacer()
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(
                        LinearGradient(
                            colors: [headerGradientColors[0].opacity(0.65), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }

                // Track List Section
                Section {
                    if tracks.isEmpty {
                        VStack(spacing: 10) {
                            Text("This playlist is empty.")
                                .foregroundColor(.secondary)
                            Button("Add Songs from Library") {
                                showSongPicker = true
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.purple)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                            HStack(spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 20, alignment: .leading)

                                TrackRowView(engine: engine, track: track) {
                                    engine.playTrack(track, in: tracks)
                                    showFullPlayer = true
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.04))
                        }
                        .onDelete { offsets in
                            offsets.forEach { idx in
                                engine.removeTrack(fileName: tracks[idx].fileName, from: playlistID)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .padding(.bottom, engine.currentTrack != nil ? 70 : 0)
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Playlist", isPresented: $showRenameAlert) {
            TextField("Playlist Name", text: $editedName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                engine.renamePlaylist(id: playlistID, newName: editedName)
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
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .foregroundColor(.white)
                                        Text(track.artist)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
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

// MARK: - Tab 2: Global Searchable Songs & Artist Browser
struct AllSongsSearchView: View {
    @ObservedObject var engine: MusiQEngine
    @Binding var showFullPlayer: Bool
    @State private var searchText: String = ""
    @State private var browseMode: BrowseMode = .songs
    @State private var showFileImporter: Bool = false
    @State private var trackToTag: Track? = nil

    enum BrowseMode: String, CaseIterable {
        case songs = "All Songs"
        case artists = "Artists"
    }

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

    var groupedArtists: [(artist: String, tracks: [Track])] {
        let dict = Dictionary(grouping: filteredTracks) { $0.artist }
        return dict.map { (artist: $0.key, tracks: $0.value) }
            .sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
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
                        Text("Import audio files directly from your iPhone Files app.")
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
                    VStack(spacing: 0) {
                        // Segmented Songs vs Artists Filter
                        Picker("Browse Mode", selection: $browseMode) {
                            ForEach(BrowseMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        if browseMode == .songs {
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
                        } else {
                            // Browse by Artist View
                            List {
                                ForEach(groupedArtists, id: \.artist) { group in
                                    NavigationLink(destination: ArtistDetailView(engine: engine, artistName: group.artist, tracks: group.tracks, showFullPlayer: $showFullPlayer)) {
                                        HStack(spacing: 14) {
                                            if let firstTrack = group.tracks.first,
                                               let art = ArtworkCache.shared.artwork(for: firstTrack.fileName) {
                                                Image(uiImage: art)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 50, height: 50)
                                                    .clipShape(Circle())
                                            } else {
                                                Circle()
                                                    .fill(Color.purple.opacity(0.3))
                                                    .frame(width: 50, height: 50)
                                                    .overlay(Image(systemName: "person.fill").foregroundColor(.white))
                                            }

                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(group.artist)
                                                    .font(.headline)
                                                    .foregroundColor(.white)
                                                Text("\(group.tracks.count) \(group.tracks.count == 1 ? "song" : "songs")")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    .listRowBackground(Color.white.opacity(0.04))
                                }
                            }
                            .scrollContentBackground(.hidden)
                        }
                    }
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search songs or artists...")
                    .padding(.bottom, engine.currentTrack != nil ? 70 : 0)
                }
            }
            .navigationTitle("Library (\(engine.allTracks.count))")
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

// MARK: - Artist Discography Detail View
struct ArtistDetailView: View {
    @ObservedObject var engine: MusiQEngine
    let artistName: String
    let tracks: [Track]
    @Binding var showFullPlayer: Bool

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

            List {
                Section {
                    HStack(spacing: 16) {
                        if let first = tracks.first,
                           let art = ArtworkCache.shared.artwork(for: first.fileName) {
                            Image(uiImage: art)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 76, height: 76)
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color.purple.opacity(0.35))
                                .frame(width: 76, height: 76)
                                .overlay(Image(systemName: "person.fill").font(.title).foregroundColor(.white))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(artistName)
                                .font(.title2.bold())
                                .foregroundColor(.white)
                            Text("\(tracks.count) tracks in library")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button {
                            if let first = tracks.first {
                                engine.playTrack(first, in: tracks)
                                showFullPlayer = true
                            }
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.purple)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.white.opacity(0.06))
                }

                Section("Songs") {
                    ForEach(tracks) { track in
                        TrackRowView(engine: engine, track: track) {
                            engine.playTrack(track, in: tracks)
                            showFullPlayer = true
                        }
                        .listRowBackground(Color.white.opacity(0.04))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .padding(.bottom, engine.currentTrack != nil ? 70 : 0)
        }
        .navigationTitle(artistName)
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

// MARK: - Full-Screen Player
struct FullPlayerDeckView: View {
    @ObservedObject var engine: MusiQEngine
    @Binding var isPresented: Bool

    @State private var activeBottomSheet: BottomPanel? = nil
    @State private var dragOffset: CGSize = .zero

    enum BottomPanel: Identifiable {
        case dsp, lyrics, tagEditor, queue
        var id: Int { hashValue }
    }

    private var dynamicAlbumGradient: [Color] {
        let _ = engine.artworkRefreshID
        return ArtworkCache.shared.playerGradient(for: engine.currentTrack?.fileName)
    }

    var body: some View {
        GeometryReader { geo in
            let safeWidth = geo.size.width
            let artBoxSize = min(safeWidth - 96, 238)

            ZStack {
                LinearGradient(
                    colors: dynamicAlbumGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.65), value: engine.currentTrack?.fileName)

                VStack(spacing: 10) {
                    // Top Bar
                    HStack {
                        Button {
                            isPresented = false
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.title3.weight(.semibold))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(8)
                        }
                        Spacer()
                        Capsule()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 42, height: 5)
                        Spacer()
                        if let track = engine.currentTrack {
                            Text(engine.formattedListenTime(for: track.fileName))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.28))
                                .clipShape(Capsule())
                                .foregroundColor(.white.opacity(0.9))
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
                                .padding(.vertical, 7)
                                .background(engine.visualMode == mode ? Color.white.opacity(0.24) : Color.black.opacity(0.22))
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                            }
                        }
                    }

                    Spacer(minLength: 2)

                    // Visualizer Stage
                    PlayerVisualizerStage(
                        mode: engine.visualMode,
                        track: engine.currentTrack,
                        isPlaying: engine.isPlaying,
                        boxSize: artBoxSize,
                        refreshID: engine.artworkRefreshID
                    )
                    .frame(width: safeWidth - 24, height: artBoxSize + 16)
                    .clipped()

                    // Refined Spotify-Style Inline Lyric Line
                    SpotifyInlineLyricView(
                        progress: engine.progress,
                        lines: engine.currentTrackLyrics,
                        isFetching: engine.isFetchingLyricsInBackground
                    ) {
                        activeBottomSheet = .lyrics
                    }
                    .padding(.horizontal, 26)

                    if let err = engine.playbackErrorMessage {
                        Text(err)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }

                    // Left-Aligned Song Title + Artist (Matches Spotify Layout)
                    VStack(alignment: .leading, spacing: 2) {
                        LoopingMarqueeText(
                            text: engine.currentTrack?.title ?? "No Track Selected",
                            font: .system(size: 22, weight: .bold),
                            textColor: .white,
                            alignment: .leading
                        )
                        .frame(width: safeWidth - 52)

                        Text(engine.currentTrack?.artist ?? "MusiQ Local Library")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                    .frame(width: safeWidth - 52, alignment: .leading)

                    // Isolated Scrubber + Timers
                    IsolatedScrubberView(progress: engine.progress) { newSeconds in
                        engine.seek(to: newSeconds)
                    }
                    .padding(.horizontal, 26)

                    // A-B Loop Pill
                    Button {
                        engine.toggleABLoop()
                    } label: {
                        Text(abLoopLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(engine.loopStart != nil ? Color.purple : Color.black.opacity(0.26))
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
                                .foregroundColor(engine.isShuffle ? .white : .white.opacity(0.45))
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
                                    .fill(Color.white.opacity(0.22))
                                    .frame(width: 68, height: 68)
                                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 27, weight: .bold))
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
                                .foregroundColor(engine.isRepeat ? .white : .white.opacity(0.45))
                        }
                    }

                    // Bottom Action Bar
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
                    .padding(.top, 4)
                    .padding(.bottom, 12)
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
                        AppleMusicLyricsSheetView(engine: engine, progress: engine.progress, track: current)
                            .presentationDetents([.large])
                            .presentationDragIndicator(.hidden)
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
        VStack(spacing: 4) {
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
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text("-" + formatTime(max(0, progress.duration - progress.currentTime)))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 3-Way Visualizer Stage
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

    @ViewBuilder
    private func walkmanCDUnit(size: CGFloat) -> some View {
        let discSize = size * 0.78
        ZStack {
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

            Circle()
                .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                .frame(width: discSize + 12, height: discSize + 12)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 2)
                )

            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.8))
                .frame(width: discSize * 0.36, height: 18)
                .offset(x: discSize * 0.22, y: discSize * 0.22)

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
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
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

// MARK: - Built-In Tag & Cover Art Editor
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

// MARK: - Tab 3: Direct Audio URL & Files Importer
struct DirectAudioImporterView: View {
    @ObservedObject var engine: MusiQEngine
    @State private var urlInput: String = ""
    @State private var customTitle: String = ""
    @State private var customArtist: String = ""
    @State private var statusMessage: String = "Paste a direct audio file link (.mp3, .m4a, .wav, .flac) or import from the Files app."
    @State private var isDownloading: Bool = false
    @State private var showFileImporter: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick Local Import") {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Select Audio Files from iPhone Files App", systemImage: "folder.fill.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.purple)
                    }
                }

                Section("Direct Audio File URL") {
                    TextField("https://example.com/audio.mp3", text: $urlInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Optional Custom Metadata") {
                    TextField("Custom Song Title (Leave blank for auto)", text: $customTitle)
                    TextField("Artist Name (Optional)", text: $customArtist)
                }

                Section {
                    Button {
                        startDirectDownload()
                    } label: {
                        HStack {
                            Spacer()
                            if isDownloading {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Downloading Audio...")
                            } else {
                                Label("Download Direct Audio Link", systemImage: "arrow.down.circle.fill")
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
            .navigationTitle("Audio Importer")
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
                    statusMessage = "✅ Imported \(urls.count) file(s) into your MusiQ library!"
                    engine.scanLocalLibrary()
                case .failure(let err):
                    statusMessage = "File import failed: \(err.localizedDescription)"
                }
            }
        }
    }

    private func startDirectDownload() {
        let trimmedURL = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetURL = URL(string: trimmedURL) else {
            statusMessage = "Invalid URL format."
            return
        }

        isDownloading = true
        statusMessage = "Downloading direct audio file..."

        Task {
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: targetURL)
                let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

                var ext = targetURL.pathExtension.lowercased()
                if !["mp3", "m4a", "wav", "flac", "aac"].contains(ext) {
                    ext = mime.contains("mp4") || mime.contains("m4a") ? "m4a" : "mp3"
                }

                var resolvedTitle = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if resolvedTitle.isEmpty {
                    resolvedTitle = targetURL.deletingPathExtension().lastPathComponent
                }
                if resolvedTitle.isEmpty {
                    resolvedTitle = "Track_\(Int(Date().timeIntervalSince1970))"
                }

                var resolvedArtist = customArtist.trimmingCharacters(in: .whitespacesAndNewlines)
                if resolvedArtist.isEmpty {
                    resolvedArtist = "Direct Audio Import"
                }

                let safeBaseName = resolvedTitle
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "?", with: "")

                let safeFileName = "\(safeBaseName).\(ext)"
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destinationURL = docs.appendingPathComponent(safeFileName)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                guard (try? AVAudioFile(forReading: destinationURL)) != nil else {
                    try? FileManager.default.removeItem(at: destinationURL)
                    throw NSError(domain: "MusiQ", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "URL did not point to a valid direct audio file."
                    ])
                }

                ArtworkCache.shared.saveCustomMetadata(title: resolvedTitle, artist: resolvedArtist, for: safeFileName)

                if let lyrics = await LyricsManager.shared.fetchOnlineLyrics(title: resolvedTitle, artist: resolvedArtist) {
                    let tempTrack = Track(id: UUID(), title: resolvedTitle, artist: resolvedArtist, fileName: safeFileName, duration: 0)
                    LyricsManager.shared.saveLyrics(lyrics, for: tempTrack)
                }

                await MainActor.run {
                    isDownloading = false
                    statusMessage = "✅ Saved '\(resolvedTitle)' to your Songs library!"
                    urlInput = ""
                    customTitle = ""
                    customArtist = ""
                    engine.scanLocalLibrary()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    statusMessage = "Import error: \(error.localizedDescription)"
                }
            }
        }
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
