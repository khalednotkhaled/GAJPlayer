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

    var formattedDuration: String {
        guard duration.isFinite && duration > 0 else { return "0:00" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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
    var hasCustomCover: Bool = false
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

// MARK: - Fast Artwork, Playlist Cover & Custom Tag Cache
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

    func playlistCover(for playlistID: UUID) -> UIImage? {
        let key = "playlist_\(playlistID.uuidString)"
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("\(key).jpg")
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            let squared = img.autoCroppedToSquare()
            cache.setObject(squared, forKey: key as NSString)
            return squared
        }
        return nil
    }

    func setPlaylistCover(_ image: UIImage, for playlistID: UUID) {
        let key = "playlist_\(playlistID.uuidString)"
        let squared = image.autoCroppedToSquare()
        cache.setObject(squared, forKey: key as NSString)
        if let data = squared.jpegData(compressionQuality: 0.9) {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = docs.appendingPathComponent("\(key).jpg")
            try? data.write(to: url)
        }
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

// MARK: - Synced Lyrics Storage, Per-Track Intro Offset & Auto-Fetcher
final class LyricsManager {
    static let shared = LyricsManager()
    private let storageKey = "MusiQ_Saved_Lyrics_v3"
    private let offsetStorageKey = "MusiQ_Lyrics_Offsets_v1"

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

    /// Returns per-song lyric timing offset in seconds (e.g., +12.5s if the track has a video intro)
    func getOffset(for fileName: String) -> Double {
        let dict = (UserDefaults.standard.dictionary(forKey: offsetStorageKey) as? [String: Double]) ?? [:]
        return dict[fileName] ?? 0.0
    }

    func saveOffset(_ offset: Double, for fileName: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: offsetStorageKey) as? [String: Double]) ?? [:]
        dict[fileName] = offset
        UserDefaults.standard.set(dict, forKey: offsetStorageKey)
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
            } else if !trimmed.hasPrefix("[ti:") && !trimmed.hasPrefix("[ar:") && !trimmed.hasPrefix("[al:") && !trimmed.hasPrefix("[by:") && !trimmed.hasPrefix("[length:") {
                parsed.append(LyricLine(index: idx, time: nil, text: trimmed))
                idx += 1
            }
        }

        return parsed
    }

    /// Evaluates active lyric index taking the user's custom Intro Offset into account
    static func activeLineIndex(in lines: [LyricLine], currentTime: Double, duration: Double, offsetSeconds: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        // Positive offset means the song has a longer intro than the lyrics (delays lyrics by offsetSeconds)
        let adjustedTime = max(0, currentTime - offsetSeconds)

        if lines.contains(where: { $0.time != nil }) {
            var lastMatch: Int? = nil
            for (i, line) in lines.enumerated() {
                if let t = line.time, t <= adjustedTime + 0.15 {
                    lastMatch = i
                }
            }
            return lastMatch ?? 0
        } else {
            let dur = max(duration, 1)
            let ratio = min(max(adjustedTime / dur, 0), 0.999)
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
        if artist != "Unknown Artist" && artist != "Audio Import" && !artist.isEmpty {
            query = "\(artist) \(cleanTitle)"
        }

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lrclib.net/api/search?q=\(encoded)") else {
            return nil
        }

        do {
            var req = URLRequest(url: url)
            req.setValue("MusiQ iOS Player v2.5", forHTTPHeaderField: "User-Agent")
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

// MARK: - High-Performance Audio Engine (Sample-Rate Safe & Interruption Proof)
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
    @Published var currentTrackLyricOffset: Double = 0.0
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

    private let playlistsStorageKey = "MusiQ_User_Playlists_v2"
    private let listeningStatsKey = "MusiQ_Listening_Seconds_v2"

    var currentTrack: Track? {
        guard currentIndex >= 0 && currentIndex < currentQueue.count else { return nil }
        return currentQueue[currentIndex]
    }

    init() {
        configureAudioSession()
        setupEngineGraph()
        registerAudioInterruptionObservers()
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

    // MARK: - Fix for PiP / Background App Audio Interruption Desync
    private func registerAudioInterruptionObservers() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let typeVal = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }

            switch type {
            case .began:
                // External video/PiP/call took over audio: immediately sync UI to paused state!
                self.captureCurrentPlaybackPosition()
                self.playerNode.pause()
                self.isPlaying = false
                self.stopProgressTimer()
                self.saveListeningStats()
                self.updateNowPlayingInfo()

            case .ended:
                let optionsVal = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsVal)
                if options.contains(.shouldResume) {
                    self.resumeAfterInterruption()
                }
            @unknown default:
                break
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let reasonVal = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal) else { return }

            if reason == .oldDeviceUnavailable {
                self.captureCurrentPlaybackPosition()
                self.playerNode.pause()
                self.isPlaying = false
                self.stopProgressTimer()
                self.updateNowPlayingInfo()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // If hardware sample rate or route changed while backgrounded, sync state cleanly
            if !self.engine.isRunning && self.isPlaying {
                self.captureCurrentPlaybackPosition()
                self.isPlaying = false
                self.stopProgressTimer()
                self.updateNowPlayingInfo()
            }
        }
    }

    private func captureCurrentPlaybackPosition() {
        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
            let currentFrame = seekFrameOffset + playerTime.sampleTime
            let clamped = max(0, min(currentFrame, totalFrames - 100))
            seekFrameOffset = clamped
            progress.currentTime = Double(clamped) / max(sampleRate, 1)
        }
    }

    private func resumeAfterInterruption() {
        try? AVAudioSession.sharedInstance().setActive(true)
        seek(to: progress.currentTime)
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
        isPlaying = true
        startProgressTimer()
        updateNowPlayingInfo()
    }

    // MARK: - Live Synced Lyrics & Offset Loader
    func reloadLyricsForCurrentTrack() {
        guard let track = currentTrack else {
            currentTrackLyrics = []
            currentTrackLyricOffset = 0
            return
        }
        currentTrackLyricOffset = LyricsManager.shared.getOffset(for: track.fileName)
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

    func adjustLyricOffset(by delta: Double) {
        guard let track = currentTrack else { return }
        if delta == 0 {
            currentTrackLyricOffset = 0
        } else {
            currentTrackLyricOffset = (currentTrackLyricOffset + delta * 10).rounded() / 10
        }
        LyricsManager.shared.saveOffset(currentTrackLyricOffset, for: track.fileName)
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

    func updatePlaylistDetails(id: UUID, newName: String, customCover: UIImage?) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            playlists[idx].name = trimmed
        }
        if let cover = customCover {
            ArtworkCache.shared.setPlaylistCover(cover, for: id)
            playlists[idx].hasCustomCover = true
        }
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

    // MARK: - Sample-Rate Matched Scheduling (Fixes 48kHz / 44.1kHz Pitch & Slowdown Bug!)
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
            try AVAudioSession.sharedInstance().setActive(true)
            let file = try AVAudioFile(forReading: track.fileURL)
            activeAudioFile = file
            let fileFormat = file.processingFormat
            sampleRate = fileFormat.sampleRate
            totalFrames = file.length
            seekFrameOffset = max(0, min(startFrame, totalFrames))

            let remainingFrames = AVAudioFrameCount(max(0, totalFrames - seekFrameOffset))
            guard remainingFrames > 0 else {
                playbackErrorMessage = "Audio file is empty or corrupted."
                return
            }

            progress.duration = max(1, Double(totalFrames) / sampleRate)
            progress.currentTime = Double(seekFrameOffset) / sampleRate

            // Connect the entire DSP chain using the file's exact sample rate & channel layout
            // so mainMixerNode handles 48kHz -> 44.1kHz conversion without pitching down!
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitchNode)
            engine.disconnectNodeOutput(eqNode)

            engine.connect(playerNode, to: timePitchNode, format: fileFormat)
            engine.connect(timePitchNode, to: eqNode, format: fileFormat)
            engine.connect(eqNode, to: engine.mainMixerNode, format: fileFormat)

            timePitchNode.pitch = pitchCents
            timePitchNode.rate = playbackRate

            if !engine.isRunning {
                engine.prepare()
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
            playbackErrorMessage = "Corrupted audio format. Delete & re-import this track."
            print("Playback load error: \(error)")
        }
    }

    func togglePlayPause() {
        if activeAudioFile == nil, let current = currentTrack ?? allTracks.first {
            playTrack(current, in: currentQueue.isEmpty ? allTracks : currentQueue)
            return
        }

        // If engine stopped in background due to PiP/System interruption, treat as paused and resume cleanly
        if isPlaying && (!engine.isRunning || !playerNode.isPlaying) {
            isPlaying = false
        }

        if isPlaying {
            captureCurrentPlaybackPosition()
            playerNode.pause()
            isPlaying = false
            stopProgressTimer()
            saveListeningStats()
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try? engine.start()
                seek(to: progress.currentTime)
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

        if !engine.isRunning {
            try? engine.start()
        }

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

            // Auto-detect if iOS paused the engine externally without firing an interruption
            if !self.engine.isRunning || !self.playerNode.isPlaying {
                self.isPlaying = false
                self.stopProgressTimer()
                self.updateNowPlayingInfo()
                return
            }

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
            guard let self = self else { return .commandFailed }
            if !self.isPlaying { self.togglePlayPause() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying { self.togglePlayPause() }
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

// MARK: - Polished In-Player Synced Lyric Line (Balanced Between Artist & Scrubber)
struct PolishedInlineLyricView: View {
    @ObservedObject var progress: PlaybackProgressObserver
    let lines: [LyricLine]
    let offsetSeconds: Double
    let isFetching: Bool
    let onTap: () -> Void

    private var activeIndex: Int? {
        LyricsManager.activeLineIndex(
            in: lines,
            currentTime: progress.currentTime,
            duration: progress.duration,
            offsetSeconds: offsetSeconds
        )
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let idx = activeIndex {
                    let currentLine = lines[idx].text
                    Text(currentLine)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .id("inline_lyric_\(idx)")
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            )
                        )
                        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: idx)
                } else if isFetching {
                    Text("Syncing lyrics...")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 11))
                        Text("Tap for lyrics")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.32))
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Apple Music-Style Blurred Scrolling Lyrics Sheet + Intro Sync Offset Calibration
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
            duration: progress.duration,
            offsetSeconds: engine.currentTrackLyricOffset
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

            Color.black.opacity(0.30)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 12)

                // Compact Top Header
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

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.68))
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
                .padding(.bottom, 10)

                // Per-Song Intro Timing Offset Calibrator (Fixes Video Intro Delays like Through The Wire!)
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))

                    Text(offsetLabel)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundColor(.white.opacity(0.88))

                    Spacer()

                    Button {
                        engine.adjustLyricOffset(by: -0.5)
                    } label: {
                        Text("-0.5s")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundColor(.white)
                    }

                    if abs(engine.currentTrackLyricOffset) > 0.05 {
                        Button {
                            engine.adjustLyricOffset(by: 0)
                        } label: {
                            Text("Reset")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.purple.opacity(0.55))
                                .clipShape(Capsule())
                                .foregroundColor(.white)
                        }
                    }

                    Button {
                        engine.adjustLyricOffset(by: 0.5)
                    } label: {
                        Text("+0.5s")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

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
                                VStack(alignment: .leading, spacing: 24) {
                                    Spacer().frame(height: 20)

                                    ForEach(engine.currentTrackLyrics) { line in
                                        let currentIdx = activeIndex ?? 0
                                        let isCurrent = (line.index == currentIdx)
                                        let distance = abs(line.index - currentIdx)

                                        Button {
                                            if let t = line.time {
                                                let seekTarget = max(0, t + engine.currentTrackLyricOffset)
                                                engine.seek(to: seekTarget)
                                            }
                                        } label: {
                                            Text(line.text)
                                                .font(.system(size: isCurrent ? 29 : 25, weight: .bold, design: .rounded))
                                                .foregroundColor(.white.opacity(isCurrent ? 1.0 : max(0.22, 0.50 - Double(distance) * 0.08)))
                                                .blur(radius: isCurrent ? 0 : min(CGFloat(distance) * 1.35, 4.8))
                                                .scaleEffect(isCurrent ? 1.0 : 0.96, anchor: .leading)
                                                .multilineTextAlignment(.leading)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .animation(.spring(response: 0.36, dampingFraction: 0.84), value: currentIdx)
                                        }
                                        .buttonStyle(.plain)
                                        .id(line.index)
                                    }

                                    Spacer().frame(height: 150)
                                }
                                .padding(.horizontal, 26)
                            }
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: .black, location: 0.07),
                                        .init(color: .black, location: 0.89),
                                        .init(color: .clear, location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .onAppear {
                                if let idx = activeIndex {
                                    proxy.scrollTo(idx, anchor: UnitPoint(x: 0.5, y: 0.28))
                                }
                            }
                            .onChange(of: activeIndex) { newIdx in
                                guard let idx = newIdx else { return }
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                                    proxy.scrollTo(idx, anchor: UnitPoint(x: 0.5, y: 0.28))
                                }
                            }
                        }
                    }

                    // Bottom Playback Controls Inside Lyrics Sheet
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

    private var offsetLabel: String {
        let val = engine.currentTrackLyricOffset
        if abs(val) < 0.05 {
            return "Intro Sync: 0.0s"
        } else if val > 0 {
            return String(format: "Intro Delay: +%.1fs", val)
        } else {
            return String(format: "Intro Early: %.1fs", val)
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

// MARK: - Playlist Cover View (Supports Custom Photo OR 2x2 Album Art Collage!)
struct PlaylistArtworkThumbnailView: View {
    let playlist: Playlist
    let tracks: [Track]
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        if let customImg = ArtworkCache.shared.playlistCover(for: playlist.id) {
            Image(uiImage: customImg)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            let covers = tracks.compactMap { ArtworkCache.shared.artwork(for: $0.fileName) }
            if covers.count >= 4 {
                // Spotify-Style 2x2 Album Art Grid Collage
                let half = size / 2.0
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Image(uiImage: covers[0]).resizable().scaledToFill().frame(width: half, height: half).clipped()
                        Image(uiImage: covers[1]).resizable().scaledToFill().frame(width: half, height: half).clipped()
                    }
                    HStack(spacing: 0) {
                        Image(uiImage: covers[2]).resizable().scaledToFill().frame(width: half, height: half).clipped()
                        Image(uiImage: covers[3]).resizable().scaledToFill().frame(width: half, height: half).clipped()
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else if let first = covers.first {
                Image(uiImage: first)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(LinearGradient(colors: [.purple.opacity(0.75), .indigo.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: size, height: size)
                    Image(systemName: "music.note.list")
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
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

                DirectAudioImporterView(engine: engine)
                    .tabItem {
                        Label("Audio URL", systemImage: "arrow.down.circle.fill")
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
                        Text("Playlists are only created when you make them.\nTap '+' to build a custom playlist with custom cover art.")
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
                            let pTracks = engine.tracks(for: playlist)
                            NavigationLink(destination: PlaylistDetailView(engine: engine, playlistID: playlist.id, showFullPlayer: $showFullPlayer)) {
                                HStack(spacing: 14) {
                                    PlaylistArtworkThumbnailView(
                                        playlist: playlist,
                                        tracks: pTracks,
                                        size: 56,
                                        cornerRadius: 10
                                    )
                                    .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.name)
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        Text("\(pTracks.count) songs")
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

// MARK: - Spotify-Inspired Playlist Detail View (Custom Art Header, Duration, Play/Shuffle & Search)
struct PlaylistDetailView: View {
    @ObservedObject var engine: MusiQEngine
    let playlistID: UUID
    @Binding var showFullPlayer: Bool

    @State private var showSongPicker = false
    @State private var showEditPlaylistSheet = false
    @State private var searchText = ""

    var playlist: Playlist? {
        engine.playlists.first(where: { $0.id == playlistID })
    }

    private var headerGradientColors: [Color] {
        if let customImg = ArtworkCache.shared.playlistCover(for: playlistID) {
            return customImg.extractPlayerGradientColors()
        }
        if let firstTrack = playlist.flatMap({ engine.tracks(for: $0).first }) {
            return ArtworkCache.shared.playerGradient(for: firstTrack.fileName)
        }
        return [Color.purple.opacity(0.55), Color(red: 0.08, green: 0.06, blue: 0.14), Color(red: 0.06, green: 0.06, blue: 0.08)]
    }

    var body: some View {
        let allPlaylistTracks = playlist.map { engine.tracks(for: $0) } ?? []
        let tracks = searchText.isEmpty ? allPlaylistTracks : allPlaylistTracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText)
        }
        let totalMinutes = Int(allPlaylistTracks.reduce(0) { $0 + $1.duration } / 60.0)

        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

            List {
                // Hero Header Section (Spotify-Inspired Cover + Metadata + Action Row)
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .bottom, spacing: 18) {
                            if let p = playlist {
                                PlaylistArtworkThumbnailView(
                                    playlist: p,
                                    tracks: allPlaylistTracks,
                                    size: 118,
                                    cornerRadius: 12
                                )
                                .shadow(color: .black.opacity(0.55), radius: 12, x: 0, y: 6)
                                .onTapGesture {
                                    showEditPlaylistSheet = true
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("CUSTOM PLAYLIST")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white.opacity(0.65))

                                Text(playlist?.name ?? "Playlist")
                                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                                    .lineLimit(2)

                                Text("\(allPlaylistTracks.count) songs • \(totalMinutes) min")
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                            Spacer()
                        }

                        // Action Buttons Row (Add Songs, Edit Cover & Name, Shuffle, Big Play Button)
                        HStack(spacing: 12) {
                            Button {
                                showSongPicker = true
                            } label: {
                                Label("Add", systemImage: "plus")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.14))
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            Button {
                                showEditPlaylistSheet = true
                            } label: {
                                Label("Cover & Name", systemImage: "pencil")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.14))
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button {
                                guard !allPlaylistTracks.isEmpty else { return }
                                engine.isShuffle = true
                                if let randomTrack = allPlaylistTracks.randomElement() {
                                    engine.playTrack(randomTrack, in: allPlaylistTracks)
                                    showFullPlayer = true
                                }
                            } label: {
                                Image(systemName: "shuffle")
                                    .font(.title3.weight(.semibold))
                                    .foregroundColor(engine.isShuffle ? .purple : .white.opacity(0.8))
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(.plain)

                            Button {
                                guard let first = allPlaylistTracks.first else { return }
                                engine.playTrack(first, in: allPlaylistTracks)
                                showFullPlayer = true
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.purple)
                                        .frame(width: 50, height: 50)
                                        .shadow(color: .purple.opacity(0.45), radius: 8, x: 0, y: 4)
                                    Image(systemName: "play.fill")
                                        .font(.title3.weight(.bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(
                        LinearGradient(
                            colors: [headerGradientColors.first ?? .purple.opacity(0.4), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }

                // Tracks Section
                Section {
                    if tracks.isEmpty {
                        VStack(spacing: 10) {
                            Text("No songs in this playlist yet.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button("Tap '+ Add' above to pick songs") {
                                showSongPicker = true
                            }
                            .font(.caption.weight(.bold))
                            .foregroundColor(.purple)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                            TrackRowView(indexNumber: idx + 1, track: track) {
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
                }
            }
            .scrollContentBackground(.hidden)
            .searchable(text: $searchText, prompt: "Search in playlist...")
            .padding(.bottom, engine.currentTrack != nil ? 70 : 0)
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
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
                                        Text("\(track.artist) • \(track.formattedDuration)")
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
        .sheet(isPresented: $showEditPlaylistSheet) {
            if let p = playlist {
                PlaylistEditorSheet(engine: engine, playlist: p)
            }
        }
    }
}

// MARK: - Custom Playlist Cover & Name Editor Sheet
struct PlaylistEditorSheet: View {
    @ObservedObject var engine: MusiQEngine
    let playlist: Playlist

    @State private var editedName: String = ""
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var previewCover: UIImage? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Custom Playlist Cover Art") {
                    HStack {
                        Spacer()
                        if let img = previewCover {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            PlaylistArtworkThumbnailView(
                                playlist: playlist,
                                tracks: engine.tracks(for: playlist),
                                size: 120,
                                cornerRadius: 14
                            )
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Choose Custom Playlist Cover", systemImage: "photo.on.rectangle.angled")
                    }
                    .onChange(of: selectedPhoto) { newItem in
                        guard let newItem = newItem else { return }
                        Task {
                            if let data = try? await newItem.loadTransferable(type: Data.self),
                               let uiImg = UIImage(data: data) {
                                await MainActor.run {
                                    previewCover = uiImg.autoCroppedToSquare()
                                }
                            }
                        }
                    }
                }

                Section("Playlist Name") {
                    TextField("Playlist Name", text: $editedName)
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        engine.updatePlaylistDetails(
                            id: playlist.id,
                            newName: editedName,
                            customCover: previewCover
                        )
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                editedName = playlist.name
                previewCover = ArtworkCache.shared.playlistCover(for: playlist.id)
            }
        }
    }
}

// MARK: - Tab 2: Global Searchable Songs & Artists Library
struct AllSongsSearchView: View {
    @ObservedObject var engine: MusiQEngine
    @Binding var showFullPlayer: Bool
    @State private var searchText: String = ""
    @State private var browseMode: BrowseMode = .songs
    @State private var showFileImporter: Bool = false
    @State private var trackToTag: Track? = nil

    enum BrowseMode: String, CaseIterable {
        case songs = "Songs"
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
        let grouped = Dictionary(grouping: filteredTracks) { $0.artist }
        return grouped.map { (artist: $0.key, tracks: $0.value) }
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
                                    TrackRowView(indexNumber: nil, track: track) {
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
                            // Browse By Artist View
                            List {
                                ForEach(groupedArtists, id: \.artist) { group in
                                    NavigationLink(destination: ArtistDetailSongsView(engine: engine, artistName: group.artist, tracks: group.tracks, showFullPlayer: $showFullPlayer)) {
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
                                                Text("\(group.tracks.count) songs")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.vertical, 3)
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

struct ArtistDetailSongsView: View {
    @ObservedObject var engine: MusiQEngine
    let artistName: String
    let tracks: [Track]
    @Binding var showFullPlayer: Bool

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()
            List(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                TrackRowView(indexNumber: idx + 1, track: track) {
                    engine.playTrack(track, in: tracks)
                    showFullPlayer = true
                }
                .listRowBackground(Color.white.opacity(0.04))
            }
            .scrollContentBackground(.hidden)
            .padding(.bottom, engine.currentTrack != nil ? 70 : 0)
        }
        .navigationTitle(artistName)
    }
}

// MARK: - Track Row View (Displays Artist + Song Duration Instead of Listen Time!)
struct TrackRowView: View {
    let indexNumber: Int?
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let num = indexNumber {
                    Text("\(num)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, alignment: .center)
                }

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
                        Text(track.formattedDuration)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
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
            let artBoxSize = min(safeWidth - 100, 236)

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
                    .frame(width: safeWidth - 24, height: artBoxSize + 18)
                    .clipped()

                    if let err = engine.playbackErrorMessage {
                        Text(err)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }

                    // Song Title + Artist
                    VStack(spacing: 3) {
                        LoopingMarqueeText(
                            text: engine.currentTrack?.title ?? "No Track Selected",
                            font: .system(size: 22, weight: .bold),
                            textColor: .white
                        )
                        .frame(width: safeWidth - 48)

                        Text(engine.currentTrack?.artist ?? "MusiQ Local Library")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 24)

                    // Polished Single-Line Synced Lyric Display (Between Artist & Scrubber)
                    PolishedInlineLyricView(
                        progress: engine.progress,
                        lines: engine.currentTrackLyrics,
                        offsetSeconds: engine.currentTrackLyricOffset,
                        isFetching: engine.isFetchingLyricsInBackground
                    ) {
                        activeBottomSheet = .lyrics
                    }
                    .padding(.horizontal, 20)

                    // Isolated Scrubber + Timers
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .foregroundColor(idx == engine.currentIndex ? .purple : .white)
                                .fontWeight(idx == engine.currentIndex ? .bold : .regular)
                            Text("\(track.artist) • \(track.formattedDuration)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
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

// MARK: - Tab 3: Direct & Cloud Audio URL Importer (.mp3, .m4a, .wav, Dropbox, Google Drive)
struct DirectAudioImporterView: View {
    @ObservedObject var engine: MusiQEngine
    @State private var urlInput: String = ""
    @State private var customTitle: String = ""
    @State private var customArtist: String = ""
    @State private var statusMessage: String = "Paste a direct audio URL (.mp3, .m4a, .wav) or Dropbox / Google Drive audio share link."
    @State private var isDownloading: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Audio File or Cloud Share Link") {
                    HStack {
                        TextField("https://example.com/song.mp3", text: $urlInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if let clip = UIPasteboard.general.string, !clip.isEmpty {
                            Button("Paste") {
                                urlInput = clip
                            }
                            .font(.caption.weight(.bold))
                            .buttonStyle(.bordered)
                            .tint(.purple)
                        }
                    }
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
            .navigationTitle("Audio URL Importer")
        }
    }

    private func normalizeCloudAudioURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Automatically convert Dropbox share links to direct download streams
        if s.contains("dropbox.com") {
            s = s.replacingOccurrences(of: "?dl=0", with: "?dl=1")
            if !s.contains("dl=1") {
                s += (s.contains("?") ? "&dl=1" : "?dl=1")
            }
        }
        // Automatically convert Google Drive file links to direct download streams
        if s.contains("drive.google.com/file/d/") {
            let parts = s.components(separatedBy: "/file/d/")
            if parts.count > 1, let fileID = parts[1].components(separatedBy: "/").first {
                s = "https://drive.google.com/uc?export=download&id=\(fileID)"
            }
        }
        return URL(string: s)
    }

    private func startDirectDownload() {
        guard let targetURL = normalizeCloudAudioURL(urlInput) else {
            statusMessage = "Invalid URL format."
            return
        }

        isDownloading = true
        statusMessage = "Downloading audio stream..."

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
                    resolvedTitle = response.suggestedFilename?.replacingOccurrences(of: ".\(ext)", with: "")
                        ?? targetURL.deletingPathExtension().lastPathComponent
                }
                if resolvedTitle.isEmpty || resolvedTitle == "uc" {
                    resolvedTitle = "Track_\(Int(Date().timeIntervalSince1970))"
                }

                var resolvedArtist = customArtist.trimmingCharacters(in: .whitespacesAndNewlines)
                if resolvedArtist.isEmpty {
                    resolvedArtist = "Audio Import"
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
                        NSLocalizedDescriptionKey: "URL did not point to a valid direct audio file. Use the Files importer in the Songs tab for local files."
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
