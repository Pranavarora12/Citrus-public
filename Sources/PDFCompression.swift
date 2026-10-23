import Foundation
import AppKit
import PDFKit
import Quartz
import ImageIO
import zlib

/// Compression candidates are private until a readable, geometrically equivalent
/// document satisfies the requested size. No partially compressed file is delivered.
struct PDFCompression {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }
    private struct Geometry {
        let media: CGRect
        let crop: CGRect
        let bleed: CGRect
        let trim: CGRect
        let art: CGRect
        let rotation: Int
        init(_ page: PDFPage) {
            media = page.bounds(for: .mediaBox); crop = page.bounds(for: .cropBox)
            bleed = page.bounds(for: .bleedBox); trim = page.bounds(for: .trimBox); art = page.bounds(for: .artBox)
            rotation = ((page.rotation % 360) + 360) % 360
        }
    }
    static func targetBytes(original: Int, options: [String: String]) throws -> Int? {
        guard original > 0 else { throw Failure("The source PDF is empty.") }
        switch options["pdfCompressionMode"] ?? "preset" {
        case "preset": return nil
        case "percentage":
            guard let reduction = Double(options["pdfReduction"] ?? "50"), reduction.isFinite, reduction > 0, reduction < 100 else { throw Failure("Choose a reduction greater than 0% and less than 100%.") }
            let target = floor(Double(original) * (1 - reduction / 100))
            guard target >= 1, target < Double(Int.max) else { throw Failure("The requested reduction leaves no room for a PDF file.") }
            return Int(target)
        case "fileSize":
            guard let size = Double(options["pdfTargetSize"] ?? "1"), size.isFinite, size > 0 else { throw Failure("Enter a positive target file size.") }
            let unit = (options["pdfTargetUnit"] ?? "MB").uppercased()
            guard ["KB", "MB"].contains(unit) else { throw Failure("Choose KB or MB for the target size.") }
            let bytes = floor(size * (unit == "KB" ? 1000 : 1_000_000))
            guard bytes >= 1, bytes < Double(Int.max) else { throw Failure("The target file size is outside the supported range.") }
            return Int(bytes)
        default: throw Failure("Choose a valid PDF compression mode.")
        }
    }
    static func run(input: URL, outputDirectory: URL, options: [String: String]) throws -> URL {
        let original = try size(input)
        let target = try targetBytes(original: original, options: options)
        let document = try PDFTools.readable(input)
        let geometry = try (0..<document.pageCount).map { index -> Geometry in
            guard let page = document.page(at: index) else { throw Failure("Cannot read PDF page \(index + 1).") }
            let value = Geometry(page)
            guard value.media.width > 0, value.media.height > 0, value.media.width.isFinite, value.media.height.isFinite else { throw Failure("The PDF contains invalid page dimensions.") }
            return value
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if let target, target >= original {
            let output = unique(input.deletingPathExtension().lastPathComponent + "-compressed", in: outputDirectory)
            try FileManager.default.copyItem(at: input, to: output)
            return output
        }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("citrus-pdf-compression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let label = (options["pdfCompressionPreset"] ?? "balanced").lowercased()
        let preset: String
        if ["high", "high quality", "higher quality", "best", "best quality"].contains(label) { preset = "high" }
        else if ["small", "smallest", "small file", "smallest file", "smaller file", "smaller file size", "low"].contains(label) { preset = "small" }
        else if ["balanced", "medium", "recommended", "standard"].contains(label) { preset = "balanced" }
        else { throw Failure("Choose Balanced, Small File, or High Quality compression.") }
        var best: URL?, bestSize = Int.max, counter = 0
        func candidate() -> URL { counter += 1; return stage.appendingPathComponent("candidate-\(counter).pdf") }
        func accept(_ url: URL) throws -> Bool {
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            let length = try size(url)
            guard length > 0, length < bestSize, verify(url, geometry: geometry) else { try? FileManager.default.removeItem(at: url); return false }
            if let previous = best { try? FileManager.default.removeItem(at: previous) }
            best = url; bestSize = length
            return target.map { length <= $0 } ?? (length < original)
        }
        func finish() throws -> URL {
            guard let best else { throw Failure("The PDF could not be compressed into a readable document.") }
            if let target, bestSize > target { throw Failure("The requested size could not be reached while retaining all pages. Smallest result: \(ByteCountFormatter.string(fromByteCount: Int64(bestSize), countStyle: .file)); target: \(ByteCountFormatter.string(fromByteCount: Int64(target), countStyle: .file)). Try a larger target.") }
            guard target != nil || bestSize < original else { throw Failure("This PDF is already compact. Compression did not produce a smaller file.") }
            let output = unique(input.deletingPathExtension().lastPathComponent + "-compressed", in: outputDirectory)
            try FileManager.default.moveItem(at: best, to: output)
            return output
        }
        // Rebuild resource dictionaries and PDF streams before any lossy operation.
        if document.pageCount <= 500, (0..<document.pageCount).allSatisfy({ document.page(at: $0)?.annotations.isEmpty == true }), let source = CGPDFDocument(input as CFURL) {
            let url = candidate()
            try vectorRewrite(source, geometry: geometry, to: url)
            if try accept(url) { return try finish() }
        }
        let vectorSettings: [(Int, Double)] = preset == "high" ? [(220, 0.85), (180, 0.8)] : (preset == "small" ? [(110, 0.6), (90, 0.45)] : [(160, 0.75), (144, 0.65)])
        for (dpi, quality) in vectorSettings {
            let url = candidate()
            if let filter = filter(dpi: dpi, quality: quality), document.write(to: url, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) {
                if try accept(url) { return try finish() }
            }
        }
        // A target can require flattening text and annotations. Search is bounded
        // to six color raster passes; each page's bitmap is released before the next.
        var rasterSettings: [(Int, Double, Int)]
        if target != nil { rasterSettings = [(144, 0.72, 0), (144, 0.72, 1), (108, 0.6, 1), (108, 0.6, 3), (80, 0.45, 3), (60, 0.45, 3)] }
        else if preset == "high" { rasterSettings = [(180, 0.85, 0), (144, 0.8, 1), (96, 0.7, 1), (72, 0.65, 1)] }
        else if preset == "small" { rasterSettings = [(96, 0.55, 0), (80, 0.5, 1), (48, 0.5, 1)] }
        else { rasterSettings = [(144, 0.72, 0), (108, 0.65, 1), (64, 0.6, 1)] }
        if options["pdfAllowGrayscale"] == "true" { rasterSettings += [(126, 0.6, 2), (96, 0.45, 2)] }
        for (dpi, quality, encoding) in rasterSettings {
            let url = candidate()
            try rasterize(document, geometry: geometry, dpi: dpi, quality: quality, encoding: encoding, to: url)
            if try accept(url) { return try finish() }
        }
        return try finish()
    }
    private static func filter(dpi: Int, quality: Double) -> QuartzFilter? {
        QuartzFilter(properties: [
            "Domains": ["Applications": true, "Printing": true], "FilterType": 1, "Name": "Citrus PDF Compression",
            "FilterData": ["ColorSettings": ["ImageSettings": ["Compression Quality": quality, "ImageCompression": "ImageJPEGCompress", "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true, "ImageSizeMax": 6000, "ImageSizeMin": 0]]]]
        ])
    }
    private static func vectorRewrite(_ source: CGPDFDocument, geometry: [Geometry], to url: URL) throws {
        var first = geometry[0].media
        guard let context = CGContext(url as CFURL, mediaBox: &first, [kCGPDFContextCreator: "Citrus Local" as CFString] as CFDictionary) else { throw Failure("Cannot create compressed PDF.") }
        for (index, value) in geometry.enumerated() {
            guard let page = source.page(at: index + 1) else { context.closePDF(); throw Failure("Cannot read PDF page.") }
            var media = value.media, crop = value.crop
            let info: [CFString: Any] = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size), kCGPDFContextCropBox: Data(bytes: &crop, count: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary); context.drawPDFPage(page); context.endPDFPage()
        }
        context.closePDF()
        try restoreGeometry(url, geometry: geometry)
    }
    private static func rasterize(_ source: PDFDocument, geometry: [Geometry], dpi: Int, quality: Double, encoding: Int, to url: URL) throws {
        // Write compressed image streams directly. Redrawing a JPEG into a Quartz
        // PDF context can inflate it into a lossless bitmap on some macOS builds.
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw Failure("Cannot create compressed PDF.") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var position = 0, offsets = [Int](repeating: 0, count: 3 + geometry.count * 3)
        func write(_ data: Data) throws { try handle.write(contentsOf: data); position += data.count }
        func text(_ string: String) throws { try write(Data(string.utf8)) }
        func object(_ number: Int, _ body: String) throws { offsets[number] = position; try text("\(number) 0 obj\n\(body)\nendobj\n") }
        func rect(_ value: CGRect) -> String { "[\(value.minX) \(value.minY) \(value.maxX) \(value.maxY)]" }
        try text("%PDF-1.5\n%\u{00e2}\u{00e3}\u{00cf}\u{00d3}\n")
        try object(1,"<< /Type /Catalog /Pages 2 0 R >>")
        let kids = geometry.indices.map { "\(3 + $0 * 3) 0 R" }.joined(separator: " ")
        try object(2,"<< /Type /Pages /Count \(geometry.count) /Kids [\(kids)] >>")
        for (index, value) in geometry.enumerated() {
            try autoreleasepool {
                guard let page = source.page(at: index) else { throw Failure("Cannot read PDF page.") }
                let scale = CGFloat(dpi) / 72
                let width = max(1, Int(ceil(value.media.width * scale))), height = max(1, Int(ceil(value.media.height * scale)))
                guard width <= 30_000, height <= 30_000, width * height <= 60_000_000 else { throw Failure("A PDF page is too large to rasterize safely.") }
                guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure("Cannot allocate PDF page image.") }
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
                bitmap.scaleBy(x: scale, y: scale); bitmap.translateBy(x: -value.media.minX, y: -value.media.minY)
                let rotation = page.rotation; page.rotation = 0
                defer { page.rotation = rotation }
                page.draw(with: .mediaBox, to: bitmap)
                guard let image = bitmap.makeImage() else { throw Failure("Could not render a PDF page.") }
                let imageBytes: Data, imageDescription: String
                if encoding == 2 {
                    guard let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { throw Failure("Cannot read rendered PDF pixels.") }
                    let rowBytes = (width + 7) / 8
                    var packed = Data(repeating: 255, count: rowBytes * height)
                    // Ordered halftoning preserves shaded table headers instead
                    // of turning their dark text and background into one solid block.
                    let bayer = [0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5]
                    packed.withUnsafeMutableBytes { raw in
                        let output = raw.bindMemory(to: UInt8.self)
                        for y in 0..<height { for x in 0..<width {
                            let p = y * bitmap.bytesPerRow + x * 4
                            let luminance = (Int(pixels[p]) * 77 + Int(pixels[p + 1]) * 150 + Int(pixels[p + 2]) * 29) >> 8
                            if luminance < bayer[(y % 4) * 4 + x % 4] * 16 + 8 { output[y * rowBytes + x / 8] &= ~(128 >> (x % 8)) }
                        } }
                    }
                    imageBytes = try deflate(packed)
                    imageDescription = "/ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /FlateDecode"
                } else if encoding == 1 || encoding == 3 {
                    let limit = encoding == 3 ? 4 : 16
                    let image = try indexedImage(bitmap, width: width, height: height, limit: limit)
                    guard let bytes = image.dataProvider?.data, let table = image.colorSpace?.colorTable else { throw Failure("Cannot read palette-compressed PDF image.") }
                    imageBytes = try deflate(bytes as Data)
                    let colors = table.map { String(format: "%02x", $0) }.joined()
                    imageDescription = "/ColorSpace [/Indexed /DeviceRGB \(limit - 1) <\(colors)>] /BitsPerComponent \(limit == 4 ? 2 : 4) /Filter /FlateDecode"
                } else {
                    let jpeg = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else { throw Failure("JPEG encoding is unavailable.") }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot encode compressed PDF page.") }
                    imageBytes = jpeg as Data
                    imageDescription = "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode"
                }
                let pageID = 3 + index * 3, contentID = pageID + 1, imageID = pageID + 2
                try object(pageID,"<< /Type /Page /Parent 2 0 R /MediaBox \(rect(value.media)) /CropBox \(rect(value.crop)) /BleedBox \(rect(value.bleed)) /TrimBox \(rect(value.trim)) /ArtBox \(rect(value.art)) /Rotate \(value.rotation) /Resources << /XObject << /Im0 \(imageID) 0 R >> >> /Contents \(contentID) 0 R >>")
                let content = "q \(value.media.width) 0 0 \(value.media.height) \(value.media.minX) \(value.media.minY) cm /Im0 Do Q\n"
                try object(contentID,"<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
                offsets[imageID] = position
                try text("\(imageID) 0 obj\n<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) \(imageDescription) /Length \(imageBytes.count) >>\nstream\n")
                try write(imageBytes); try text("\nendstream\nendobj\n")
            }
        }
        let xref = position
        try text("xref\n0 \(offsets.count)\n0000000000 65535 f \n")
        for offset in offsets.dropFirst() { try text(String(format: "%010d 00000 n \n", offset)) }
        try text("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
        try handle.synchronize()
    }
    private static func deflate(_ data: Data) throws -> Data {
        var length = compressBound(uLong(data.count))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress!, &length, source.bindMemory(to: Bytef.self).baseAddress!, uLong(data.count), Z_BEST_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw Failure("Cannot compress PDF image stream.") }
        output.count = Int(length)
        return output
    }
    private static func indexedImage(_ bitmap: CGContext, width: Int, height: Int, limit: Int) throws -> CGImage {
        guard let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { throw Failure("Cannot read rendered PDF pixels.") }
        var counts = [Int](repeating: 0, count: 32768), reds = counts, greens = counts, blues = counts
        for y in 0..<height { for x in 0..<width {
            let p = y * bitmap.bytesPerRow + x * 4
            let r = Int(pixels[p]), g = Int(pixels[p + 1]), b = Int(pixels[p + 2])
            let bin = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
            counts[bin] += 1; reds[bin] += r; greens[bin] += g; blues[bin] += b
        } }
        struct Color { let bin: Int; let r: Int; let g: Int; let b: Int; let count: Int }
        let colors = counts.indices.compactMap { bin -> Color? in
            guard counts[bin] > 0, bin != 0, bin != 32767 else { return nil }
            return Color(bin: bin, r: reds[bin] / counts[bin], g: greens[bin] / counts[bin], b: blues[bin] / counts[bin], count: counts[bin])
        }
        func range(_ values: [Color]) -> (Int, Int) {
            guard !values.isEmpty else { return (0, 0) }
            let channels = [values.map(\.r), values.map(\.g), values.map(\.b)]
            let ranges = channels.map { ($0.max() ?? 0) - ($0.min() ?? 0) }
            let axis = ranges.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
            return (ranges[axis], axis)
        }
        var boxes = colors.isEmpty ? [] : [colors]
        while boxes.count < limit - 2 {
            guard let index = boxes.indices.filter({ boxes[$0].count > 1 }).max(by: { range(boxes[$0]).0 < range(boxes[$1]).0 }) else { break }
            let values = boxes.remove(at: index), axis = range(values).1
            let sorted = values.sorted { axis == 0 ? $0.r < $1.r : (axis == 1 ? $0.g < $1.g : $0.b < $1.b) }
            let half = sorted.reduce(0) { $0 + $1.count } / 2
            var weight = 0, split = 1
            for index in 0..<sorted.count - 1 { weight += sorted[index].count; split = index + 1; if weight >= half { break } }
            boxes.append(Array(sorted[..<split])); boxes.append(Array(sorted[split...]))
        }
        var palette: [(Int, Int, Int)] = [(255,255,255), (0,0,0)]
        for box in boxes {
            let weight = max(1, box.reduce(0) { $0 + $1.count })
            palette.append((box.reduce(0) { $0 + $1.r * $1.count } / weight, box.reduce(0) { $0 + $1.g * $1.count } / weight, box.reduce(0) { $0 + $1.b * $1.count } / weight))
        }
        var map = [UInt8](repeating: 0, count: 32768); map[0] = 1
        for color in colors {
            var best = Int.max, chosen: UInt8 = 0
            for (index, value) in palette.enumerated() {
                let distance = (color.r - value.0) * (color.r - value.0) + (color.g - value.1) * (color.g - value.1) + (color.b - value.2) * (color.b - value.2)
                if distance < best { best = distance; chosen = UInt8(index) }
            }
            map[color.bin] = chosen
        }
        let bits = limit == 4 ? 2 : 4, perByte = limit == 4 ? 4 : 2
        let rowBytes = (width * bits + 7) / 8
        var indices = Data(count: rowBytes * height)
        indices.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let p = y * bitmap.bytesPerRow + x * 4
                let bin = (Int(pixels[p] >> 3) << 10) | (Int(pixels[p + 1] >> 3) << 5) | Int(pixels[p + 2] >> 3)
                let value = map[bin], offset = y * rowBytes + x / perByte
                output[offset] |= value << (8 - bits - (x % perByte) * bits)
            } }
        }
        while palette.count < limit { palette.append((255,255,255)) }
        let table = palette.flatMap { [UInt8($0.0), UInt8($0.1), UInt8($0.2)] }
        guard let space = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: limit - 1, colorTable: table), let provider = CGDataProvider(data: indices as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits, bytesPerRow: rowBytes, space: space, bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw Failure("Cannot encode palette-compressed PDF page.") }
        return image
    }
    private static func restoreGeometry(_ url: URL, geometry: [Geometry]) throws {
        guard let document = PDFDocument(url: url), document.pageCount == geometry.count else { throw Failure("Compressed PDF could not be verified.") }
        var changed = false
        for (index, value) in geometry.enumerated() {
            guard let page = document.page(at: index) else { throw Failure("Compressed PDF lost a page.") }
            if page.rotation != value.rotation { page.rotation = value.rotation; changed = true }
            for (box, rect) in [(PDFDisplayBox.mediaBox, value.media), (.cropBox, value.crop), (.bleedBox, value.bleed), (.trimBox, value.trim), (.artBox, value.art)] {
                if !same(page.bounds(for: box), rect) { page.setBounds(rect, for: box); changed = true }
            }
        }
        if changed && !document.write(to: url) { throw Failure("Could not preserve PDF page geometry.") }
    }
    private static func verify(_ url: URL, geometry: [Geometry]) -> Bool {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount == geometry.count else { return false }
        return geometry.enumerated().allSatisfy { index, value in
            guard let page = document.page(at: index) else { return false }
            return ((page.rotation % 360) + 360) % 360 == value.rotation && same(page.bounds(for: .mediaBox), value.media) && same(page.bounds(for: .cropBox), value.crop) && same(page.bounds(for: .bleedBox), value.bleed) && same(page.bounds(for: .trimBox), value.trim) && same(page.bounds(for: .artBox), value.art)
        }
    }
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }
    private static func size(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0 }
    private static func unique(_ stem: String, in folder: URL) -> URL {
        var index = 1, url = folder.appendingPathComponent(stem + ".pdf")
        while FileManager.default.fileExists(atPath: url.path) { index += 1; url = folder.appendingPathComponent(stem + " \(index).pdf") }
        return url
    }
}
