// Writes a frame as HEIC with Apple's hardware HEVC encoder, for
// `filmscan --encoder apple`. `rake apple_heic` builds it into libexec/.
//
//   apple-heic --qp N [--bits 8|10] [--threads N] [--check | --report] [--times] IN.png OUT.heic
//
// The frame is coded as a grid of 2048px tiles, each its own HEVC picture,
// since libde265 (behind libheif, libvips and most viewers outside Apple's)
// cannot open a picture over about 16 MB. Colour is 4:4:4 in full range
// BT.601, as heif-enc writes it, and a grey PNG is written as monochrome. The
// PNG's ICC profile and Exif go in unchanged.
//
// A frame denser than the encoder has been seen to code cleanly is refused
// with exit status 3 before any encoder session exists: a frame of noise
// hung the encoder and the kernel panicked. --check prints the readings the
// guard goes on and stops; --report prints them with each tile's coded size.
//
// Apple's own decoder reads this monochrome as colour, with red and blue a
// level below green, so filmscan gives black and white frames to heif-enc.
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("apple-heic: \(message)\n".utf8))
    exit(status)
}

// What the hardware encoder has coded cleanly: 31 of the owner's real frames
// at QP 1, the densest 2.13 bytes a pixel in a tile and the least detailed
// 0.32 times its grain, each held 10% short of that. Predicted density is
// bytes a pixel in a frame's densest tile, and detail is how far its busiest
// blocks rise above its grain, as a multiple of the grain. Only 10-bit colour
// was measured. Built with -D CALIBRATE the guard is off, for measuring new
// frames, and only then.
enum Guard {
    static let maxDensity = 1.85
    static let minDetail = 0.35
    // Bits at QP 1, fitted to those frames' coded tiles: a base a pixel, and a
    // slope on log2(1 + each sample's median predictor residual).
    static let luma = (base: -0.5487, slope: 1.5579)
    static let chroma = (base: 0.0, slope: 1.4895)
}

struct Options {
    var qp = -1
    var bits: Int?
    var threads = ProcessInfo.processInfo.activeProcessorCount
    var check = false
    var report = false
    var times = false
    var maxDensity = Guard.maxDensity
    var minDetail = Guard.minDetail
    var input = ""
    var output = ""

    init(_ arguments: [String]) {
        let usage = "usage: apple-heic --qp N [--bits 8|10] [--threads N] [--check | --report] [--times] IN.png OUT.heic"
        var rest = arguments.makeIterator()
        var paths: [String] = []
        func number() -> Double {
            guard let text = rest.next(), let value = Double(text) else { fail(usage) }
            return value
        }
        while let argument = rest.next() {
            switch argument {
            case "--qp": qp = Int(number())
            case "--bits": bits = Int(number())
            case "--threads": threads = Int(number())
            case "--check": check = true
            case "--report": report = true
            case "--times": times = true
            // Only ever stricter than what was tested.
            case "--max-density": maxDensity = number()
            case "--min-detail": minDetail = number()
            default:
                if argument.hasPrefix("--") { fail(usage) }
                paths.append(argument)
            }
        }
        guard paths.count == (check ? 1 : 2) else { fail(usage) }
        guard (0...51).contains(qp) else { fail("--qp must be 0 to 51") }
        guard bits == nil || bits == 8 || bits == 10 else { fail("--bits must be 8 or 10") }
        guard threads > 0 else { fail(usage) }
        guard maxDensity <= Guard.maxDensity, minDetail >= Guard.minDetail else { fail("the guard can only be made stricter") }
        input = paths[0]
        output = check ? "" : paths[1]
    }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))
let started = Date()
func lap(_ what: String) {
    if options.times { FileHandle.standardError.write(Data(String(format: "%@ %.3fs\n", what, Date().timeIntervalSince(started)).utf8)) }
}

// MARK: Reading the PNG

struct Picture {
    let width: Int
    let height: Int
    let grey: Bool
    let deep: Bool
    // Four 16-bit samples a pixel in colour, the last unused, and one in grey.
    let samples: [UInt16]
    var stride: Int { grey ? 1 : 4 }
}

func readPicture(_ path: String) -> Picture {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = image.colorSpace else { fail("cannot read \(path)") }
    let grey: Bool
    switch space.model {
    case .monochrome: grey = true
    case .rgb: grey = false
    default: fail("\(path) is neither grey nor RGB")
    }
    let width = image.width, height = image.height, stride = grey ? 1 : 4
    var samples = [UInt16](repeating: 0, count: width * height * stride)
    // Drawn in its own colour space, so the samples come through unconverted.
    let info = (grey ? CGImageAlphaInfo.none : .noneSkipLast).rawValue | CGBitmapInfo.byteOrder16Little.rawValue
    let drawn = samples.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 16,
                                      bytesPerRow: width * stride * 2, space: space, bitmapInfo: info) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { fail("cannot unpack \(path)") }
    return Picture(width: width, height: height, grey: grey, deep: image.bitsPerComponent > 8, samples: samples)
}

// The ICC profile and Exif, read from the PNG's chunks so their bytes go in
// as they are. Both come before the pixels in the PNGs libvips writes.
func readMetadata(_ path: String) -> (icc: Data?, exif: Data?) {
    guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
    defer { try? file.close() }
    var icc: Data?, exif: Data?
    guard let signature = try? file.read(upToCount: 8), signature.count == 8 else { return (nil, nil) }
    while let header = try? file.read(upToCount: 8), header.count == 8 {
        let length = header.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        let type = String(decoding: header.suffix(4), as: UTF8.self)
        if type == "IDAT" || type == "IEND" { break }
        guard let body = try? file.read(upToCount: length + 4), body.count == length + 4 else { break }
        if type == "iCCP" { icc = inflateProfile(body.prefix(length)) }
        if type == "eXIf" { exif = Data(body.prefix(length)) }
    }
    return (icc, exif)
}

// An iCCP chunk is a name, a nul, a method byte and a zlib stream; Foundation
// inflates the raw deflate inside it.
func inflateProfile(_ chunk: Data) -> Data? {
    let chunk = Data(chunk)
    guard let nul = chunk.firstIndex(of: 0), chunk.count > nul + 8 else { return nil }
    let deflate = chunk.subdata(in: (nul + 4)..<(chunk.count - 4))
    return try? (deflate as NSData).decompressed(using: .zlib) as Data
}

// MARK: Tiles

struct Layout {
    let tileWidth: Int
    let tileHeight: Int
    let columns: Int
    let rows: Int
    var count: Int { columns * rows }

    // Tiles no bigger than the frame needs, so a small frame is not padded
    // out to a whole tile.
    init(width: Int, height: Int, tile: Int) {
        tileWidth = min(tile, (width + 63) / 64 * 64)
        tileHeight = min(tile, (height + 63) / 64 * 64)
        columns = (width + tileWidth - 1) / tileWidth
        rows = (height + tileHeight - 1) / tileHeight
        guard columns <= 256, rows <= 256 else { fail("a \(width)x\(height) frame needs more than 256 tiles a side") }
    }
}

struct Format {
    let pixels: OSType
    let profile: String
    let chroma: Int
    let depth: Int

    init(grey: Bool, deep: Bool) {
        switch (grey, deep) {
        case (false, true): (pixels, profile) = (kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, "HEVC_Main44410_AutoLevel")
        case (false, false): (pixels, profile) = (kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, "HEVC_Main444_AutoLevel")
        case (true, true): (pixels, profile) = (kCVPixelFormatType_OneComponent10, "HEVC_Monochrome10_AutoLevel")
        case (true, false): (pixels, profile) = (kCVPixelFormatType_OneComponent8, "HEVC_Monochrome_AutoLevel")
        }
        chroma = grey ? 0 : 3
        depth = deep ? 10 : 8
    }
}

// Luma, and Cb and Cr side by side, or the one plane of a grey tile, each
// with its bytes a row. The buffer has to be locked.
func planesOf(_ buffer: CVPixelBuffer) -> (UnsafeMutableRawPointer, Int, UnsafeMutableRawPointer?, Int) {
    CVPixelBufferIsPlanar(buffer)
        ? (CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
           CVPixelBufferGetBaseAddressOfPlane(buffer, 1), CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        : (CVPixelBufferGetBaseAddress(buffer)!, CVPixelBufferGetBytesPerRow(buffer), nil, 0)
}

// Full range BT.601, heif-enc's default: Y over the whole range, Cb and Cr
// centred on half of it, each rounded to the nearest level.
let kr = 0.299, kb = 0.114, kg = 1 - kr - kb
func makeTiles(_ picture: Picture, _ layout: Layout, _ format: Format, threads: Int) -> [CVPixelBuffer] {
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
    let buffers = (0..<layout.count).map { _ -> CVPixelBuffer in
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, layout.tileWidth, layout.tileHeight, format.pixels, attributes, &buffer)
        guard let buffer else { fail("cannot make a \(layout.tileWidth)x\(layout.tileHeight) tile") }
        CVPixelBufferLockBaseAddress(buffer, [])
        return buffer
    }
    defer { buffers.forEach { CVPixelBufferUnlockBaseAddress($0, []) } }
    let planes = buffers.map(planesOf)

    let top = Double((1 << format.depth) - 1), half = Double(1 << (format.depth - 1))
    let scale = top / 65535, shift = format.depth == 10 ? 6 : 0
    let lines = layout.rows * layout.tileHeight
    let (width, height, step, grey) = (picture.width, picture.height, picture.stride, picture.grey)

    func fill<Sample: FixedWidthInteger>(_: Sample.Type, _ samples: UnsafeBufferPointer<UInt16>) {
        let size = MemoryLayout<Sample>.size
        func level(_ value: Double) -> Sample { Sample(Int(max(0, min(top, value.rounded()))) << shift) }
        DispatchQueue.concurrentPerform(iterations: threads) { part in
            for line in stride(from: part, to: lines, by: threads) {
                let source = min(line, height - 1) * width
                let row = line % layout.tileHeight
                for column in 0..<layout.columns {
                    let (luma, lumaStride, chroma, chromaStride) = planes[line / layout.tileHeight * layout.columns + column]
                    let y = luma + row * lumaStride
                    let c = chroma.map { $0 + row * chromaStride }
                    let left = column * layout.tileWidth
                    for x in 0..<layout.tileWidth {
                        let at = (source + min(left + x, width - 1)) * step
                        if grey {
                            y.storeBytes(of: level(Double(samples[at]) * scale), toByteOffset: x * size, as: Sample.self)
                            continue
                        }
                        let r = Double(samples[at]) * scale, g = Double(samples[at + 1]) * scale, b = Double(samples[at + 2]) * scale
                        let luminance = kr * r + kg * g + kb * b
                        y.storeBytes(of: level(luminance), toByteOffset: x * size, as: Sample.self)
                        c!.storeBytes(of: level((b - luminance) / (2 * (1 - kb)) + half), toByteOffset: 2 * x * size, as: Sample.self)
                        c!.storeBytes(of: level((r - luminance) / (2 * (1 - kr)) + half), toByteOffset: (2 * x + 1) * size, as: Sample.self)
                    }
                }
            }
        }
    }
    picture.samples.withUnsafeBufferPointer { samples in
        if format.depth == 10 { fill(UInt16.self, samples) } else { fill(UInt8.self, samples) }
    }
    return buffers
}

// MARK: Readings

// How busy a tile is, from each sample's distance from the median edge
// predictor: a cheap stand-in for what an intra coder pays for it.
struct TileReading {
    var lumaLog = 0.0, chromaLog = 0.0
    var lumaSum = 0.0, chromaSum = 0.0
    var lumaSamples = 0, chromaSamples = 0

    static func + (a: TileReading, b: TileReading) -> TileReading {
        TileReading(lumaLog: a.lumaLog + b.lumaLog, chromaLog: a.chromaLog + b.chromaLog,
                    lumaSum: a.lumaSum + b.lumaSum, chromaSum: a.chromaSum + b.chromaSum,
                    lumaSamples: a.lumaSamples + b.lumaSamples, chromaSamples: a.chromaSamples + b.chromaSamples)
    }

    // Bytes a pixel at QP 1, from the calibrated bits a sample.
    var predicted: Double {
        func bits(_ model: (base: Double, slope: Double), _ logged: Double, _ count: Int) -> Double {
            count == 0 ? 0 : max(0, model.base + model.slope * logged / Double(count))
        }
        return (bits(Guard.luma, lumaLog, lumaSamples) + 2 * bits(Guard.chroma, chromaLog, chromaSamples)) / 8
    }
}

struct Readings {
    let tiles: [TileReading]
    // The mean luma residual of each 64px block inside the frame's 5% inset.
    let blocks: [Double]

    var densest: Double { tiles.map(\.predicted).max() ?? 0 }

    // How far the busiest 2% of blocks rise above the quietest tenth, which
    // hold grain alone, as a multiple of it. Noise everywhere reads near 0.
    var detail: Double {
        let sorted = blocks.sorted()
        guard !sorted.isEmpty else { return 0 }
        let floor = sorted[sorted.count / 10]
        let busiest = sorted.suffix(max(1, sorted.count / 50))
        return (busiest.reduce(0, +) / Double(busiest.count) - floor) / max(floor, 1e-9)
    }
}

func measure(_ tiles: [CVPixelBuffer], _ layout: Layout, _ format: Format, _ picture: Picture) -> Readings {
    tiles.forEach { CVPixelBufferLockBaseAddress($0, .readOnly) }
    defer { tiles.forEach { CVPixelBufferUnlockBaseAddress($0, .readOnly) } }
    let planes = tiles.map(planesOf)
    let bands = layout.tileHeight / 64, columns = layout.tileWidth / 64, jobs = layout.count * bands
    let shift = format.depth == 10 ? 6 : 0
    let logs = (0...1023).map { log2(1 + Double($0)) }
    var parts = [TileReading](repeating: TileReading(), count: jobs)
    var sums = [Double](repeating: 0, count: jobs * columns)

    func run<Sample: FixedWidthInteger>(_: Sample.Type) {
        let size = MemoryLayout<Sample>.size
        parts.withUnsafeMutableBufferPointer { parts in
            sums.withUnsafeMutableBufferPointer { sums in
                // One band of 64 rows of one tile at a time.
                DispatchQueue.concurrentPerform(iterations: jobs) { job in
                    let (luma, lumaStride, chroma, chromaStride) = planes[job / bands]
                    let top = job % bands * 64
                    var reading = TileReading()
                    var blockSums = [Double](repeating: 0, count: columns)
                    func pass(_ base: UnsafeMutableRawPointer, _ stride: Int, _ channels: Int, _ channel: Int, luma: Bool) {
                        func at(_ x: Int, _ y: Int) -> Int {
                            Int(base.load(fromByteOffset: y * stride + (x * channels + channel) * size, as: Sample.self)) >> shift
                        }
                        var total = 0.0, logged = 0.0, count = 0
                        for y in max(top, 1)..<(top + 64) {
                            for x in 1..<layout.tileWidth {
                                let a = at(x - 1, y), b = at(x, y - 1), c = at(x - 1, y - 1)
                                let guess = c >= max(a, b) ? min(a, b) : c <= min(a, b) ? max(a, b) : a + b - c
                                let residual = min(abs(at(x, y) - guess), 1023)
                                total += Double(residual)
                                logged += logs[residual]
                                count += 1
                                if luma { blockSums[x / 64] += Double(residual) }
                            }
                        }
                        if luma {
                            (reading.lumaSum, reading.lumaLog, reading.lumaSamples) = (total, logged, count)
                        } else {
                            reading.chromaSum += total
                            reading.chromaLog += logged
                            reading.chromaSamples += count
                        }
                    }
                    pass(luma, lumaStride, 1, 0, luma: true)
                    if let chroma {
                        pass(chroma, chromaStride, 2, 0, luma: false)
                        pass(chroma, chromaStride, 2, 1, luma: false)
                    }
                    parts[job] = reading
                    for column in 0..<columns { sums[job * columns + column] = blockSums[column] }
                }
            }
        }
    }
    if format.depth == 10 { run(UInt16.self) } else { run(UInt8.self) }

    let readings = (0..<layout.count).map { tile in parts[(tile * bands)..<((tile + 1) * bands)].reduce(TileReading(), +) }
    let insetX = picture.width / 20, insetY = picture.height / 20
    var blocks: [Double] = []
    for job in 0..<jobs {
        let tile = job / bands
        let top = tile / layout.columns * layout.tileHeight + job % bands * 64
        for column in 0..<columns {
            let left = tile % layout.columns * layout.tileWidth + column * 64
            if left >= insetX && left + 64 <= picture.width - insetX && top >= insetY && top + 64 <= picture.height - insetY {
                blocks.append(sums[job * columns + column] / 4096)
            }
        }
    }
    return Readings(tiles: readings, blocks: blocks)
}

func verdict(_ readings: Readings) -> String? {
    if format.depth != 10 || format.chroma != 3 {
        return "only 10-bit colour has been measured on the hardware encoder"
    }
    if readings.densest > options.maxDensity {
        return String(format: "too dense for the hardware encoder: %.2f bytes a pixel predicted, past the %.2f it has coded cleanly",
                      readings.densest, options.maxDensity)
    }
    if readings.detail < options.minDetail {
        return String(format: "more grain than picture for the hardware encoder: detail %.2f times its grain, under the %.2f it has coded cleanly",
                      readings.detail, options.minDetail)
    }
    return nil
}

// One line of JSON on standard output, for calibrating the guard.
func report(_ readings: Readings, _ refusal: String?, coded: [Int]?) {
    let tiles = readings.tiles.enumerated().map { index, tile -> [String: Any] in
        var row: [String: Any] = ["lumaLog": tile.lumaLog, "chromaLog": tile.chromaLog, "lumaSum": tile.lumaSum,
                                  "chromaSum": tile.chromaSum, "lumaSamples": tile.lumaSamples,
                                  "chromaSamples": tile.chromaSamples, "predicted": tile.predicted]
        if let coded { row["bytes"] = coded[index] }
        return row
    }
    let line: [String: Any] = ["width": picture.width, "height": picture.height, "tileWidth": layout.tileWidth,
                               "tileHeight": layout.tileHeight, "densest": readings.densest, "detail": readings.detail,
                               "refusal": refusal ?? NSNull(), "tiles": tiles]
    guard let json = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(json + Data("\n".utf8))
}

// MARK: Encoding

final class Coded: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var pictures: [Data?]
    private(set) var configs: [Data?]
    private(set) var problem: String?

    init(_ count: Int) {
        pictures = Array(repeating: nil, count: count)
        configs = Array(repeating: nil, count: count)
    }

    func keep(_ index: Int, _ status: OSStatus, _ sample: CMSampleBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample),
              let description = CMSampleBufferGetFormatDescription(sample) else {
            problem = problem ?? "the encoder gave no picture for tile \(index) (status \(status))"
            return
        }
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        pictures[index] = bytes
        configs[index] = atoms?["hvcC"] as? Data
    }
}

func makeSession(_ layout: Layout, _ format: Format, qp: Int, tagged: Bool) -> VTCompressionSession {
    var session: VTCompressionSession?
    let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
    VTCompressionSessionCreate(allocator: nil, width: Int32(layout.tileWidth), height: Int32(layout.tileHeight),
                               codecType: kCMVideoCodecType_HEVC, encoderSpecification: specification,
                               imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                               refcon: nil, compressionSessionOut: &session)
    guard let session else { fail("this Mac has no hardware HEVC encoder") }
    var properties: [(CFString, CFTypeRef)] = [
        (kVTCompressionPropertyKey_ProfileLevel, format.profile as CFString),
        (kVTCompressionPropertyKey_RealTime, kCFBooleanFalse),
        (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
        (kVTCompressionPropertyKey_MaxKeyFrameInterval, 1 as CFNumber),
        (kVTCompressionPropertyKey_MinAllowedFrameQP, qp as CFNumber),
        (kVTCompressionPropertyKey_MaxAllowedFrameQP, qp as CFNumber),
        (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4),
    ]
    // With no ICC profile the stream says sRGB, as the nclx box does.
    if !tagged {
        properties += [(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
                       (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)]
    }
    for (key, value) in properties where VTSessionSetProperty(session, key: key, value: value) != noErr {
        fail(key == kVTCompressionPropertyKey_ProfileLevel
             ? "this Mac's hardware encoder cannot write \(format.profile)" : "the hardware encoder refused \(key)")
    }
    VTCompressionSessionPrepareToEncodeFrames(session)
    return session
}

func encode(_ tiles: [CVPixelBuffer], _ layout: Layout, _ format: Format, qp: Int, tagged: Bool) -> (pictures: [Data], config: Data) {
    let coded = Coded(tiles.count)
    // One session, one tile after another, as the frames that coded cleanly were.
    let session = makeSession(layout, format, qp: qp, tagged: tagged)
    let key = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
    for (index, tile) in tiles.enumerated() {
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: tile,
                                                     presentationTimeStamp: CMTime(value: Int64(index), timescale: 1),
                                                     duration: .invalid, frameProperties: key, infoFlagsOut: nil) { status, _, sample in
            coded.keep(index, status, sample)
        }
        if status != noErr { fail("the encoder refused tile \(index) (status \(status))") }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(session)
    if let problem = coded.problem { fail(problem) }
    let pictures = coded.pictures.compactMap { $0 }
    let configs = Set(coded.configs.compactMap { $0 })
    guard pictures.count == tiles.count, configs.count == 1, let config = configs.first, config.count > 22 else {
        fail("the encoder's tiles do not share one configuration")
    }
    // The stream has to be what was asked for, not a conversion of it.
    let chroma = Int(config[16] & 3), depth = Int(config[17] & 7) + 8
    guard chroma == format.chroma, depth == format.depth else {
        fail("the encoder wrote chroma format \(chroma) at \(depth) bits, not \(format.chroma) at \(format.depth)")
    }
    return (pictures, config)
}

// MARK: The HEIF file

extension Data {
    mutating func u8(_ value: Int) { append(UInt8(truncatingIfNeeded: value)) }
    mutating func u16(_ value: Int) { u8(value >> 8); u8(value) }
    mutating func u32(_ value: Int) { u16(value >> 16); u16(value) }
    mutating func text(_ value: String) { append(contentsOf: Array(value.utf8)) }
}

func bytes(_ fill: (inout Data) -> Void) -> Data {
    var data = Data()
    fill(&data)
    return data
}

func box(_ type: String, _ body: Data) -> Data {
    bytes { $0.u32(8 + body.count); $0.text(type); $0.append(body) }
}

func fullBox(_ type: String, version: Int = 0, flags: Int = 0, _ body: Data) -> Data {
    box(type, bytes { $0.u8(version); $0.u8(flags >> 16); $0.u16(flags); $0.append(body) })
}

// Laid out as libheif lays out a grid: one hvcC shared by every tile, the
// colour on the grid and on each tile, and the grid's own record in idat.
func writeHeif(to path: String, pictures: [Data], config: Data, picture: Picture, layout: Layout, format: Format,
               icc: Data?, exif: Data?) {
    let grid = 1, tileIDs = pictures.indices.map { $0 + 2 }, exifID = pictures.count + 2
    let wide = picture.width > 65535 || picture.height > 65535
    let record = bytes {
        $0.u8(0); $0.u8(wide ? 1 : 0); $0.u8(layout.rows - 1); $0.u8(layout.columns - 1)
        if wide { $0.u32(picture.width); $0.u32(picture.height) } else { $0.u16(picture.width); $0.u16(picture.height) }
    }
    // Exif items start with the offset to the TIFF header.
    let exifItem = exif.map { exif in
        bytes { $0.u32(exif.starts(with: Data("Exif\0\0".utf8)) ? 6 : 0); $0.append(exif) }
    }

    var properties: [Data] = []
    func property(_ data: Data) -> Int { properties.append(data); return properties.count }
    let hvcC = property(box("hvcC", config))
    let tileSize = property(fullBox("ispe", bytes { $0.u32(layout.tileWidth); $0.u32(layout.tileHeight) }))
    let gridSize = property(fullBox("ispe", bytes { $0.u32(picture.width); $0.u32(picture.height) }))
    let channels = picture.grey ? 1 : 3
    let pixi = property(fullBox("pixi", bytes { $0.u8(channels); for _ in 0..<channels { $0.u8(format.depth) } }))
    // nclx gives the matrix and range; an ICC profile, where there is one,
    // gives the colours, so nclx leaves them unspecified then.
    let nclx = property(box("colr", bytes {
        $0.text("nclx"); $0.u16(icc == nil ? 1 : 2); $0.u16(icc == nil ? 13 : 2); $0.u16(6); $0.u8(0x80)
    }))
    let colour = [nclx] + (icc.map { icc in [property(box("colr", bytes { $0.text("prof"); $0.append(icc) }))] } ?? [])
    let associations = [(grid, [gridSize, pixi] + colour)]
        + tileIDs.map { ($0, [hvcC | 0x80, tileSize, pixi] + colour) }
    let iprp = box("iprp", box("ipco", properties.reduce(Data(), +)) + fullBox("ipma", bytes { out in
        out.u32(associations.count)
        for (item, list) in associations {
            out.u16(item); out.u8(list.count); list.forEach { out.u8($0) }
        }
    }))

    let infos = [fullBox("infe", version: 2, bytes { $0.u16(grid); $0.u16(0); $0.text("grid\0") })]
        + tileIDs.map { id in fullBox("infe", version: 2, flags: 1, bytes { $0.u16(id); $0.u16(0); $0.text("hvc1\0") }) }
        + (exifItem == nil ? [] : [fullBox("infe", version: 2, bytes { $0.u16(exifID); $0.u16(0); $0.text("Exif\0") })])
    let iinf = fullBox("iinf", bytes { out in out.u16(infos.count); infos.forEach { out.append($0) } })
    let iref = fullBox("iref", box("dimg", bytes { out in
        out.u16(grid); out.u16(tileIDs.count); tileIDs.forEach { out.u16($0) }
    }) + (exifItem == nil ? Data() : box("cdsc", bytes { $0.u16(exifID); $0.u16(1); $0.u16(grid) })))

    let ftyp = box("ftyp", bytes { $0.text("heix"); $0.u32(0); $0.text("mif1heixmiaf") })
    let payloads = pictures + (exifItem.map { [$0] } ?? [])
    let payloadIDs = tileIDs + (exifItem == nil ? [] : [exifID])
    func meta(mdat: Int) -> Data {
        // Version 1, four byte offsets and lengths; the grid record lives in idat.
        let iloc = fullBox("iloc", version: 1, bytes { out in
            out.u8(0x44); out.u8(0); out.u16(1 + payloads.count)
            out.u16(grid); out.u16(1); out.u16(0); out.u16(1); out.u32(0); out.u32(record.count)
            var offset = mdat + 8
            for (id, payload) in zip(payloadIDs, payloads) {
                out.u16(id); out.u16(0); out.u16(0); out.u16(1); out.u32(offset); out.u32(payload.count)
                offset += payload.count
            }
        })
        let handler = fullBox("hdlr", bytes { $0.u32(0); $0.text("pict"); $0.u32(0); $0.u32(0); $0.u32(0); $0.u8(0) })
        let primary = fullBox("pitm", bytes { $0.u16(grid) })
        return fullBox("meta", handler + primary + iloc + iinf + iref + iprp + box("idat", record))
    }
    let header = ftyp + meta(mdat: ftyp.count + meta(mdat: 0).count)
    let total = payloads.reduce(8) { $0 + $1.count }
    guard header.count + total <= Int(UInt32.max) else { fail("a HEIC over 4 GB is not written") }

    guard FileManager.default.createFile(atPath: path, contents: nil),
          let file = FileHandle(forWritingAtPath: path) else { fail("cannot write \(path)") }
    do {
        try file.write(contentsOf: header + bytes { $0.u32(total); $0.text("mdat") })
        for payload in payloads { try file.write(contentsOf: payload) }
        try file.close()
    } catch {
        try? FileManager.default.removeItem(atPath: path)
        fail("cannot write \(path): \(error.localizedDescription)")
    }
}

// MARK: Main

let picture = readPicture(options.input)
let (icc, exif) = readMetadata(options.input)
lap("read")
let format = Format(grey: picture.grey, deep: (options.bits ?? (picture.deep ? 10 : 8)) == 10)
let layout = Layout(width: picture.width, height: picture.height, tile: 2048)
let tiles = makeTiles(picture, layout, format, threads: options.threads)
lap("converted")
let readings = measure(tiles, layout, format, picture)
let refusal = verdict(readings)
lap("measured")
if options.check {
    report(readings, refusal, coded: nil)
    exit(0)
}
#if !CALIBRATE
if let refusal { fail(refusal, status: 3) }
#endif
let (pictures, config) = encode(tiles, layout, format, qp: options.qp, tagged: icc != nil)
lap("encoded")
if options.report { report(readings, refusal, coded: pictures.map(\.count)) }
writeHeif(to: options.output, pictures: pictures, config: config, picture: picture, layout: layout, format: format,
          icc: icc, exif: exif)
lap("written")
