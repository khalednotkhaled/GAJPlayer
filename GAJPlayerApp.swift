import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
import UniformTypeIdentifiers
import PhotosUI
import CoreMotion
import Network
import AudioToolbox

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

// MARK: - Perfectly Centered Native Audio Output Route Picker ("Source" Button)
struct AudioSourcePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        picker.backgroundColor = .clear
        picker.tintColor = UIColor.white.withAlphaComponent(0.88)
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

// MARK: - Local Wi-Fi Drag & Drop Browser Upload Server (NWListener Port 8080)
final class WiFiUploadServer: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var serverURLString: String = ""
    @Published var uploadedCount: Int = 0
    @Published var lastUploadedFile: String = ""

    private var listener: NWListener?
    var onFileUploaded: (() -> Void)?

    func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func startServer() {
        stopServer()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: params, on: 8080)
            self.listener = newListener

            newListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        let ip = Self.getWiFiIPAddress() ?? "127.0.0.1"
                        self.serverURLString = "http://\(ip):8080"
                    case .failed, .cancelled:
                        self.isRunning = false
                        self.serverURLString = ""
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleClientConnection(connection)
            }

            newListener.start(queue: .global(qos: .userInitiated))
        } catch {
            print("Wi-Fi Server error: \(error)")
        }
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        isRunning = false
        serverURLString = ""
    }

    private func handleClientConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var accumulated = Data()

        func receiveNextChunk() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let d = data, !d.isEmpty {
                    accumulated.append(d)
                }

                if let headerEndRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = accumulated.subdata(in: 0..<headerEndRange.lowerBound)
                    let headerStr = String(data: headerData, encoding: .utf8) ?? ""
                    let firstLine = headerStr.components(separatedBy: "\r\n").first ?? ""

                    if firstLine.hasPrefix("GET ") {
                        self.sendHTMLPortal(over: connection)
                        return
                    } else if firstLine.hasPrefix("POST ") {
                        let contentLen = Self.extractContentLength(from: headerStr)
                        let bodyBytesCount = accumulated.count - headerEndRange.upperBound
                        if bodyBytesCount >= contentLen || isComplete {
                            let bodyData = accumulated.subdata(in: headerEndRange.upperBound..<accumulated.count)
                            let rawFileName = Self.extractHeaderValue(from: headerStr, key: "X-File-Name") ?? "Track_\(Int(Date().timeIntervalSince1970)).mp3"
                            let decodedName = rawFileName.removingPercentEncoding ?? rawFileName
                            self.saveUploadedAudioData(bodyData, fileName: decodedName)
                            self.sendJSONSuccess(over: connection)
                            return
                        }
                    }
                }

                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receiveNextChunk()
                }
            }
        }

        receiveNextChunk()
    }

    private func saveUploadedAudioData(_ data: Data, fileName: String) {
        guard data.count > 4096 else { return }
        let safeName = fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent(safeName)
        try? FileManager.default.removeItem(at: dest)
        try? data.write(to: dest)

        DispatchQueue.main.async {
            self.uploadedCount += 1
            self.lastUploadedFile = safeName
            self.onFileUploaded?()
        }
    }

    private func sendHTMLPortal(over connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>MusiQ Wi-Fi Studio Drop</title>
        <style>
        body { background:#0d0c12; color:#fff; font-family:-apple-system,BlinkMacSystemFont,sans-serif; display:flex; flex-direction:column; align-items:center; justify-content:center; min-height:92vh; margin:0; }
        .card { background:rgba(255,255,255,0.05); border:2px dashed #a855f7; border-radius:24px; padding:48px 36px; text-align:center; max-width:460px; width:85%; transition:0.25s; cursor:pointer; }
        .card.drag { background:rgba(168,85,247,0.18); transform:scale(1.02); }
        h1 { margin:0 0 8px; font-size:26px; }
        p { color:#a1a1aa; font-size:14px; margin-bottom:24px; }
        .btn { background:#a855f7; color:#fff; padding:12px 24px; border-radius:99px; font-weight:700; display:inline-block; }
        #log { margin-top:22px; font-size:13px; color:#c084fc; max-height:180px; overflow-y:auto; text-align:left; width:100%; }
        </style>
        </head>
        <body>
        <div class="card" id="dropzone" onclick="document.getElementById('picker').click()">
            <h1>MusiQ Wi-Fi Drop</h1>
            <p>Drag & drop .mp3, .m4a, .wav, or .flac songs here to send them straight to your iPhone.</p>
            <div class="btn">Choose Audio Files</div>
            <input type="file" id="picker" multiple accept=".mp3,.m4a,.wav,.flac,.aac" style="display:none" onchange="uploadFiles(this.files)">
            <div id="log"></div>
        </div>
        <script>
        const dz = document.getElementById('dropzone');
        const log = document.getElementById('log');
        dz.addEventListener('dragover', e => { e.preventDefault(); dz.classList.add('drag'); });
        dz.addEventListener('dragleave', () => dz.classList.remove('drag'));
        dz.addEventListener('drop', e => { e.preventDefault(); dz.classList.remove('drag'); uploadFiles(e.dataTransfer.files); });
        async function uploadFiles(files) {
            for (const f of files) {
                const item = document.createElement('div');
                item.textContent = '⏳ Uploading ' + f.name + '...';
                log.prepend(item);
                try {
                    const buf = await f.arrayBuffer();
                    await fetch('/upload', { method:'POST', headers:{ 'X-File-Name': encodeURIComponent(f.name) }, body: buf });
                    item.textContent = '✅ Sent ' + f.name;
                } catch (err) {
                    item.textContent = '❌ Failed ' + f.name;
                }
            }
        }
        </script>
        </body>
        </html>
        """
        let body = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendJSONSuccess(over connection: NWConnection) {
        let body = Data("{\"ok\":true}".utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func extractContentLength(from header: String) -> Int {
        if let val = extractHeaderValue(from: header, key: "Content-Length"), let n = Int(val) {
            return n
        }
        return 0
    }

    private static func extractHeaderValue(from header: String, key: String) -> String? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() {
                return parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func getWiFiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
                let interface = ptr.pointee
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" {
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
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
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
            req.setValue("MusiQ iOS Player v4.0", forHTTPHeaderField: "User-Agent")
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

// MARK: - Crash-Proof, Sample-Rate Resampling Audio Engine
final class MusiQEngine: ObservableObject {
    @Published var allTracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var currentQueue: [Track] = []
    @Published var currentIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var isShuffle: Bool = false
    @Published var isRepeat: Bool = false

    @Published var visualMode: VisualMode = .sideVinyl
    @Published var isIPodModeActive: Bool = false
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
}

// MARK: - Full-Screen Standalone iPod Classic Mode (With Top-Left Quit Button & High-Precision Click Wheel)
struct FullScreenIPodClassicModeView: View {
    @ObservedObject var engine: MusiQEngine
    @ObservedObject var progress: PlaybackProgressObserver
    let onQuit: () -> Void

    enum IPodScreenState: Equatable {
        case rootMenu
        case songsList
        case playlistsList
        case playlistTracks(UUID)
        case nowPlaying
    }

    @State private var screenStack: [IPodScreenState] = [.rootMenu]
    @State private var selectedRow: Int = 0
    @State private var backlightOn: Bool = true
    @State private var lastWheelAngle: Double? = nil
    @State private var accumulatedDeltaAngle: Double = 0

    private let rootMenuItems = ["Now Playing", "Songs", "Playlists", "Shuffle Songs", "Backlight"]

    private var currentScreen: IPodScreenState {
        screenStack.last ?? .rootMenu
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lcdWidth = min(w - 44, 336)
            let lcdHeight = lcdWidth * 0.75
            let wheelDiameter = min(w - 84, 268)

            ZStack {
                LinearGradient(
                    colors: [
                        Color(white: 0.88),
                        Color(white: 0.76),
                        Color(white: 0.68),
                        Color(white: 0.58)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top Bar with "Quit" Button on Top Left
                    HStack {
                        Button {
                            triggerClickHaptic(heavy: true)
                            onQuit()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15, weight: .bold))
                                Text("Quit iPod")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.68))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                        }

                        Spacer()

                        Text("iPod Classic")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundColor(.black.opacity(0.45))
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 16)

                    // 4:3 Retro iPod Color LCD Screen
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(backlightOn ? Color(white: 0.97) : Color(red: 0.68, green: 0.72, blue: 0.66))
                            .frame(width: lcdWidth + 8, height: lcdHeight + 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.black.opacity(0.88), lineWidth: 5)
                            )
                            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)

                        VStack(spacing: 0) {
                            HStack {
                                Text(statusBarTitle)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.black.opacity(0.85))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: engine.isPlaying ? "play.fill" : "pause.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.blue)
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(Color.black.opacity(0.75), lineWidth: 1)
                                        .frame(width: 22, height: 10)
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.green.opacity(0.85))
                                        .frame(width: 18, height: 8)
                                        .padding(.leading, 1)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                LinearGradient(
                                    colors: [Color(white: 0.95), Color(white: 0.80)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(Rectangle().fill(Color.gray.opacity(0.5)).frame(height: 1), alignment: .bottom)

                            Group {
                                switch currentScreen {
                                case .rootMenu:
                                    ipodSplitScreenRootMenu(totalWidth: lcdWidth, totalHeight: lcdHeight - 28)
                                case .songsList:
                                    ipodSingleListScreen(
                                        items: engine.allTracks.isEmpty ? ["No Songs in Library"] : engine.allTracks.map { $0.title },
                                        subtitles: engine.allTracks.map { $0.artist },
                                        height: lcdHeight - 28
                                    )
                                case .playlistsList:
                                    ipodSingleListScreen(
                                        items: engine.playlists.isEmpty ? ["No Playlists Yet"] : engine.playlists.map { $0.name },
                                        subtitles: engine.playlists.map { "\($0.trackFileNames.count) songs" },
                                        height: lcdHeight - 28
                                    )
                                case .playlistTracks(let pid):
                                    let pTracks = engine.playlists.first(where: { $0.id == pid }).map { engine.tracks(for: $0) } ?? []
                                    ipodSingleListScreen(
                                        items: pTracks.isEmpty ? ["Empty Playlist"] : pTracks.map { $0.title },
                                        subtitles: pTracks.map { $0.artist },
                                        height: lcdHeight - 28
                                    )
                                case .nowPlaying:
                                    ipodNowPlayingScreen(width: lcdWidth, height: lcdHeight - 28)
                                }
                            }
                            .frame(width: lcdWidth, height: lcdHeight - 28)
                            .clipped()
                        }
                        .frame(width: lcdWidth, height: lcdHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.clear, Color.black.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: lcdWidth, height: lcdHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false)
                    }

                    Spacer()

                    // High-Precision Trigonometric Click Wheel
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(white: 0.94), Color(white: 0.84)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: wheelDiameter, height: wheelDiameter)
                            .overlay(Circle().stroke(Color.black.opacity(0.22), lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.38), radius: 12, x: 0, y: 6)
                            .contentShape(Circle())
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                    .onChanged { value in
                                        let radius = wheelDiameter / 2.0
                                        let dx = value.location.x - radius
                                        let dy = value.location.y - radius
                                        let dist = hypot(dx, dy)

                                        guard dist > (wheelDiameter * 0.16) else { return }

                                        let angle = atan2(dy, dx) * 180.0 / .pi
                                        if let prev = lastWheelAngle {
                                            var delta = angle - prev
                                            if delta > 180 { delta -= 360 }
                                            if delta < -180 { delta += 360 }

                                            if abs(delta) < 75 {
                                                accumulatedDeltaAngle += delta
                                                let stepDegrees = 9.5
                                                if abs(accumulatedDeltaAngle) >= stepDegrees {
                                                    let steps = Int(accumulatedDeltaAngle / stepDegrees)
                                                    accumulatedDeltaAngle -= Double(steps) * stepDegrees
                                                    handleWheelScroll(steps: steps)
                                                }
                                            }
                                        }
                                        lastWheelAngle = angle
                                    }
                                    .onEnded { _ in
                                        lastWheelAngle = nil
                                        accumulatedDeltaAngle = 0
                                    }
                            )

                        VStack {
                            Button {
                                triggerClickHaptic()
                                handleMenuButton()
                            } label: {
                                Text("MENU")
                                    .font(.system(size: 13, weight: .black, design: .rounded))
                                    .tracking(1.3)
                                    .foregroundColor(.gray.opacity(0.95))
                                    .padding(.top, 16)
                                    .frame(width: 90, height: 46)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button {
                                triggerClickHaptic()
                                engine.togglePlayPause()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "play.fill")
                                    Image(systemName: "pause.fill")
                                }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.gray.opacity(0.95))
                                .padding(.bottom, 16)
                                .frame(width: 90, height: 46)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: wheelDiameter, height: wheelDiameter)

                        HStack {
                            Button {
                                triggerClickHaptic()
                                engine.previousTrack()
                            } label: {
                                Image(systemName: "backward.end.alt.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.gray.opacity(0.95))
                                    .padding(.leading, 16)
                                    .frame(width: 54, height: 90)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button {
                                triggerClickHaptic()
                                engine.nextTrack()
                            } label: {
                                Image(systemName: "forward.end.alt.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.gray.opacity(0.95))
                                    .padding(.trailing, 16)
                                    .frame(width: 54, height: 90)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: wheelDiameter, height: wheelDiameter)

                        Button {
                            triggerClickHaptic(heavy: true)
                            handleCenterSelect()
                        } label: {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(white: 0.74), Color(white: 0.88)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: wheelDiameter * 0.35, height: wheelDiameter * 0.35)
                                .overlay(Circle().stroke(Color.black.opacity(0.28), lineWidth: 1.2))
                                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
        }
    }

    private var statusBarTitle: String {
        switch currentScreen {
        case .rootMenu: return "iPod"
        case .songsList: return "Songs (\(engine.allTracks.count))"
        case .playlistsList: return "Playlists"
        case .playlistTracks: return "Playlist"
        case .nowPlaying: return "Now Playing"
        }
    }

    @ViewBuilder
    private func ipodSplitScreenRootMenu(totalWidth: CGFloat, totalHeight: CGFloat) -> some View {
        let halfW = totalWidth * 0.52
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(0..<rootMenuItems.count, id: \.self) { idx in
                    let isSel = (selectedRow == idx)
                    HStack {
                        Text(rootMenuItems[idx])
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(isSel ? .white : .black)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(isSel ? .white : .gray)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        isSel
                            ? LinearGradient(colors: [Color(red: 0.22, green: 0.58, blue: 0.98), Color(red: 0.10, green: 0.38, blue: 0.86)], startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        triggerClickHaptic()
                        selectedRow = idx
                        handleCenterSelect()
                    }
                }
                Spacer()
            }
            .frame(width: halfW, height: totalHeight)
            .overlay(Rectangle().fill(Color.gray.opacity(0.35)).frame(width: 1), alignment: .trailing)

            ZStack {
                if let track = engine.currentTrack ?? engine.allTracks.first,
                   let art = ArtworkCache.shared.artwork(for: track.fileName) {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: totalWidth * 0.36, height: totalWidth * 0.36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
                } else {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 46))
                        .foregroundColor(.gray.opacity(0.5))
                }
            }
            .frame(width: totalWidth - halfW, height: totalHeight)
        }
    }

    @ViewBuilder
    private func ipodSingleListScreen(items: [String], subtitles: [String], height: CGFloat) -> some View {
        let rowHeight: CGFloat = 32
        let visibleRows = max(1, Int(height / rowHeight))
        let clampedSel = max(0, min(max(0, items.count - 1), selectedRow))
        let startIdx = max(0, min(clampedSel - (visibleRows / 2), max(0, items.count - visibleRows)))
        let endIdx = min(items.count, startIdx + visibleRows)

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(startIdx..<endIdx, id: \.self) { idx in
                    let isSel = (clampedSel == idx)
                    HStack {
                        Text(items[idx])
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(isSel ? .white : .black)
                            .lineLimit(1)
                        Spacer()
                        if subtitles.indices.contains(idx) {
                            Text(subtitles[idx])
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(isSel ? .white.opacity(0.85) : .gray)
                                .lineLimit(1)
                                .frame(maxWidth: 90, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: rowHeight)
                    .background(
                        isSel
                            ? LinearGradient(colors: [Color(red: 0.22, green: 0.58, blue: 0.98), Color(red: 0.10, green: 0.38, blue: 0.86)], startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        triggerClickHaptic(heavy: true)
                        selectedRow = idx
                        handleCenterSelect()
                    }
                }
                Spacer(minLength: 0)
            }

            if items.count > visibleRows {
                GeometryReader { sbGeo in
                    let thumbRatio = CGFloat(visibleRows) / CGFloat(items.count)
                    let thumbH = max(18, sbGeo.size.height * thumbRatio)
                    let maxOffset = max(1, sbGeo.size.height - thumbH)
                    let progressRatio = CGFloat(clampedSel) / CGFloat(max(1, items.count - 1))

                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.22))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 0.16, green: 0.48, blue: 0.92))
                            .frame(width: 5, height: thumbH)
                            .offset(y: maxOffset * progressRatio)
                    }
                }
                .frame(width: 7)
            }
        }
    }

    @ViewBuilder
    private func ipodNowPlayingScreen(width: CGFloat, height: CGFloat) -> some View {
        let track = engine.currentTrack
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                if let t = track, let art = ArtworkCache.shared.artwork(for: t.fileName) {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: height * 0.54, height: height * 0.54)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 2, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: height * 0.54, height: height * 0.54)
                        .overlay(Image(systemName: "music.note").foregroundColor(.gray))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(track?.title ?? "No Track Playing")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .lineLimit(2)
                    Text(track?.artist ?? "Unknown Artist")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                    Text("\(engine.currentIndex + 1) of \(max(1, engine.currentQueue.count))")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.gray.opacity(0.85))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            VStack(spacing: 5) {
                GeometryReader { geo in
                    let ratio = CGFloat(min(max(progress.currentTime / max(progress.duration, 1), 0), 1))
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.gray.opacity(0.28))
                            .frame(height: 11)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.30, green: 0.68, blue: 1.0), Color(red: 0.12, green: 0.42, blue: 0.90)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: geo.size.width * ratio, height: 11)
                    }
                }
                .frame(height: 11)

                HStack {
                    Text(formatIPodTime(progress.currentTime))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.black.opacity(0.75))
                    Spacer()
                    Text("-" + formatIPodTime(max(0, progress.duration - progress.currentTime)))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.black.opacity(0.75))
                }
            }
            .padding(.horizontal, 16)

            Spacer()
        }
    }

    private func formatIPodTime(_ s: Double) -> String {
        guard s.isFinite && s >= 0 else { return "0:00" }
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func triggerClickHaptic(heavy: Bool = false) {
        let gen = UIImpactFeedbackGenerator(style: heavy ? .medium : .light)
        gen.impactOccurred()
        AudioServicesPlaySystemSound(1104)
    }

    private func handleWheelScroll(steps: Int) {
        triggerClickHaptic()
        switch currentScreen {
        case .rootMenu:
            selectedRow = max(0, min(rootMenuItems.count - 1, selectedRow + steps))
        case .songsList:
            guard !engine.allTracks.isEmpty else { return }
            selectedRow = max(0, min(engine.allTracks.count - 1, selectedRow + steps))
        case .playlistsList:
            guard !engine.playlists.isEmpty else { return }
            selectedRow = max(0, min(engine.playlists.count - 1, selectedRow + steps))
        case .playlistTracks(let pid):
            let pTracks = engine.playlists.first(where: { $0.id == pid }).map { engine.tracks(for: $0) } ?? []
            guard !pTracks.isEmpty else { return }
            selectedRow = max(0, min(pTracks.count - 1, selectedRow + steps))
        case .nowPlaying:
            let target = max(0, min(progress.duration, progress.currentTime + Double(steps) * 2.5))
            engine.seek(to: target)
        }
    }

    private func handleMenuButton() {
        if screenStack.count > 1 {
            screenStack.removeLast()
            selectedRow = 0
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
                screenStack.append(.songsList)
            case 2:
                selectedRow = 0
                screenStack.append(.playlistsList)
            case 3:
                if let randomTrack = engine.allTracks.randomElement() {
                    engine.isShuffle = true
                    engine.playTrack(randomTrack, in: engine.allTracks)
                    screenStack.append(.nowPlaying)
                }
            case 4:
                backlightOn.toggle()
            default:
                break
            }
        case .songsList:
            guard engine.allTracks.indices.contains(selectedRow) else { return }
            let track = engine.allTracks[selectedRow]
            engine.playTrack(track, in: engine.allTracks)
            screenStack.append(.nowPlaying)

        case .playlistsList:
            guard engine.playlists.indices.contains(selectedRow) else { return }
            let pid = engine.playlists[selectedRow].id
            selectedRow = 0
            screenStack.append(.playlistTracks(pid))

        case .playlistTracks(let pid):
            let pTracks = engine.playlists.first(where: { $0.id == pid }).map { engine.tracks(for: $0) } ?? []
            guard pTracks.indices.contains(selectedRow) else { return }
            engine.playTrack(pTracks[selectedRow], in: pTracks)
            screenStack.append(.nowPlaying)

        case .nowPlaying:
            engine.togglePlayPause()
        }
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
        withAnimation(.linear(duration: duration).delay(1.0).repeatForever(autoreverses: false)) {
            offset = -totalShift
        }
    }
}

// MARK: - 2-Line Capable Word-by-Word Karaoke Inline Lyric View
struct WordByWordInlineLyricView: View {
    @ObservedObject var progress: PlaybackProgressObserver
    let lines: [LyricLine]
    let autoOffset: Double
    let isFetching: Bool
    let onTap: () -> Void

    private var activeIndex: Int? {
        LyricsManager.activeLineIndex(
            in: lines,
            currentTime: progress.currentTime,
            duration: progress.duration,
            autoOffset: autoOffset
        )
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let idx = activeIndex {
                    let activeLine = lines[idx]
                    let activeWordIdx = LyricsManager.activeWordProgress(
                        in: activeLine,
                        currentTime: progress.currentTime,
                        autoOffset: autoOffset
                    )

                    buildKaraokeAttributedText(line: activeLine, activeWordIndex: activeWordIdx)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .shadow(color: .white.opacity(0.25), radius: 5, x: 0, y: 0)
                        .lineLimit(2)
                        .minimumScaleFactor(0.80)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .id("inline_lyric_\(idx)")
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            )
                        )
                        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: idx)
                } else if isFetching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.75)
                            .tint(.white.opacity(0.6))
                        Text("Syncing version-matched lyrics...")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                    }
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .bold))
                        Text("Scroll down or tap for lyrics")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.38))
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
    }

    private func buildKaraokeAttributedText(line: LyricLine, activeWordIndex: Int) -> Text {
        var combined = Text("")
        for (wIdx, word) in line.words.enumerated() {
            let space = (wIdx == line.words.count - 1) ? "" : " "
            let isSungOrCurrent = wIdx <= activeWordIndex
            let piece = Text(word + space)
                .foregroundColor(isSungOrCurrent ? .white : .white.opacity(0.40))
            combined = combined + piece
        }
        return combined
    }
}

// MARK: - Scroll-Down Spotify-Inspired Lyrics Card
struct ScrollDownLyricsPreviewCard: View {
    @ObservedObject var progress: PlaybackProgressObserver
    let lines: [LyricLine]
    let autoOffset: Double
    let isFetching: Bool
    let cardTint: Color
    let onOpenFullLyrics: () -> Void

    private var activeIndex: Int? {
        LyricsManager.activeLineIndex(
            in: lines,
            currentTime: progress.currentTime,
            duration: progress.duration,
            autoOffset: autoOffset
        )
    }

    var body: some View {
        Button(action: onOpenFullLyrics) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Lyrics")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Spacer()

                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.28))
                            .frame(width: 34, height: 34)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                if !lines.isEmpty, let currentIdx = activeIndex {
                    let startIdx = max(0, min(currentIdx - 1, max(0, lines.count - 5)))
                    let endIdx = min(lines.count, startIdx + 5)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(startIdx..<endIdx, id: \.self) { idx in
                            let isCurrent = (idx == currentIdx)
                            Text(lines[idx].text)
                                .font(.system(size: isCurrent ? 22 : 19, weight: .bold, design: .rounded))
                                .foregroundColor(isCurrent ? .white : .black.opacity(0.48))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .animation(.spring(response: 0.34, dampingFraction: 0.84), value: currentIdx)
                        }
                    }
                    .padding(.vertical, 4)
                } else if isFetching {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Syncing live lyrics...")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.vertical, 24)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No verified synced lyrics yet.")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                        Text("Tap this card to auto-fetch or paste custom lyrics.")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white.opacity(0.65))
                    }
                    .padding(.vertical, 18)
                }
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: [
                                cardTint.opacity(0.92),
                                cardTint.opacity(0.75)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Apple Music-Style Blurred Scrolling Lyrics Sheet
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
            autoOffset: engine.autoDetectedLyricOffset
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

                HStack(spacing: 14) {
                    if let art = ArtworkCache.shared.artwork(for: track.fileName) {
                        Image(uiImage: art)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 52, height: 52)
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
                            engine.reloadLyricsForCurrentTrack(forceOnlineFetch: true)
                        } label: {
                            Label("Re-Fetch Synced Lyrics", systemImage: "sparkles")
                        }

                        Button {
                            rawLyricsDraft = LyricsManager.shared.getLyrics(for: track)
                            showRawEditor.toggle()
                        } label: {
                            Label(showRawEditor ? "View Synced Lyrics" : "Edit / Paste Raw Lyrics", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            LyricsManager.shared.saveLyrics("", matchedDuration: nil, for: track)
                            engine.currentTrackLyrics = []
                        } label: {
                            Label("Clear Lyrics for This Track", systemImage: "trash")
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
                .padding(.bottom, 12)

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
                                LyricsManager.shared.saveLyrics(rawLyricsDraft, matchedDuration: track.duration, for: track)
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
                                Text("Verifying track version & syncing lyrics...")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.7))
                            } else {
                                Image(systemName: "quote.bubble")
                                    .font(.system(size: 42))
                                    .foregroundColor(.white.opacity(0.45))
                                Text("No Public Lyrics for This Track")
                                    .font(.title3.bold())
                                    .foregroundColor(.white)
                                Text("Unreleased / Yedit tracks without verified online lyrics stay clean.\nYou can paste custom lyrics below.")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.65))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)

                                HStack(spacing: 12) {
                                    Button {
                                        engine.reloadLyricsForCurrentTrack(forceOnlineFetch: true)
                                    } label: {
                                        Label("Retry Auto-Match", systemImage: "sparkles")
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
                                                let seekTarget = max(0, t + engine.autoDetectedLyricOffset)
                                                engine.seek(to: seekTarget)
                                            }
                                        } label: {
                                            if isCurrent {
                                                let activeWordIdx = LyricsManager.activeWordProgress(
                                                    in: line,
                                                    currentTime: progress.currentTime,
                                                    autoOffset: engine.autoDetectedLyricOffset
                                                )
                                                buildKaraokeSheetLine(line: line, activeWordIndex: activeWordIdx)
                                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                                    .shadow(color: .white.opacity(0.25), radius: 8, x: 0, y: 0)
                                                    .multilineTextAlignment(.leading)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            } else {
                                                Text(line.text)
                                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                                    .foregroundColor(.white.opacity(max(0.22, 0.48 - Double(distance) * 0.08)))
                                                    .blur(radius: min(CGFloat(distance) * 1.35, 4.8))
                                                    .scaleEffect(0.96, anchor: .leading)
                                                    .multilineTextAlignment(.leading)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .id(line.index)
                                        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: currentIdx)
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

    private func buildKaraokeSheetLine(line: LyricLine, activeWordIndex: Int) -> Text {
        var combined = Text("")
        for (wIdx, word) in line.words.enumerated() {
            let space = (wIdx == line.words.count - 1) ? "" : " "
            let isSung = wIdx <= activeWordIndex
            combined = combined + Text(word + space)
                .foregroundColor(isSung ? .white : .white.opacity(0.42))
        }
        return combined
    }
}

// MARK: - Playlist Cover View
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

// MARK: - Root Tab View (Clean Without Dynamic Island Overlay)
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
                        Label("Wi-Fi / URL", systemImage: "wifi.circle.fill")
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
        .fullScreenCover(isPresented: $engine.isIPodModeActive) {
            FullScreenIPodClassicModeView(engine: engine, progress: engine.progress) {
                engine.isIPodModeActive = false
            }
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
                                HStack(spacing: 16) {
                                    PlaylistArtworkThumbnailView(
                                        playlist: playlist,
                                        tracks: pTracks,
                                        size: 64,
                                        cornerRadius: 12
                                    )
                                    .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(playlist.name)
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(.white)
                                        Text("\(pTracks.count) songs")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
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

// MARK: - Clean Full-Bleed Playlist Detail View
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
                VStack(spacing: 18) {
                    HStack(alignment: .center, spacing: 18) {
                        if let p = playlist {
                            PlaylistArtworkThumbnailView(
                                playlist: p,
                                tracks: allPlaylistTracks,
                                size: 116,
                                cornerRadius: 16
                            )
                            .shadow(color: .black.opacity(0.55), radius: 12, x: 0, y: 6)
                            .onTapGesture {
                                showEditPlaylistSheet = true
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("PLAYLIST")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.4)
                                .foregroundColor(.white.opacity(0.60))

                            Text(playlist?.name ?? "Playlist")
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(2)

                            Text("\(allPlaylistTracks.count) songs • \(totalMinutes) min")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.white.opacity(0.72))
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 12) {
                        Button {
                            showSongPicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Add Songs")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.14))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            showEditPlaylistSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Edit Cover")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
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
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "shuffle")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(engine.isShuffle ? .purple : .white)
                            }
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
                                    .frame(width: 52, height: 52)
                                    .shadow(color: .purple.opacity(0.45), radius: 8, x: 0, y: 4)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(
                    LinearGradient(
                        colors: [headerGradientColors.first ?? .purple.opacity(0.45), Color(red: 0.06, green: 0.06, blue: 0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                if tracks.isEmpty {
                    VStack(spacing: 10) {
                        Text("No songs in this playlist yet.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("Tap '+ Add Songs' above to pick tracks") {
                            showSongPicker = true
                        }
                        .font(.caption.weight(.bold))
                        .foregroundColor(.purple)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        TrackRowView(indexNumber: idx + 1, track: track) {
                            engine.playTrack(track, in: tracks)
                            showFullPlayer = true
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.white.opacity(0.08))
                    }
                    .onDelete { offsets in
                        offsets.forEach { idx in
                            engine.removeTrack(fileName: tracks[idx].fileName, from: playlistID)
                        }
                    }
                }
            }
            .listStyle(.plain)
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
                            .font(.system(size: 54))
                            .foregroundColor(.purple)
                        Text("No Songs Found")
                            .font(.headline)
                        Text("Import audio files from the Files app, or use the Wi-Fi Browser Drop in the Wi-Fi / URL tab.")
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
                            TrackRowView(indexNumber: nil, track: track) {
                                let snapshotQueue = filteredTracks
                                engine.playTrack(track, in: snapshotQueue)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    showFullPlayer = true
                                }
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
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search songs or artists...")
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

// MARK: - Enlarged Track Row View
struct TrackRowView: View {
    let indexNumber: Int?
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                if let num = indexNumber {
                    Text("\(num)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, alignment: .center)
                }

                if let uiImage = ArtworkCache.shared.artwork(for: track.fileName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 58, height: 58)
                        .overlay(Image(systemName: "music.note").font(.title3).foregroundColor(.gray))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(track.formattedDuration)
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
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
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.3))
                    .frame(width: 44, height: 44)
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

// MARK: - Full-Screen Player (Clean Top Bar + Scroll-Down Lyrics Card + Sticky Pinned 4-Column Bottom Bar)
struct FullPlayerDeckView: View {
    @ObservedObject var engine: MusiQEngine
    @Binding var isPresented: Bool

    @StateObject private var motion = MotionTiltManager()
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
            let artBoxSize = min(safeWidth - 76, 264)

            ZStack {
                LinearGradient(
                    colors: dynamicAlbumGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.65), value: engine.currentTrack?.fileName)

                VStack(spacing: 0) {
                    // Clean Top Bar (Grabber Capsule Restored)
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
                    .padding(.bottom, 6)

                    // Scrollable Main Player Stage + Scroll-Down Lyrics Card
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) {
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
                            .padding(.top, 2)

                            Spacer(minLength: 6)

                            // Value-Captured Visualizer Stage
                            ZStack {
                                if let activeTrack = engine.currentTrack {
                                    let capturedPalette = ArtworkCache.shared.cassettePalette(for: activeTrack.fileName)
                                    PlayerVisualizerStage(
                                        mode: engine.visualMode,
                                        track: activeTrack,
                                        isPlaying: engine.isPlaying,
                                        boxSize: artBoxSize,
                                        refreshID: engine.artworkRefreshID,
                                        zonePalette: capturedPalette
                                    )
                                    .id(activeTrack.fileName)
                                    .transition(
                                        .asymmetric(
                                            insertion: .offset(x: engine.skipTransitionDirection >= 0 ? 140 : -140)
                                                .combined(with: .scale(scale: 0.86))
                                                .combined(with: .opacity),
                                            removal: .offset(x: engine.skipTransitionDirection >= 0 ? -140 : 140)
                                                .combined(with: .scale(scale: 0.86))
                                                .combined(with: .opacity)
                                        )
                                    )
                                }
                            }
                            .rotation3DEffect(.degrees(motion.pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                            .rotation3DEffect(.degrees(motion.roll), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                            .offset(x: CGFloat(motion.roll * 1.3), y: CGFloat(motion.pitch * 1.3))
                            .frame(width: safeWidth - 16, height: artBoxSize + 10)
                            .padding(.bottom, 20)

                            if let err = engine.playbackErrorMessage {
                                Text(err)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)
                            }

                            // Song Title + Artist
                            VStack(spacing: 4) {
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

                            // Inline Synced Lyrics right under the Artist Name
                            WordByWordInlineLyricView(
                                progress: engine.progress,
                                lines: engine.currentTrackLyrics,
                                autoOffset: engine.autoDetectedLyricOffset,
                                isFetching: engine.isFetchingLyricsInBackground
                            ) {
                                activeBottomSheet = .lyrics
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 2)

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
                            .padding(.bottom, 16)

                            // Scroll-Down Spotify-Style Lyrics Card
                            ScrollDownLyricsPreviewCard(
                                progress: engine.progress,
                                lines: engine.currentTrackLyrics,
                                autoOffset: engine.autoDetectedLyricOffset,
                                isFetching: engine.isFetchingLyricsInBackground,
                                cardTint: dynamicAlbumGradient.first ?? .purple
                            ) {
                                activeBottomSheet = .lyrics
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                        }
                    }

                    // Pinned, Non-Scrolling Symmetrically Centered 4-Column Bottom Bar (DSP, Tags, Queue, Source)
                    HStack(spacing: 0) {
                        Button {
                            activeBottomSheet = .dsp
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: "dial.high.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 24, height: 24)
                                Text("DSP")
                                    .font(.caption2.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.white.opacity(0.88))
                        }

                        Button {
                            activeBottomSheet = .tagEditor
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: "tag.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 24, height: 24)
                                Text("Tags")
                                    .font(.caption2.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.white.opacity(0.88))
                        }

                        Button {
                            activeBottomSheet = .queue
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 24, height: 24)
                                Text("Queue")
                                    .font(.caption2.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.white.opacity(0.88))
                        }

                        VStack(spacing: 5) {
                            ZStack {
                                AudioSourcePickerButton()
                                    .frame(width: 24, height: 24)
                            }
                            .frame(width: 24, height: 24)
                            Text("Source")
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.white.opacity(0.88))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Color.black.opacity(0.28)
                            .background(.ultraThinMaterial.opacity(0.5))
                            .ignoresSafeArea(edges: .bottom)
                    )
                }
            }
            .offset(x: max(0, dragOffset.width), y: 0)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.width > abs(value.translation.height) && value.translation.width > 0 {
                            dragOffset = value.translation
                        }
                    }
                    .onEnded { value in
                        if value.translation.width > 95 && value.translation.width > abs(value.translation.height) {
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
    let track: Track
    let isPlaying: Bool
    let boxSize: CGFloat
    let refreshID: UUID
    let zonePalette: [Color]

    var artworkImage: UIImage? {
        let _ = refreshID
        return ArtworkCache.shared.artwork(for: track.fileName)
    }

    var body: some View {
        ZStack {
            switch mode {
            case .sleeve:
                sleeveCover(size: boxSize)

            case .cassette:
                multiColorPaletteCassetteView(width: boxSize * 1.12, height: boxSize * 0.72)

            case .sideVinyl:
                let sleeveDim = boxSize * 0.80
                let vinylDim = boxSize * 0.78
                HStack(spacing: -vinylDim * 0.44) {
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
                                .shadow(color: .black.opacity(0.5), radius: 10, x: 4, y: 6)

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
                                    .fill(zonePalette[2])
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
    private func multiColorPaletteCassetteView(width: CGFloat, height: CGFloat) -> some View {
        let reelSize = height * 0.36
        let cLeft = zonePalette.indices.contains(0) ? zonePalette[0] : .white
        let cMidLeft = zonePalette.indices.contains(1) ? zonePalette[1] : .yellow
        let cCenter = zonePalette.indices.contains(2) ? zonePalette[2] : .orange
        let cMidRight = zonePalette.indices.contains(3) ? zonePalette[3] : .yellow
        let cRight = zonePalette.indices.contains(4) ? zonePalette[4] : .white

        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: cLeft.opacity(0.85), location: 0.0),
                            .init(color: cMidLeft.opacity(0.80), location: 0.24),
                            .init(color: cCenter.opacity(0.85), location: 0.50),
                            .init(color: cMidRight.opacity(0.80), location: 0.76),
                            .init(color: cRight.opacity(0.85), location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.ultraThinMaterial)
                )
                .frame(width: width, height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            LinearGradient(
                                colors: [cLeft.opacity(0.9), cMidLeft, cCenter, cRight.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2.2
                        )
                )
                .shadow(color: .black.opacity(0.55), radius: 16, x: 0, y: 10)

            VStack {
                HStack {
                    cassetteScrew()
                    Spacer()
                    cassetteScrew()
                }
                Spacer()
                HStack {
                    cassetteScrew()
                    Spacer()
                    cassetteScrew()
                }
            }
            .padding(12)
            .frame(width: width, height: height)

            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: cLeft, location: 0.0),
                                .init(color: cLeft.opacity(0.95), location: 0.14),
                                .init(color: cMidLeft, location: 0.30),
                                .init(color: cCenter, location: 0.50),
                                .init(color: cMidRight, location: 0.70),
                                .init(color: cRight.opacity(0.95), location: 0.86),
                                .init(color: cRight, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 0.88, height: height * 0.62)
                    .overlay(
                        VStack(spacing: 3) {
                            Spacer()
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [cMidLeft, cCenter, cMidRight],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(height: 5)
                                .opacity(0.85)
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [cCenter, cMidLeft, cCenter],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(height: 3)
                                .opacity(0.75)
                        }
                        .padding(.bottom, 8)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color.black.opacity(0.28), lineWidth: 1.2)
                    )

                VStack {
                    HStack {
                        Text("SIDE A")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Spacer()

                        Text("HI-BIAS CrO2")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(.white.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
                    Spacer()
                }
                .frame(width: width * 0.88, height: height * 0.62)

                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.black.opacity(0.82), cCenter.opacity(0.45), Color.black.opacity(0.82)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width * 0.68, height: reelSize + 14)
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.35), lineWidth: 1.3)
                        )

                    HStack(spacing: width * 0.14) {
                        Circle()
                            .fill(Color(red: 0.12, green: 0.08, blue: 0.07).opacity(0.92))
                            .frame(width: reelSize * 1.25, height: reelSize * 1.25)
                        Circle()
                            .fill(Color(red: 0.12, green: 0.08, blue: 0.07).opacity(0.92))
                            .frame(width: reelSize * 1.05, height: reelSize * 1.05)
                    }
                    .clipShape(Capsule().scale(0.95))

                    HStack(spacing: width * 0.16) {
                        ContinuousSpinView(isSpinning: isPlaying, rpm: 20.0) {
                            cassetteSpindleWheel(size: reelSize, accent: cMidLeft)
                        }
                        ContinuousSpinView(isSpinning: isPlaying, rpm: 20.0) {
                            cassetteSpindleWheel(size: reelSize, accent: cMidRight)
                        }
                    }
                }
                .offset(y: 4)
            }
            .offset(y: -height * 0.08)

            VStack {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [Color.black.opacity(0.62), cCenter.opacity(0.45), Color.black.opacity(0.62)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width * 0.66, height: height * 0.20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                        )

                    HStack(spacing: 16) {
                        Circle().fill(Color.black.opacity(0.8)).frame(width: 9, height: 9)
                        Text(track.title.uppercased())
                            .font(.system(size: 8.5, weight: .black, design: .monospaced))
                            .foregroundColor(.white.opacity(0.90))
                            .lineLimit(1)
                            .frame(maxWidth: width * 0.40)
                        Circle().fill(Color.black.opacity(0.8)).frame(width: 9, height: 9)
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private func cassetteSpindleWheel(size: CGFloat, accent: Color) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.92), lineWidth: 3.5)
                .frame(width: size, height: size)

            Circle()
                .stroke(accent.opacity(0.75), lineWidth: 2)
                .frame(width: size * 0.72, height: size * 0.72)

            ForEach(0..<6, id: \.self) { idx in
                Rectangle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 3, height: size * 0.32)
                    .offset(y: -size * 0.30)
                    .rotationEffect(.degrees(Double(idx) * 60.0))
            }

            Circle()
                .fill(Color.black.opacity(0.7))
                .frame(width: size * 0.40, height: size * 0.40)
        }
    }

    @ViewBuilder
    private func cassetteScrew() -> some View {
        Circle()
            .fill(Color.white.opacity(0.42))
            .frame(width: 7, height: 7)
            .overlay(
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 5, height: 1)
                    .rotationEffect(.degrees(45))
            )
    }

    @ViewBuilder
    private func sleeveCover(size: CGFloat) -> some View {
        if let img = artworkImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 8)
        } else {
            RoundedRectangle(cornerRadius: 20)
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

// MARK: - Tab 3: iPod Mode Switch + Wi-Fi Browser Upload Bridge + Direct Cloud Audio URL Importer
struct DirectAudioImporterView: View {
    @ObservedObject var engine: MusiQEngine
    @StateObject private var wifiServer = WiFiUploadServer()

    @State private var urlInput: String = ""
    @State private var customTitle: String = ""
    @State private var customArtist: String = ""
    @State private var statusMessage: String = "Use Wi-Fi Browser Drop above, or paste a direct audio file link below."
    @State private var isDownloading: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                // 1. Full-Screen Standalone iPod Classic Mode Switch
                Section("Classic Hardware Mode") {
                    Toggle(isOn: $engine.isIPodModeActive) {
                        Label("iPod Mode", systemImage: "ipod")
                            .font(.headline)
                    }
                    .tint(.purple)

                    Text("Transforms MusiQ into a full-screen 5th Gen iPod Classic with a tactile Click Wheel. Tap 'Quit iPod' in the top-left corner to return.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // 2. Local Wi-Fi Browser Drag & Drop Server Section
                Section("Wi-Fi Browser Drag & Drop Bridge") {
                    Toggle(isOn: Binding(
                        get: { wifiServer.isRunning },
                        set: { _ in
                            wifiServer.onFileUploaded = {
                                engine.scanLocalLibrary()
                            }
                            wifiServer.toggleServer()
                        }
                    )) {
                        Label("Start Wi-Fi Upload Server", systemImage: "wifi")
                            .font(.headline)
                    }
                    .tint(.purple)

                    if wifiServer.isRunning {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Open this address in Chrome or Safari on your computer (on the same Wi-Fi):")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Text(wifiServer.serverURLString)
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    .foregroundColor(.purple)
                                Spacer()
                                Button("Copy") {
                                    UIPasteboard.general.string = wifiServer.serverURLString
                                }
                                .font(.caption.bold())
                                .buttonStyle(.bordered)
                                .tint(.purple)
                            }

                            if wifiServer.uploadedCount > 0 {
                                Text("✅ Received \(wifiServer.uploadedCount) file(s) • Last: \(wifiServer.lastUploadedFile)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // 3. Direct & Cloud Audio URL Importer
                Section("Direct Audio File or Cloud Share Link") {
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
            .navigationTitle("Wi-Fi & Modes")
        }
    }

    private func normalizeCloudAudioURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("dropbox.com") {
            s = s.replacingOccurrences(of: "?dl=0", with: "?dl=1")
            if !s.contains("dl=1") {
                s += (s.contains("?") ? "&dl=1" : "?dl=1")
            }
        }
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

                guard let verifyFile = try? AVAudioFile(forReading: destinationURL) else {
                    try? FileManager.default.removeItem(at: destinationURL)
                    throw NSError(domain: "MusiQ", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "URL did not point to a valid direct audio file. Use the Wi-Fi Browser Drop above or Files importer."
                    ])
                }

                let exactDuration = Double(verifyFile.length) / max(verifyFile.processingFormat.sampleRate, 1)
                ArtworkCache.shared.saveCustomMetadata(title: resolvedTitle, artist: resolvedArtist, for: safeFileName)

                if let res = await LyricsManager.shared.fetchVersionMatchedLyrics(
                    title: resolvedTitle,
                    artist: resolvedArtist,
                    targetDuration: exactDuration
                ) {
                    let tempTrack = Track(id: UUID(), title: resolvedTitle, artist: resolvedArtist, fileName: safeFileName, duration: exactDuration)
                    LyricsManager.shared.saveLyrics(res.lyrics, matchedDuration: res.matchedDuration, for: tempTrack)
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
                                            .frame(width: 44, height: 44)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    } else {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.white.opacity(0.1))
                                            .frame(width: 44, height: 44)
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
