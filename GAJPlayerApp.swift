import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
import UniformTypeIdentifiers
import PhotosUI
import CoreMotion
import Network
import AudioToolbox
#if canImport(ActivityKit)
import ActivityKit
#endif

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

// MARK: - ActivityKit Live Activity Attributes (For Supported Provisioning Profiles)
#if canImport(ActivityKit)
@available(iOS 16.2, *)
struct MusiQNowPlayingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var currentTime: Double
        var duration: Double
    }
    var sessionName: String
}
#endif

// MARK: - Local Wi-Fi Browser Drag-and-Drop Upload Server (Apple Network Framework)
final class WiFiTransferServer: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var serverURLString: String = ""
    @Published var uploadedFilesCount: Int = 0
    @Published var lastUploadedName: String = ""

    private var listener: NWListener?
    private let port: UInt16 = 8080
    var onFileSaved: (() -> Void)?

    func toggleServer() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let newListener = try NWListener(using: params, on: nwPort)

            newListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        let ip = Self.localWiFiIPAddress() ?? "localhost"
                        self.serverURLString = "http://\(ip):\(self.port)"
                    case .failed, .cancelled:
                        self.isRunning = false
                        self.serverURLString = ""
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            newListener.start(queue: .global(qos: .userInitiated))
            listener = newListener
        } catch {
            print("WiFi Server start error: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        serverURLString = ""
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var accumulated = Data()

        func readNextChunk() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
                guard let self = self else {
                    connection.cancel()
                    return
                }
                if let chunk = data, !chunk.isEmpty {
                    accumulated.append(chunk)
                }

                // Check if full HTTP request has arrived via Content-Length header
                if let headerEndRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = accumulated.subdata(in: 0..<headerEndRange.lowerBound)
                    let headerStr = String(data: headerData, encoding: .utf8) ?? ""
                    let firstLine = headerStr.components(separatedBy: "\r\n").first ?? ""

                    if firstLine.hasPrefix("GET ") {
                        self.sendHTMLResponse(on: connection)
                        return
                    } else if firstLine.hasPrefix("POST ") {
                        let contentLength = Self.parseContentLength(from: headerStr)
                        let bodyStart = headerEndRange.upperBound
                        let currentBodyBytes = accumulated.count - bodyStart
                        if currentBodyBytes >= contentLength {
                            let bodyData = accumulated.subdata(in: bodyStart..<(bodyStart + contentLength))
                            let rawFileName = Self.parseHeaderValue(key: "X-File-Name", from: headerStr) ?? "Track_\(Int(Date().timeIntervalSince1970)).mp3"
                            let decodedName = rawFileName.removingPercentEncoding ?? rawFileName
                            self.saveUploadedFile(name: decodedName, data: bodyData)
                            self.sendJSONSuccess(on: connection, fileName: decodedName)
                            return
                        }
                    }
                }

                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    readNextChunk()
                }
            }
        }

        readNextChunk()
    }

    private func saveUploadedFile(name: String, data: Data) {
        guard data.count > 4096 else { return }
        let safeName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent(safeName)
        try? FileManager.default.removeItem(at: dest)
        try? data.write(to: dest)

        DispatchQueue.main.async {
            self.uploadedFilesCount += 1
            self.lastUploadedName = safeName
            self.onFileSaved?()
        }
    }

    private func sendHTMLResponse(on connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>MusiQ Wi-Fi Transfer</title>
        <style>
            body { background: #0d0d12; color: #fff; font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 92vh; margin: 0; }
            .card { background: #181822; border: 2px dashed #9b59b6; border-radius: 22px; padding: 48px 36px; text-align: center; max-width: 460px; width: 85%; transition: 0.2s; cursor: pointer; }
            .card.dragover { background: #261b36; border-color: #d28eff; transform: scale(1.02); }
            h1 { margin: 0 0 8px 0; font-size: 26px; }
            p { color: #9a9aa6; font-size: 14px; margin-bottom: 24px; }
            .btn { background: #9b59b6; color: #fff; padding: 12px 26px; border-radius: 99px; font-weight: 700; display: inline-block; }
            #list { margin-top: 24px; text-align: left; font-size: 13px; color: #b8b8c4; max-height: 200px; overflow-y: auto; }
            .ok { color: #2ecc71; font-weight: 600; }
        </style>
        </head>
        <body>
            <div class="card" id="dropzone" onclick="document.getElementById('fileInput').click()">
                <h1>🎵 MusiQ Wi-Fi Drop</h1>
                <p>Drag & drop .mp3, .m4a, .wav, or .flac files here, or click to browse.</p>
                <div class="btn">Select Audio Files</div>
                <input type="file" id="fileInput" multiple accept=".mp3,.m4a,.wav,.flac,.aac" style="display:none">
                <div id="list"></div>
            </div>
            <script>
                const zone = document.getElementById('dropzone');
                const input = document.getElementById('fileInput');
                const list = document.getElementById('list');
                zone.addEventListener('dragover', e => { e.preventDefault(); zone.classList.add('dragover'); });
                zone.addEventListener('dragleave', () => zone.classList.remove('dragover'));
                zone.addEventListener('drop', e => {
                    e.preventDefault();
                    zone.classList.remove('dragover');
                    handleFiles(e.dataTransfer.files);
                });
                input.addEventListener('change', e => handleFiles(e.target.files));
                async function handleFiles(files) {
                    for (const file of files) {
                        const row = document.createElement('div');
                        row.textContent = '⏳ Uploading ' + file.name + '...';
                        list.prepend(row);
                        try {
                            const buf = await file.arrayBuffer();
                            const res = await fetch('/upload', {
                                method: 'POST',
                                headers: { 'X-File-Name': encodeURIComponent(file.name), 'Content-Type': 'application/octet-stream' },
                                body: buf
                            });
                            if (res.ok) {
                                row.innerHTML = '<span class="ok">✅ Saved to MusiQ:</span> ' + file.name;
                            } else {
                                row.textContent = '❌ Failed: ' + file.name;
                            }
                        } catch (err) {
                            row.textContent = '❌ Error: ' + file.name;
                        }
                    }
                }
            </script>
        </body>
        </html>
        """
        let body = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendJSONSuccess(on connection: NWConnection, fileName: String) {
        let json = "{\"status\":\"ok\",\"file\":\"\(fileName)\"}"
        let body = Data(json.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseContentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(val) ?? 0
            }
        }
        return 0
    }

    private static func parseHeaderValue(key: String, from headers: String) -> String? {
        let prefix = key.lowercased() + ":"
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix(prefix) {
                return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func localWiFiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    if name == "en0" { break }
                }
            }
        }
        return address
    }
}

// MARK: - Subtle Gyroscope Parallax Manager
final class MotionTiltManager: ObservableObject {
    @Published var pitch: Double = 0
    @Published var roll: Double = 0
    private let manager = CMMotionManager()

    init() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let attitude = data?.attitude else { return }
            let targetPitch = max(-4.8, min(4.8, attitude.pitch * 5.8))
            let targetRoll = max(-4.8, min(4.8, attitude.roll * 5.8))
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.85)) {
                self.pitch = targetPitch
                self.roll = targetRoll
            }
        }
    }

    deinit {
        manager.stopDeviceMotionUpdates()
    }
}

// MARK: - Native iOS Audio Output Route Picker ("Source" Button)
struct AudioSourcePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.white.withAlphaComponent(0.85)
        picker.activeTintColor = UIColor.systemPurple
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
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
    let endTime: TimeInterval?
    let text: String
    let words: [String]
}

enum VisualMode: String, CaseIterable {
    case sleeve = "Sleeve"
    case cassette = "Cassette"
    case sideVinyl = "Side Vinyl"

    var icon: String {
        switch self {
        case .sleeve: return "square.fill"
        case .cassette: return "recordingtape"
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

// MARK: - Image Auto-Cropper & Multi-Zone Color Palette Extractor
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

    func extractCassetteZonePalette() -> [Color] {
        guard let cgImage = self.cgImage else {
            return [
                Color(white: 0.92),
                Color(red: 0.85, green: 0.65, blue: 0.20),
                Color(red: 0.55, green: 0.35, blue: 0.14),
                Color(red: 0.85, green: 0.65, blue: 0.20),
                Color(white: 0.92)
            ]
        }

        let grid = 24
        let bytesPerPixel = 4
        var raw = [UInt8](repeating: 0, count: grid * grid * bytesPerPixel)

        guard let ctx = CGContext(
            data: &raw,
            width: grid,
            height: grid,
            bitsPerComponent: 8,
            bytesPerRow: grid * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return [.white, .yellow, .orange, .yellow, .white]
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: grid, height: grid))

        func averageColorInColumns(_ xRange: Range<Int>, yRange: Range<Int>, boostSaturation: Bool) -> Color {
            var rSum: CGFloat = 0, gSum: CGFloat = 0, bSum: CGFloat = 0, wSum: CGFloat = 0
            for y in yRange {
                for x in xRange {
                    let i = (y * grid + x) * bytesPerPixel
                    let r = CGFloat(raw[i]) / 255.0
                    let g = CGFloat(raw[i + 1]) / 255.0
                    let b = CGFloat(raw[i + 2]) / 255.0

                    let maxC = max(r, max(g, b))
                    let minC = min(r, min(g, b))
                    let sat = maxC > 0 ? (maxC - minC) / maxC : 0
                    let weight: CGFloat = boostSaturation ? (0.25 + sat * 2.5) : 1.0

                    rSum += r * weight
                    gSum += g * weight
                    bSum += b * weight
                    wSum += weight
                }
            }
            guard wSum > 0 else { return .purple }
            let uiCol = UIColor(red: rSum / wSum, green: gSum / wSum, blue: bSum / wSum, alpha: 1.0)
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            if uiCol.getHue(&h, saturation: &s, brightness: &br, alpha: &a) {
                if s > 0.14 && boostSaturation {
                    return Color(UIColor(hue: h, saturation: min(s * 1.45, 0.96), brightness: min(max(br * 1.08, 0.28), 0.94), alpha: 1.0))
                }
                return Color(UIColor(hue: h, saturation: s, brightness: min(max(br, 0.18), 0.96), alpha: 1.0))
            }
            return Color(uiCol)
        }

        let leftOuter = averageColorInColumns(0..<4, yRange: 2..<22, boostSaturation: false)
        let leftMid = averageColorInColumns(4..<9, yRange: 3..<21, boostSaturation: true)
        let centerCore = averageColorInColumns(9..<15, yRange: 5..<19, boostSaturation: true)
        let rightMid = averageColorInColumns(15..<20, yRange: 3..<21, boostSaturation: true)
        let rightOuter = averageColorInColumns(20..<24, yRange: 2..<22, boostSaturation: false)

        return [leftOuter, leftMid, centerCore, rightMid, rightOuter]
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
            targetBrightness: 0.48
        )
        let c2 = Self.tunedBackgroundUIColor(
            r: botWeight > 0 ? botR / botWeight : 0.1,
            g: botWeight > 0 ? botG / botWeight : 0.08,
            b: botWeight > 0 ? botB / botWeight : 0.18,
            targetBrightness: 0.24
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

// MARK: - Fast Artwork, Multi-Color Cassette Palette & Custom Tag Cache
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    private var gradientCache: [String: [Color]] = [:]
    private var cassetteZoneCache: [String: [Color]] = [:]
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
            cassetteZoneCache[fileName] = squared.extractCassetteZonePalette()
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
                    cassetteZoneCache[fileName] = squared.extractCassetteZonePalette()
                    return squared
                }
            }
        }
        return nil
    }

    func cassettePalette(for fileName: String?) -> [Color] {
        let fallback: [Color] = [
            Color(white: 0.92),
            Color(red: 0.88, green: 0.66, blue: 0.22),
            Color(red: 0.58, green: 0.36, blue: 0.15),
            Color(red: 0.88, green: 0.66, blue: 0.22),
            Color(white: 0.92)
        ]
        guard let fileName = fileName else { return fallback }
        if let cached = cassetteZoneCache[fileName] {
            return cached
        }
        if let img = artwork(for: fileName) {
            let zones = img.extractCassetteZonePalette()
            cassetteZoneCache[fileName] = zones
            return zones
        }
        return fallback
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
        cassetteZoneCache[fileName] = squared.extractCassetteZonePalette()
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

// MARK: - Strict Version-Aware Lyrics Engine
final class LyricsManager {
    static let shared = LyricsManager()
    private let storageKey = "MusiQ_Saved_Lyrics_v6"
    private let matchedDurationKey = "MusiQ_Lyrics_MatchedDur_v6"

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

    func getSavedMatchedDuration(for fileName: String) -> Double? {
        let dict = (UserDefaults.standard.dictionary(forKey: matchedDurationKey) as? [String: Double]) ?? [:]
        return dict[fileName]
    }

    func saveLyrics(_ text: String, matchedDuration: Double?, for track: Track) {
        var dict = (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        dict[track.fileName] = text
        UserDefaults.standard.set(dict, forKey: storageKey)

        if let mDur = matchedDuration {
            var durDict = (UserDefaults.standard.dictionary(forKey: matchedDurationKey) as? [String: Double]) ?? [:]
            durDict[track.fileName] = mDur
            UserDefaults.standard.set(durDict, forKey: matchedDurationKey)
        }
    }

    func parseLyrics(_ raw: String, trackDuration: Double) -> [LyricLine] {
        let rawLines = raw.components(separatedBy: .newlines)
        var temp: [(time: TimeInterval?, text: String)] = []

        let pattern = #"\[(\d{1,2}):(\d{2})(?:[\.:](\d{1,3}))?\](.*)"#
        let regex = try? NSRegularExpression(pattern: pattern)

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
                    temp.append((time: timestamp, text: lyricText))
                }
            } else if !trimmed.hasPrefix("[ti:") && !trimmed.hasPrefix("[ar:") && !trimmed.hasPrefix("[al:") && !trimmed.hasPrefix("[by:") && !trimmed.hasPrefix("[length:") && !trimmed.hasPrefix("[offset:") {
                temp.append((time: nil, text: trimmed))
            }
        }

        if temp.contains(where: { $0.time != nil }) {
            temp.sort { ($0.time ?? 0) < ($1.time ?? 0) }
        }

        var finalLines: [LyricLine] = []
        for i in 0..<temp.count {
            let current = temp[i]
            let nextTime: TimeInterval? = (i + 1 < temp.count) ? temp[i + 1].time : max(trackDuration, (current.time ?? 0) + 4.0)
            let words = current.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            finalLines.append(
                LyricLine(
                    index: i,
                    time: current.time,
                    endTime: nextTime,
                    text: current.text,
                    words: words.isEmpty ? [current.text] : words
                )
            )
        }
        return finalLines
    }

    func computeAutoVersionOffset(for track: Track, parsedLines: [LyricLine], lrcSourceDuration: Double?) -> Double {
        guard !parsedLines.isEmpty, parsedLines.first?.time != nil else { return 0.0 }
        guard let srcDur = lrcSourceDuration, srcDur > 30, track.duration > 30 else {
            return 0.0
        }
        let diff = track.duration - srcDur
        if abs(diff) <= 3.0 {
            return 0.0
        }
        if diff > 3.0 && diff <= 60.0 {
            return diff
        }
        return 0.0
    }

    static func activeLineIndex(in lines: [LyricLine], currentTime: Double, duration: Double, autoOffset: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        let adjustedTime = max(0, currentTime - autoOffset)

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

    static func activeWordProgress(in line: LyricLine, currentTime: Double, autoOffset: Double) -> Int {
        guard !line.words.isEmpty else { return 0 }
        let adjusted = max(0, currentTime - autoOffset)
        guard let start = line.time, let end = line.endTime, end > start else {
            return line.words.count
        }
        let span = min(max(0.5, (end - start) * 0.82), 5.5)
        let elapsed = max(0, adjusted - start)
        let progress = min(1.0, elapsed / span)
        return min(line.words.count - 1, Int(progress * Double(line.words.count)))
    }

    func fetchVersionMatchedLyrics(title: String, artist: String, targetDuration: Double) async -> (lyrics: String, matchedDuration: Double?)? {
        let cleanTitle = Self.sanitizeTitle(title)
        guard !cleanTitle.isEmpty else { return nil }
        let primaryArtist = Self.extractPrimaryArtist(artist)

        var queries: [String] = []
        if !primaryArtist.isEmpty {
            queries.append("\(primaryArtist) \(cleanTitle)")
        }
        if !queries.contains(cleanTitle) {
            queries.append(cleanTitle)
        }

        for q in queries {
            if let hit = await queryLRCLIB(
                searchQuery: q,
                cleanTitle: cleanTitle,
                rawArtist: artist,
                primaryArtist: primaryArtist,
                targetDuration: targetDuration
            ) {
                return hit
            }
        }
        return nil
    }

    private func queryLRCLIB(
        searchQuery: String,
        cleanTitle: String,
        rawArtist: String,
        primaryArtist: String,
        targetDuration: Double
    ) async -> (lyrics: String, matchedDuration: Double?)? {
        guard let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lrclib.net/api/search?q=\(encoded)") else {
            return nil
        }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("MusiQ iOS Player v4.5", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !results.isEmpty else {
                return nil
            }

            let targetNormTitle = Self.normalizeAlphanumeric(cleanTitle)
            let targetNormArtist = Self.normalizeAlphanumeric(primaryArtist)
            let rawNormArtist = Self.normalizeAlphanumeric(rawArtist)

            let scored: [(item: [String: Any], score: Double)] = results.compactMap { item in
                let synced = (item["syncedLyrics"] as? String) ?? ""
                let plain = (item["plainLyrics"] as? String) ?? ""
                guard !synced.isEmpty || !plain.isEmpty else { return nil }

                let itemRawTitle = (item["trackName"] as? String) ?? ""
                let itemCleanTitle = Self.sanitizeTitle(itemRawTitle)
                let itemNormTitle = Self.normalizeAlphanumeric(itemCleanTitle)
                let itemNormArtist = Self.normalizeAlphanumeric((item["artistName"] as? String) ?? "")

                guard !itemNormTitle.isEmpty, !targetNormTitle.isEmpty else { return nil }
                let isExactTitle = (itemNormTitle == targetNormTitle)
                let isContainedTitle = (itemNormTitle.count >= 4 && targetNormTitle.count >= 4) &&
                    (itemNormTitle.contains(targetNormTitle) || targetNormTitle.contains(itemNormTitle))

                if !isExactTitle && !isContainedTitle {
                    return nil
                }

                let artistMatches = !targetNormArtist.isEmpty && (
                    itemNormArtist.contains(targetNormArtist) ||
                    targetNormArtist.contains(itemNormArtist) ||
                    rawNormArtist.contains(itemNormArtist)
                )

                let itemDur = (item["duration"] as? Double) ?? 0
                let durDiff = targetDuration > 15 && itemDur > 15 ? abs(itemDur - targetDuration) : 999.0

                if !artistMatches {
                    if !isExactTitle || durDiff > 3.5 {
                        return nil
                    }
                } else {
                    if durDiff > 65.0 {
                        return nil
                    }
                }

                var score: Double = synced.isEmpty ? 20 : 100
                if isExactTitle { score += 60 } else { score += 25 }
                if artistMatches { score += 50 }
                if durDiff < 60 {
                    score += max(0, 65.0 - (durDiff * 4.0))
                }

                return (item, score)
            }

            guard let bestEntry = scored.max(by: { $0.score < $1.score }),
                  bestEntry.score >= 115 else {
                return nil
            }

            let best = bestEntry.item
            let mDur = best["duration"] as? Double
            if let synced = best["syncedLyrics"] as? String, !synced.isEmpty {
                return (synced, mDur)
            }
            if let plain = best["plainLyrics"] as? String, !plain.isEmpty {
                return (plain, mDur)
            }
        } catch {
            print("Lyrics search error: \(error)")
        }
        return nil
    }

    private static func normalizeAlphanumeric(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func sanitizeTitle(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"^\d{1,2}[\.\-\s]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(feat|ft\.|official|video|audio|lyrics|explicit|clean|remaster|version|hq|hd|yedit|edit|v\d+)[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractPrimaryArtist(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Unknown Artist" || trimmed == "Audio Import" {
            return ""
        }
        let separators = ["/", "&", ",", " feat.", " ft.", " featuring ", ";"]
        var primary = trimmed
        for sep in separators {
            if let range = primary.range(of: sep, options: .caseInsensitive) {
                let candidate = String(primary[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.count >= 2 && candidate != "¥$" {
                    primary = candidate
                } else if candidate == "¥$" {
                    let after = String(primary[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !after.isEmpty { primary = after }
                }
            }
        }
        return primary
    }
}

// MARK: - Isolated Playback Time Observer
final class PlaybackProgressObserver: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    var isScrubbing: Bool = false
}

// MARK: - Crash-Proof, Sample-Rate Resampling Audio Engine + Live Activity Sync
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

    @Published var skipTransitionDirection: Int = 1

    @Published var currentTrackLyrics: [LyricLine] = []
    @Published var autoDetectedLyricOffset: Double = 0.0
    @Published var isFetchingLyricsInBackground: Bool = false

    @Published var listenedSecondsByFile: [String: Double] = [:]

    @Published var loopStart: Double? = nil
    @Published var loopEnd: Double? = nil

    let progress = PlaybackProgressObserver()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchNode = AVAudioUnitTimePitch()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 3)

    private let graphFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    private var activeAudioFile: AVAudioFile?
    private var activeConvertedBuffer: AVAudioPCMBuffer?
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

        engine.connect(playerNode, to: timePitchNode, format: graphFormat)
        engine.connect(timePitchNode, to: eqNode, format: graphFormat)
        engine.connect(eqNode, to: engine.mainMixerNode, format: graphFormat)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            print("Engine start error: \(error)")
        }
    }

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
        if !engine.isRunning {
            try? engine.start()
        }
        seek(to: progress.currentTime)
        playerNode.play()
        isPlaying = true
        startProgressTimer()
        updateNowPlayingInfo()
    }

    func reloadLyricsForCurrentTrack(forceOnlineFetch: Bool = false) {
        guard let track = currentTrack else {
            currentTrackLyrics = []
            autoDetectedLyricOffset = 0
            return
        }
        let saved = LyricsManager.shared.getLyrics(for: track)
        if !saved.isEmpty && !forceOnlineFetch {
            let parsed = LyricsManager.shared.parseLyrics(saved, trackDuration: track.duration)
            currentTrackLyrics = parsed
            let savedMatchedDur = LyricsManager.shared.getSavedMatchedDuration(for: track.fileName)
            autoDetectedLyricOffset = LyricsManager.shared.computeAutoVersionOffset(
                for: track,
                parsedLines: parsed,
                lrcSourceDuration: savedMatchedDur
            )
        } else {
            currentTrackLyrics = []
            autoDetectedLyricOffset = 0
            isFetchingLyricsInBackground = true
            let requestedFile = track.fileName
            Task {
                if let result = await LyricsManager.shared.fetchVersionMatchedLyrics(
                    title: track.title,
                    artist: track.artist,
                    targetDuration: track.duration
                ) {
                    LyricsManager.shared.saveLyrics(result.lyrics, matchedDuration: result.matchedDuration, for: track)
                    let parsed = LyricsManager.shared.parseLyrics(result.lyrics, trackDuration: track.duration)
                    let computedOffset = LyricsManager.shared.computeAutoVersionOffset(
                        for: track,
                        parsedLines: parsed,
                        lrcSourceDuration: result.matchedDuration
                    )
                    await MainActor.run {
                        if self.currentTrack?.fileName == requestedFile {
                            self.currentTrackLyrics = parsed
                            self.autoDetectedLyricOffset = computedOffset
                        }
                        self.isFetchingLyricsInBackground = false
                    }
                } else {
                    await MainActor.run {
                        if self.currentTrack?.fileName == requestedFile {
                            self.currentTrackLyrics = []
                        }
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
            activeConvertedBuffer = nil
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
        skipTransitionDirection = 1
        withAnimation(.spring(response: 0.44, dampingFraction: 0.84)) {
            currentQueue = validQueue
            if let idx = currentQueue.firstIndex(where: { $0.fileName == track.fileName }) {
                currentIndex = idx
            } else {
                currentQueue.insert(track, at: 0)
                currentIndex = 0
            }
        }
        loadAndScheduleCurrentTrack(startFrame: 0, autoPlay: true)
    }

    private func loadAndScheduleCurrentTrack(startFrame: AVAudioFramePosition, autoPlay: Bool) {
        guard let track = currentTrack else { return }
        scheduleGeneration += 1
        let currentGen = scheduleGeneration

        playerNode.stop()
        activeAudioFile = nil
        activeConvertedBuffer = nil
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

            let srcFormat = file.processingFormat
            let fileDuration = Double(file.length) / max(srcFormat.sampleRate, 1)
            progress.duration = max(1, fileDuration)

            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }

            if abs(srcFormat.sampleRate - graphFormat.sampleRate) > 1.0 || srcFormat.channelCount != graphFormat.channelCount {
                sampleRate = graphFormat.sampleRate
                if let converted = resampleFileToGraphFormat(file: file) {
                    activeConvertedBuffer = converted
                    totalFrames = AVAudioFramePosition(converted.frameLength)
                    seekFrameOffset = max(0, min(startFrame, totalFrames))
                    scheduleSubBuffer(from: converted, startFrame: seekFrameOffset, generation: currentGen)
                } else {
                    sampleRate = srcFormat.sampleRate
                    totalFrames = file.length
                    seekFrameOffset = max(0, min(startFrame, totalFrames))
                    scheduleFileDirect(file: file, startFrame: seekFrameOffset, generation: currentGen)
                }
            } else {
                sampleRate = srcFormat.sampleRate
                totalFrames = file.length
                seekFrameOffset = max(0, min(startFrame, totalFrames))
                scheduleFileDirect(file: file, startFrame: seekFrameOffset, generation: currentGen)
            }

            progress.currentTime = Double(seekFrameOffset) / sampleRate

            if autoPlay {
                playerNode.play()
                isPlaying = true
                startProgressTimer()
            }
            updateNowPlayingInfo()
            syncLiveActivity()
        } catch {
            isPlaying = false
            stopProgressTimer()
            playbackErrorMessage = "Corrupted audio format. Delete & re-import this track."
            print("Playback load error: \(error)")
        }
    }

    private func resampleFileToGraphFormat(file: AVAudioFile) -> AVAudioPCMBuffer? {
        let srcFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: srcFormat, to: graphFormat) else { return nil }

        let ratio = graphFormat.sampleRate / srcFormat.sampleRate
        let outFrameCap = AVAudioFrameCount(Double(file.length) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: graphFormat, frameCapacity: outFrameCap) else { return nil }

        file.framePosition = 0
        let inputChunk: AVAudioFrameCount = 32768
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: inputChunk) else { return nil }

        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            do {
                try file.read(into: inBuffer, frameCount: inputChunk)
                if inBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }
        return outBuffer.frameLength > 0 ? outBuffer : nil
    }

    private func scheduleSubBuffer(from fullBuffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition, generation: Int) {
        let total = AVAudioFramePosition(fullBuffer.frameLength)
        let clampedStart = max(0, min(startFrame, total - 1))
        let count = AVAudioFrameCount(max(0, total - clampedStart))
        guard count > 0,
              let sub = AVAudioPCMBuffer(pcmFormat: graphFormat, frameCapacity: count) else { return }
        sub.frameLength = count

        let channels = Int(graphFormat.channelCount)
        for ch in 0..<channels {
            if let srcPtr = fullBuffer.floatChannelData?[ch],
               let dstPtr = sub.floatChannelData?[ch] {
                dstPtr.update(from: srcPtr.advanced(by: Int(clampedStart)), count: Int(count))
            }
        }

        playerNode.scheduleBuffer(sub, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.scheduleGeneration == generation else { return }
                if self.isPlaying {
                    self.handleTrackCompletion()
                }
            }
        }
    }

    private func scheduleFileDirect(file: AVAudioFile, startFrame: AVAudioFramePosition, generation: Int) {
        let remainingFrames = AVAudioFrameCount(max(0, file.length - startFrame))
        guard remainingFrames > 0 else { return }
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: remainingFrames,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.scheduleGeneration == generation else { return }
                if self.isPlaying {
                    self.handleTrackCompletion()
                }
            }
        }
    }

    func togglePlayPause() {
        if activeAudioFile == nil, let current = currentTrack ?? allTracks.first {
            playTrack(current, in: currentQueue.isEmpty ? allTracks : currentQueue)
            return
        }

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
        syncLiveActivity()
    }

    func seek(to seconds: Double) {
        guard let file = activeAudioFile else { return }
        let targetFrame = AVAudioFramePosition(seconds * sampleRate)
        let clampedFrame = max(0, min(targetFrame, totalFrames - 100))
        seekFrameOffset = clampedFrame

        scheduleGeneration += 1
        let currentGen = scheduleGeneration

        playerNode.stop()
        if !engine.isRunning {
            try? engine.start()
        }

        if let converted = activeConvertedBuffer {
            scheduleSubBuffer(from: converted, startFrame: clampedFrame, generation: currentGen)
        } else {
            scheduleFileDirect(file: file, startFrame: clampedFrame, generation: currentGen)
        }

        if isPlaying {
            playerNode.play()
        }
        progress.currentTime = seconds
        updateNowPlayingInfo()
        syncLiveActivity()
    }

    func nextTrack() {
        guard !currentQueue.isEmpty else { return }
        skipTransitionDirection = 1
        let nextIdx: Int
        if isShuffle && currentQueue.count > 1 {
            var candidate = Int.random(in: 0..<currentQueue.count)
            if candidate == currentIndex {
                candidate = (currentIndex + 1) % currentQueue.count
            }
            nextIdx = candidate
        } else {
            nextIdx = (currentIndex + 1) % currentQueue.count
        }
        withAnimation(.spring(response: 0.44, dampingFraction: 0.84)) {
            currentIndex = nextIdx
        }
        loadAndScheduleCurrentTrack(startFrame: 0, autoPlay: isPlaying)
    }

    func previousTrack() {
        guard !currentQueue.isEmpty else { return }
        if progress.currentTime > 3.0 {
            seek(to: 0)
            return
        }
        skipTransitionDirection = -1
        let prevIdx = (currentIndex - 1 + currentQueue.count) % currentQueue.count
        withAnimation(.spring(response: 0.44, dampingFraction: 0.84)) {
            currentIndex = prevIdx
        }
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
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying, self.activeAudioFile != nil else { return }

            if !self.engine.isRunning || !self.playerNode.isPlaying {
                self.isPlaying = false
                self.stopProgressTimer()
                self.updateNowPlayingInfo()
                return
            }

            if let activeFile = self.currentTrack?.fileName {
                self.listenedSecondsByFile[activeFile, default: 0] += 0.12
                self.tickCounter += 1
                if self.tickCounter % 30 == 0 {
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

    // Updates iOS 16.2+ ActivityKit Live Activity if enabled in Entitlements
    private func syncLiveActivity() {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled,
                  let track = currentTrack else { return }
            let state = MusiQNowPlayingAttributes.ContentState(
                title: track.title,
                artist: track.artist,
                isPlaying: isPlaying,
                currentTime: progress.currentTime,
                duration: progress.duration
            )
            Task {
                let activities = Activity<MusiQNowPlayingAttributes>.activities
                if let existing = activities.first {
                    await existing.update(ActivityContent(state: state, staleDate: nil))
                } else {
                    let attrs = MusiQNowPlayingAttributes(sessionName: "MusiQ")
                    _ = try? Activity.request(
                        attributes: attrs,
                        content: ActivityContent(state: state, staleDate: nil),
                        pushType: nil
                    )
                }
            }
        }
        #endif
    }
}

// MARK: - Dynamic Island Interactive Capsule HUD (Works Immediately Without Extra Widget Target)
struct DynamicIslandCapsuleHUD: View {
    @ObservedObject var engine: MusiQEngine
    let track: Track
    let onOpenFullPlayer: () -> Void
    let onOpenIPodMode: () -> Void

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack {
            if isExpanded {
                // Expanded Dynamic Island Deck
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        ContinuousSpinView(isSpinning: engine.isPlaying, rpm: 16.0) {
                            if let art = ArtworkCache.shared.artwork(for: track.fileName) {
                                Image(uiImage: art)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(Color.purple)
                                    .frame(width: 44, height: 44)
                                    .overlay(Image(systemName: "opticaldisc").foregroundColor(.white))
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.65))
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            onOpenIPodMode()
                            withAnimation(.spring()) { isExpanded = false }
                        } label: {
                            Image(systemName: "ipod")
                                .font(.system(size: 15, weight: .bold))
                                .padding(8)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Circle())
                                .foregroundColor(.white)
                        }

                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                isExpanded = false
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.caption.bold())
                                .padding(8)
                                .background(Color.white.opacity(0.12))
                                .clipShape(Circle())
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }

                    HStack(spacing: 36) {
                        Button { engine.previousTrack() } label: {
                            Image(systemName: "backward.fill").font(.title3).foregroundColor(.white)
                        }
                        Button { engine.togglePlayPause() } label: {
                            Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 34))
                                .foregroundColor(.white)
                        }
                        Button { engine.nextTrack() } label: {
                            Image(systemName: "forward.fill").font(.title3).foregroundColor(.white)
                        }
                        Button {
                            withAnimation(.spring()) { isExpanded = false }
                            onOpenFullPlayer()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.bold())
                                .foregroundColor(.purple)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.black.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 14, x: 0, y: 6)
                .padding(.horizontal, 16)
            } else {
                // Compact Dynamic Island Pill
                HStack(spacing: 10) {
                    ContinuousSpinView(isSpinning: engine.isPlaying, rpm: 18.0) {
                        if let art = ArtworkCache.shared.artwork(for: track.fileName) {
                            Image(uiImage: art)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 22, height: 22)
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color.purple)
                                .frame(width: 22, height: 22)
                        }
                    }

                    Text(track.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: 120)

                    // Animated 3-Bar Equalizer Waveform
                    HStack(spacing: 2.5) {
                        ForEach(0..<3, id: \.self) { bar in
                            Capsule()
                                .fill(Color.purple)
                                .frame(width: 2.5, height: engine.isPlaying ? CGFloat([8, 14, 10][bar]) : 4)
                                .animation(
                                    engine.isPlaying
                                        ? .easeInOut(duration: 0.35 + Double(bar) * 0.12).repeatForever(autoreverses: true)
                                        : .default,
                                    value: engine.isPlaying
                                )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.92))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 4)
                .onTapGesture {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        isExpanded = true
                    }
                }
            }
        }
    }
}

// MARK: - Realistic iPod Classic 5th/6th Gen Mode (Split-Screen LCD + Trigonometric Haptic Click Wheel!)
struct iPodModeFullScreenView: View {
    @ObservedObject var engine: MusiQEngine
    @ObservedObject var progress: PlaybackProgressObserver
    @Binding var isPresented: Bool

    enum iPodScreen {
        case rootMenu
        case playlistsMenu
        case songsMenu
        case nowPlaying
    }

    @State private var screenStack: [iPodScreen] = [.rootMenu]
    @State private var selectedRow: Int = 0
    @State private var backlightOn: Bool = true
    @State private var lastWheelAngle: Double? = nil
    @State private var accumulatedDeltaAngle: Double = 0

    private let rootMenuItems = ["Now Playing", "Songs", "Playlists", "Shuffle Songs", "Backlight", "Exit iPod Mode"]

    private var currentScreen: iPodScreen {
        screenStack.last ?? .rootMenu
    }

    private var currentRowCount: Int {
        switch currentScreen {
        case .rootMenu: return rootMenuItems.count
        case .playlistsMenu: return max(1, engine.playlists.count)
        case .songsMenu: return max(1, engine.allTracks.count)
        case .nowPlaying: return 1
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Brushed Anodized Aluminum / Classic Silver-Gray iPod Shell
                LinearGradient(
                    colors: [
                        Color(red: 0.84, green: 0.85, blue: 0.88),
                        Color(red: 0.72, green: 0.74, blue: 0.77),
                        Color(red: 0.62, green: 0.64, blue: 0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                // Metallic Inner Bevel Border
                RoundedRectangle(cornerRadius: 42)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.8), .black.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 4
                    )
                    .padding(6)
                    .ignoresSafeArea()

                VStack(spacing: 28) {
                    // 1. Classic 4:3 Recessed Color LCD Display
                    iPodLCDDisplay(width: min(geo.size.width - 44, 342), height: 256)
                        .padding(.top, 16)

                    Spacer(minLength: 4)

                    // 2. Iconic Tactile Click Wheel (With Rotational Drag Gesture & Haptics)
                    iPodClickWheel(diameter: min(geo.size.width - 76, 286))

                    Spacer(minLength: 16)
                }
            }
        }
    }

    // MARK: - iPod 4:3 Split-Pane & Now Playing LCD Screen
    @ViewBuilder
    private func iPodLCDDisplay(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // Outer Black Glass Bezel
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)
                .frame(width: width + 12, height: height + 12)
                .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 4)

            // Inner Backlit LCD Panel
            ZStack {
                Color(white: backlightOn ? 0.97 : 0.75)

                VStack(spacing: 0) {
                    // Top Classic iPod Status Bar
                    HStack {
                        Text(headerTitle)
                            .font(.system(size: 13, weight: .bold, design: .default))
                            .foregroundColor(Color(white: 0.15))
                            .lineLimit(1)

                        Spacer()

                        Image(systemName: engine.isPlaying ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color.blue)

                        // Classic Green Battery Icon
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.black.opacity(0.6), lineWidth: 1)
                                .frame(width: 22, height: 10)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.green.opacity(0.85))
                                .frame(width: 18, height: 6)
                                .padding(.leading, 2)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        LinearGradient(
                            colors: [Color(white: 0.95), Color(white: 0.80)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(Rectangle().fill(Color.gray.opacity(0.5)).frame(height: 1), alignment: .bottom)

                    // Main LCD Content
                    if currentScreen == .nowPlaying {
                        iPodClassicNowPlayingPane(width: width, height: height - 24)
                    } else {
                        // Iconic 6th Gen Split-Screen View (Left Menu + Right Artwork Preview)
                        HStack(spacing: 0) {
                            // Left Menu Pane
                            VStack(spacing: 0) {
                                switch currentScreen {
                                case .rootMenu:
                                    ForEach(0..<rootMenuItems.count, id: \.self) { idx in
                                        iPodMenuRow(title: rootMenuItems[idx], isSelected: idx == selectedRow)
                                    }
                                    Spacer(minLength: 0)

                                case .playlistsMenu:
                                    if engine.playlists.isEmpty {
                                        Text("No Playlists")
                                            .font(.caption.bold())
                                            .foregroundColor(.gray)
                                            .padding(.top, 20)
                                        Spacer()
                                    } else {
                                        let visibleRange = visibleMenuWindow(total: engine.playlists.count, selected: selectedRow, maxRows: 7)
                                        ForEach(visibleRange, id: \.self) { idx in
                                            iPodMenuRow(title: engine.playlists[idx].name, isSelected: idx == selectedRow)
                                        }
                                        Spacer(minLength: 0)
                                    }

                                case .songsMenu:
                                    if engine.allTracks.isEmpty {
                                        Text("No Songs")
                                            .font(.caption.bold())
                                            .foregroundColor(.gray)
                                            .padding(.top, 20)
                                        Spacer()
                                    } else {
                                        let visibleRange = visibleMenuWindow(total: engine.allTracks.count, selected: selectedRow, maxRows: 7)
                                        ForEach(visibleRange, id: \.self) { idx in
                                            iPodMenuRow(title: engine.allTracks[idx].title, isSelected: idx == selectedRow)
                                        }
                                        Spacer(minLength: 0)
                                    }

                                case .nowPlaying:
                                    EmptyView()
                                }
                            }
                            .frame(width: width * 0.54, height: height - 24)
                            .overlay(Rectangle().fill(Color.gray.opacity(0.35)).frame(width: 1), alignment: .trailing)

                            // Right Preview Pane (Shows Highlighted Track/Album Cover)
                            ZStack {
                                LinearGradient(
                                    colors: [Color(white: 0.92), Color(white: 0.82)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )

                                VStack(spacing: 8) {
                                    if let previewArt = previewArtworkForCurrentSelection() {
                                        Image(uiImage: previewArt)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: width * 0.34, height: width * 0.34)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 3)
                                    } else {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(LinearGradient(colors: [.blue.opacity(0.7), .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                .frame(width: width * 0.32, height: width * 0.32)
                                            Image(systemName: "music.note")
                                                .font(.system(size: 36, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                                    }

                                    Text("\(engine.allTracks.count) Songs")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.black.opacity(0.6))
                                }
                            }
                            .frame(width: width * 0.46, height: height - 24)
                        }
                    }
                }

                // Subtle Diagonal Glass Screen Glare
                LinearGradient(
                    colors: [Color.white.opacity(0.18), Color.clear, Color.black.opacity(backlightOn ? 0.02 : 0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .allowsHitTesting(false)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    @ViewBuilder
    private func iPodMenuRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isSelected ? .white : .black.opacity(0.85))
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isSelected ? .white : .gray)
        }
        .padding(.horizontal, 10)
        .frame(height: 31)
        .background(
            Group {
                if isSelected {
                    LinearGradient(
                        colors: [Color(red: 0.22, green: 0.58, blue: 0.96), Color(red: 0.10, green: 0.38, blue: 0.82)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    Color.clear
                }
            }
        )
    }

    @ViewBuilder
    private func iPodClassicNowPlayingPane(width: CGFloat, height: CGFloat) -> some View {
        let track = engine.currentTrack
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                if let fileName = track?.fileName,
                   let art = ArtworkCache.shared.artwork(for: fileName) {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 112, height: 112)
                        .border(Color.gray.opacity(0.4), width: 1)
                        .shadow(color: .black.opacity(0.35), radius: 5, x: 2, y: 4)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.25))
                        .frame(width: 112, height: 112)
                        .overlay(Image(systemName: "music.note").font(.largeTitle).foregroundColor(.gray))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(track?.title ?? "No Track")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .lineLimit(2)

                    Text(track?.artist ?? "Unknown Artist")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black.opacity(0.65))
                        .lineLimit(1)

                    Text("MusiQ iPod Edition")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray)

                    if let firstLyric = activeLyricString {
                        Text(firstLyric)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(red: 0.10, green: 0.38, blue: 0.82))
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Spacer(minLength: 0)

            // Classic Glossy Blue iPod Progress Bar
            VStack(spacing: 4) {
                GeometryReader { barGeo in
                    let ratio = min(1.0, max(0.0, progress.currentTime / max(progress.duration, 1)))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(white: 0.78), Color(white: 0.90)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 10)
                            .overlay(Capsule().stroke(Color.gray.opacity(0.6), lineWidth: 0.8))

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.35, green: 0.68, blue: 1.0), Color(red: 0.12, green: 0.42, blue: 0.88)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: max(8, barGeo.size.width * ratio), height: 10)
                    }
                }
                .frame(height: 10)

                HStack {
                    Text(formatSeconds(progress.currentTime))
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundColor(.black.opacity(0.75))
                    Spacer()
                    Text("-" + formatSeconds(max(0, progress.duration - progress.currentTime)))
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundColor(.black.opacity(0.75))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(width: width, height: height)
    }

    // MARK: - Trigonometric Haptic Click Wheel
    @ViewBuilder
    private func iPodClickWheel(diameter: CGFloat) -> some View {
        let centerSize = diameter * 0.36

        ZStack {
            // Matte White / Light Gray Click Wheel Surface
            Circle()
                .fill(Color(white: 0.95))
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.18), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 4)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let center = CGPoint(x: diameter / 2.0, y: diameter / 2.0)
                            let dx = Double(value.location.x - center.x)
                            let dy = Double(value.location.y - center.y)
                            let radius = sqrt(dx * dx + dy * dy)

                            // Ignore touches inside the center button
                            guard radius > Double(centerSize * 0.48) else { return }

                            let angle = atan2(dy, dx) * 180.0 / .pi
                            if let prev = lastWheelAngle {
                                var delta = angle - prev
                                if delta > 180 { delta -= 360 }
                                if delta < -180 { delta += 360 }
                                accumulatedDeltaAngle += delta

                                // Every 16 degrees of thumb rotation = 1 mechanical click tick!
                                let stepDegrees = 16.0
                                if abs(accumulatedDeltaAngle) >= stepDegrees {
                                    let steps = Int(accumulatedDeltaAngle / stepDegrees)
                                    accumulatedDeltaAngle -= Double(steps) * stepDegrees
                                    handleWheelScroll(steps: steps)
                                }
                            }
                            lastWheelAngle = angle
                        }
                        .onEnded { _ in
                            lastWheelAngle = nil
                            accumulatedDeltaAngle = 0
                        }
                )

            // Top "MENU" Button
            VStack {
                Button {
                    triggerClickHaptic()
                    handleMenuButton()
                } label: {
                    Text("MENU")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .tracking(1.2)
                        .foregroundColor(.gray)
                        .padding(.top, 18)
                        .frame(width: 90, height: 44)
                }
                Spacer()
                // Bottom Play/Pause Button
                Button {
                    triggerClickHaptic()
                    engine.togglePlayPause()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "play.fill")
                        Image(systemName: "pause.fill")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.gray)
                    .padding(.bottom, 18)
                    .frame(width: 90, height: 44)
                }
            }
            .frame(width: diameter, height: diameter)

            // Left Previous & Right Next Buttons
            HStack {
                Button {
                    triggerClickHaptic()
                    engine.previousTrack()
                } label: {
                    Image(systemName: "backward.end.alt.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.gray)
                        .padding(.leading, 18)
                        .frame(width: 54, height: 80)
                }
                Spacer()
                Button {
                    triggerClickHaptic()
                    engine.nextTrack()
                } label: {
                    Image(systemName: "forward.end.alt.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.gray)
                        .padding(.trailing, 18)
                        .frame(width: 54, height: 80)
                }
            }
            .frame(width: diameter, height: diameter)

            // Center Tactile Select Button
            Button {
                triggerClickHaptic()
                handleCenterSelect()
            } label: {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.76), Color(white: 0.64)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: centerSize, height: centerSize)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.25), lineWidth: 1.2)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
            }
        }
    }

    // MARK: - iPod Click Wheel Logic & Haptics
    private func triggerClickHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        AudioServicesPlaySystemSound(1104)
    }

    private func handleWheelScroll(steps: Int) {
        guard steps != 0 else { return }
        triggerClickHaptic()

        if currentScreen == .nowPlaying {
            // Scrolling the Click Wheel in Now Playing scrubs 3 seconds per click!
            let target = max(0, min(progress.duration, progress.currentTime + Double(steps) * 3.0))
            engine.seek(to: target)
        } else {
            let maxRow = max(0, currentRowCount - 1)
            selectedRow = max(0, min(maxRow, selectedRow + (steps > 0 ? 1 : -1)))
        }
    }

    private func handleMenuButton() {
        if screenStack.count > 1 {
            screenStack.removeLast()
            selectedRow = 0
        } else {
            isPresented = false
        }
    }

    private func handleCenterSelect() {
        switch currentScreen {
        case .rootMenu:
            switch selectedRow {
            case 0:
                screenStack.append(.nowPlaying)
            case 1:
                selectedRow = 0
                screenStack.append(.songsMenu)
            case 2:
                selectedRow = 0
                screenStack.append(.playlistsMenu)
            case 3:
                if !engine.allTracks.isEmpty {
                    engine.isShuffle = true
                    if let rand = engine.allTracks.randomElement() {
                        engine.playTrack(rand, in: engine.allTracks)
                        screenStack.append(.nowPlaying)
                    }
                }
            case 4:
                backlightOn.toggle()
            case 5:
                isPresented = false
            default:
                break
            }

        case .songsMenu:
            guard engine.allTracks.indices.contains(selectedRow) else { return }
            let track = engine.allTracks[selectedRow]
            engine.playTrack(track, in: engine.allTracks)
            screenStack.append(.nowPlaying)

        case .playlistsMenu:
            guard engine.playlists.indices.contains(selectedRow) else { return }
            let pTracks = engine.tracks(for: engine.playlists[selectedRow])
            if let first = pTracks.first {
                engine.playTrack(first, in: pTracks)
                screenStack.append(.nowPlaying)
            }

        case .nowPlaying:
            engine.togglePlayPause()
        }
    }

    private var headerTitle: String {
        switch currentScreen {
        case .rootMenu: return "iPod"
        case .playlistsMenu: return "Playlists"
        case .songsMenu: return "Songs"
        case .nowPlaying: return "Now Playing"
        }
    }

    private var activeLyricString: String? {
        guard let idx = LyricsManager.activeLineIndex(
            in: engine.currentTrackLyrics,
            currentTime: progress.currentTime,
            duration: progress.duration,
            autoOffset: engine.autoDetectedLyricOffset
        ), engine.currentTrackLyrics.indices.contains(idx) else { return nil }
        return engine.currentTrackLyrics[idx].text
    }

    private func previewArtworkForCurrentSelection() -> UIImage? {
        switch currentScreen {
        case .songsMenu:
            if engine.allTracks.indices.contains(selectedRow) {
                return ArtworkCache.shared.artwork(for: engine.allTracks[selectedRow].fileName)
            }
        case .playlistsMenu:
            if engine.playlists.indices.contains(selectedRow) {
                let pl = engine.playlists[selectedRow]
                if let custom = ArtworkCache.shared.playlistCover(for: pl.id) { return custom }
                if let first = engine.tracks(for: pl).first {
                    return ArtworkCache.shared.artwork(for: first.fileName)
                }
            }
        default:
            break
        }
        if let active = engine.currentTrack {
            return ArtworkCache.shared.artwork(for: active.fileName)
        }
        if let first = engine.allTracks.first {
            return ArtworkCache.shared.artwork(for: first.fileName)
        }
        return nil
    }

    private func visibleMenuWindow(total: Int, selected: Int, maxRows: Int) -> Range<Int> {
        guard total > maxRows else { return 0..<total }
        let half = maxRows / 2
        var start = max(0, selected - half)
        if start + maxRows > total {
            start = max(0, total - maxRows)
        }
        return start..<(start + maxRows)
    }

    private func formatSeconds(_ s: Double) -> String {
        guard s.isFinite && s >= 0 else { return "0:00" }
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Continuous 60fps Spinning Disc / Reel Modifier
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
        withAnimation(.linear(duration: duration).delay(1.0).
