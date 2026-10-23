import Foundation
import AppKit
import PDFKit
import Vision
import CoreText
import Quartz

/// Local document transformations. Every operation writes new files.
struct DocumentEngine {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    static func run(_ operation: String, inputs: [URL], outputDirectory: URL, options: [String: String]) throws -> [URL] {
        guard !inputs.isEmpty else { throw Failure("Choose at least one file.") }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        switch operation {
        case "compress":
            return try inputs.map { try PDFCompression.run(input:$0,outputDirectory:outputDirectory,options:options) }
        case "createPDF":
            let document = PDFDocument()
            for input in inputs {
                if input.pathExtension.lowercased() == "pdf" {
                    let source = try pdf(input)
                    for index in 0..<source.pageCount { if let page = source.page(at: index)?.copy() as? PDFPage { document.insert(page, at: document.pageCount) } }
                } else if input.pathExtension.lowercased() == "pptx" {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try OfficeConversion.presentationPDF(input, to: temporary)
                    let source = try pdf(temporary)
                    for index in 0..<source.pageCount { if let page = source.page(at: index)?.copy() as? PDFPage { document.insert(page, at: document.pageCount) } }
                } else if ["xls", "xlsx", "ods", "csv", "tsv"].contains(input.pathExtension.lowercased()) {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try spreadsheetPDF(readSpreadsheet(input), to: temporary)
                    let source = try pdf(temporary)
                    for index in 0..<source.pageCount { if let page = source.page(at: index)?.copy() as? PDFPage { document.insert(page, at: document.pageCount) } }
                } else if ["jpg", "jpeg", "png", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif", "svg", "gif"].contains(input.pathExtension.lowercased()) {
                    let normalized = FileManager.default.temporaryDirectory.appendingPathComponent("citrus-pdf-image-" + UUID().uuidString + ".png")
                    defer { try? FileManager.default.removeItem(at: normalized) }
                    try NativeImageConversion.normalizedPNG(input, to: normalized)
                    guard let image = NSImage(contentsOf: normalized), let page = PDFPage(image: image) else { throw Failure("Cannot render source image into PDF.") }
                    document.insert(page, at: document.pageCount)
                } else if let image = NSImage(contentsOf: input), let page = PDFPage(image: image) {
                    document.insert(page, at: document.pageCount)
                } else {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try textPDF(try readText(input), to: temporary)
                    let source = try pdf(temporary)
                    for index in 0..<source.pageCount { if let page = source.page(at: index)?.copy() as? PDFPage { document.insert(page, at: document.pageCount) } }
                }
            }
            let target = unique("Combined", "pdf", outputDirectory)
            try writePDF(document, target)
            return [target]
        case "mergePDF":
            let result = PDFDocument()
            for input in inputs {
                let source = try pdf(input)
                for index in 0..<source.pageCount { if let page = source.page(at: index)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) } }
            }
            let target = unique("Merged", "pdf", outputDirectory)
            try writePDF(result, target)
            return [target]
        case "splitPDF":
            return try inputs.map { input -> URL in
                let source = try pdf(input)
                let indices = try pageIndices(options["pages"], count: source.pageCount)
                let folder = unique(input.deletingPathExtension().lastPathComponent + " Pages", "", outputDirectory)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                do { for index in indices {
                    let result = PDFDocument()
                    guard let page = source.page(at: index)?.copy() as? PDFPage else { throw Failure("Cannot read page \(index + 1).") }
                    result.insert(page, at: 0)
                    let target = folder.appendingPathComponent("Page \(index + 1).pdf")
                    try writePDF(result, target)
                }} catch {try? FileManager.default.removeItem(at:folder);throw error}
                return folder
            }
        case "organizePDF":
            return try inputs.map { input in
                let source = try pdf(input)
                let result = PDFDocument()
                let indices = try pageIndices(options["order"] ?? options["pages"], count: source.pageCount)
                guard indices.count == source.pageCount, Set(indices).count == source.pageCount else { throw Failure("Page order must include every page exactly once.") }
                let rotations = (options["rotations"] ?? "").split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
                let allRotation = Int(options["rotation"] ?? "0") ?? 0
                let widths = indices.enumerated().compactMap { offset,index -> CGFloat? in
                    guard let page=source.page(at:index) else{return nil}
                    let rotation=offset < rotations.count ? rotations[offset]:allRotation
                    let box=page.bounds(for:.mediaBox)
                    return abs((page.rotation+rotation)%180)==90 ? box.height:box.width
                }
                let equalWidth = options["equalWidths"] == "true" ? widths.min() : nil
                for (offset, index) in indices.enumerated() {
                    guard let page = source.page(at: index)?.copy() as? PDFPage else { throw Failure("Cannot read PDF page.") }
                    let rotation = offset < rotations.count ? rotations[offset] : allRotation
                    guard rotation % 90 == 0 else { throw Failure("PDF rotations must be multiples of 90 degrees.") }
                    page.rotation = (page.rotation + rotation) % 360
                    if let width = equalWidth { result.insert(try scaledPage(page, width: width), at: result.pageCount) }
                    else { result.insert(page, at: result.pageCount) }
                }
                let target = unique(input.deletingPathExtension().lastPathComponent + "-organized", "pdf", outputDirectory)
                try writePDF(result, target)
                return target
            }
        case "createArchive":
            let chosenFormat = (options["format"] ?? "zip").lowercased()
            let format=chosenFormat=="gzip" ? "tar.gz":chosenFormat
            guard ["zip", "tar", "tgz", "tar.gz"].contains(format) else { throw Failure("Archive creation supports ZIP, TAR, and TAR.GZ.") }
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            for input in inputs {
                let name = unique(input.deletingPathExtension().lastPathComponent, input.pathExtension, stage)
                try FileManager.default.copyItem(at: input, to: name)
            }
            let target = unique("Archive", format, outputDirectory)
            if format == "zip" { _ = try process("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--zlibCompressionLevel", options["archiveCompression"]=="faster" ? "1":options["archiveCompression"]=="smallest" ? "9":"6", stage.path, target.path]) }
            else {
                var args=[format == "tar" ? "-cf":"-czf",target.path,"-C",stage.path]
                if format != "tar" {args += ["--options","gzip:compression-level=\(options["archiveCompression"]=="faster" ? "1":options["archiveCompression"]=="smallest" ? "9":"6")"]}
                _ = try process("/usr/bin/tar",args+["."])
            }
            return [target]
        case "convertArchive":
            let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("citrus-archive-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:temporary)}
            return try inputs.flatMap{input->[URL] in
                let folders=try run("extractArchive",inputs:[input],outputDirectory:temporary,options:options)
                let contents=try folders.flatMap{try FileManager.default.contentsOfDirectory(at:$0,includingPropertiesForKeys:nil)}
                return try run("createArchive",inputs:contents,outputDirectory:outputDirectory,options:options)
            }
        case "extractArchive":
            return try inputs.map { input in
                let isZip = input.pathExtension.lowercased() == "zip"
                let isTar = ["tar", "tgz", "tbz", "tbz2", "txz", "rar"].contains(input.pathExtension.lowercased()) || [".tar.gz", ".tar.bz2", ".tar.xz"].contains(where: { input.lastPathComponent.lowercased().hasSuffix($0) })
                guard isZip || isTar else { throw Failure("Archive extraction supports ZIP, RAR, TAR, TAR.GZ, TAR.BZ2, and TAR.XZ.") }
                let listing = try process(isZip ? "/usr/bin/unzip" : "/usr/bin/tar", isZip ? ["-Z1", input.path] : ["-tf", input.path])
                for item in listing.split(separator: "\n") {
                    let name = String(item)
                    guard !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.split(separator: "/").contains(".."), !name.contains("\\") else { throw Failure("Archive contains an unsafe path.") }
                }
                let attributes = try process(isZip ? "/usr/bin/unzip" : "/usr/bin/tar", isZip ? ["-Z", "-l", input.path] : ["-tvf", input.path])
                if isZip {
                    guard !attributes.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw Failure("Archives containing symbolic links cannot be extracted safely.") }
                } else {
                    guard attributes.split(separator: "\n").allSatisfy({ $0.hasPrefix("-") || $0.hasPrefix("d") }) else { throw Failure("Only regular files and directories may be extracted from TAR archives.") }
                }
                let target = unique(input.deletingPathExtension().lastPathComponent + "-extracted", "", outputDirectory)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                do { _ = try process(isZip ? "/usr/bin/unzip" : "/usr/bin/tar", isZip ? ["-q", input.path, "-d", target.path] : ["-xf", input.path, "-C", target.path, "--no-same-owner", "--no-same-permissions"]) }
                catch { try? FileManager.default.removeItem(at: target); throw error }
                return target
            }
        case "extractText":
            return try inputs.map { input in
                let text = try extractedText(input, ocr: options["ocr"] != "false")
                let target = unique(input.deletingPathExtension().lastPathComponent, "txt", outputDirectory)
                try text.write(to: target, atomically: true, encoding: .utf8)
                return target
            }
        case "removeMetadata":
            return try inputs.map { input in
                let target = unique(input.deletingPathExtension().lastPathComponent + "-clean", input.pathExtension, outputDirectory)
                if input.pathExtension.lowercased() == "pdf" {
                    return try PDFTools.saveMetadata(input,fields:[],outputDirectory:outputDirectory)
                } else if let image = NSImage(contentsOf: input), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                    let ext = input.pathExtension.lowercased()
                    let type: NSBitmapImageRep.FileType
                    switch ext { case "png": type = .png; case "jpg", "jpeg": type = .jpeg; case "tif", "tiff": type = .tiff; case "bmp": type = .bmp; default: throw Failure("Metadata removal supports PDF, PNG, JPEG, TIFF, and BMP.") }
                    guard let data = bitmap.representation(using: type, properties: [:]) else { throw Failure("Image encoding failed.") }
                    try data.write(to: target, options: .atomic)
                } else { throw Failure("Metadata removal is unavailable for this format.") }
                return target
            }
        case "convert":
            guard let format = options["format"]?.lowercased(), !format.isEmpty else { throw Failure("Choose an output format.") }
            let imageTypes:Set<String>=["jpg","jpeg","png","webp","bmp","tif","tiff","heic","heif","avif","svg","gif"]
            if format == "pdf", inputs.count > 1, inputs.allSatisfy({imageTypes.contains($0.pathExtension.lowercased())}) {
                return try run("createPDF", inputs: inputs, outputDirectory: outputDirectory, options: options)
            }
            return try inputs.flatMap { try convert($0, format: format, outputDirectory: outputDirectory, options: options) }
        default: throw Failure("Unknown document operation: \(operation)")
        }
    }

    private static func convert(_ input: URL, format: String, outputDirectory: URL, options: [String:String]) throws -> [URL] {
        let ext = input.pathExtension.lowercased()
        let stem = input.deletingPathExtension().lastPathComponent
        try DocumentImport.validateDocument(input)
        if ext == "pdf", format == "pptx" {
            let target = unique(stem, format, outputDirectory)
            try OfficeConversion.pdfPresentation(input, to: target)
            return [target]
        }
        if ext == "pdf", ["xlsx", "ods", "csv", "tsv"].contains(format) {
            let rows = try OfficeConversion.pdfRows(input)
            let target = unique(stem, format, outputDirectory)
            try writeSpreadsheet(rows, format: format, to: target)
            return [target]
        }
        if ext == "pptx", format == "pdf" {
            let target = unique(stem, format, outputDirectory)
            try OfficeConversion.presentationPDF(input, to: target)
            return [target]
        }
        let readableDocuments: Set<String> = ["txt", "md", "doc", "docx", "rtf", "rtfd", "html", "odt", "epub", "textclipping", "pages", "pptx", "csv", "tsv", "xlsx", "xls", "ods"]
        if readableDocuments.contains(ext), ["png", "jpg", "jpeg", "tiff", "tif"].contains(format) {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("citrus-render-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let intermediate = try convert(input, format: "pdf", outputDirectory: temporary, options: options)
            guard let document = intermediate.first else { throw Failure("Document did not render to PDF.") }
            let rendered = try convert(document, format: format, outputDirectory: temporary, options: options)
            return try rendered.enumerated().map { index, image in
                let target = unique(stem + (rendered.count > 1 ? "-page-\(index + 1)" : ""), format, outputDirectory)
                try FileManager.default.moveItem(at: image, to: target)
                return target
            }
        }
        if format=="docx",ext=="pdf",options["pdfLayout"]=="pages" {
            let target=unique(stem,format,outputDirectory);try DocumentLayoutWriter.docxPreservingPages(input,to:target);return[target]
        }
        if format=="epub" {
            let target=unique(stem,format,outputDirectory)
            let keep=options["epubLayout"]=="pages" && ext=="pdf"
            let text=keep ? "":try extractedText(input,ocr:options["ocr"] != "false")
            try DocumentLayoutWriter.epub(input,text:text,keepPages:keep,to:target);return[target]
        }
        if ["srt", "vtt", "ass", "ssa"].contains(ext), ["srt", "vtt", "ass"].contains(format) {
            let target = unique(stem, format, outputDirectory)
            let cues = try subtitleCues(String(contentsOf: input, encoding: .utf8), format: ext)
            guard !cues.isEmpty else { throw Failure("No valid subtitle cues were found.") }
            let contents: String
            if format == "ass" {
                contents = "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" + cues.map { "Dialogue: 0,\(stamp($0.start, ass: true)),\(stamp($0.end, ass: true)),Default,,0,0,0,,\($0.text.replacingOccurrences(of: "\n", with: "\\N"))" }.joined(separator: "\n")
            } else {
                contents = (format == "vtt" ? "WEBVTT\n\n" : "") + cues.enumerated().map { i, cue in
                    "\(i + 1)\n\(stamp(cue.start, comma: format == "srt")) --> \(stamp(cue.end, comma: format == "srt"))\n\(cue.text)\n"
                }.joined(separator: "\n")
            }
            try contents.write(to: target, atomically: true, encoding: .utf8)
            return [target]
        }
        if ["csv", "tsv", "json", "xlsx", "xls", "ods"].contains(ext), ["csv", "tsv", "json", "xlsx", "ods", "pdf"].contains(format) {
            let target = unique(stem, format, outputDirectory)
            let rows = try readSpreadsheet(input)
            if format == "ods" { try DocumentImport.writeODS(rows, to: target); return [target] }
            if format == "pdf" { try spreadsheetPDF(rows, to: target); return [target] }
            if format == "xlsx" { try writeXLSX(rows, to: target) }
            else if format == "json" {
                let object: Any
                if let header = rows.first, Set(header).count == header.count {
                    object = rows.dropFirst().map { row in Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset < row.count ? row[$0.offset] : "") }) }
                } else { object = rows }
                try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: target)
            } else {
                let separator = format == "csv" ? "," : "\t"
                let text = rows.map { $0.map { field -> String in
                    if field.contains(separator) || field.contains("\"") || field.contains("\n") || field.contains("\r") { return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                    return field
                }.joined(separator: separator) }.joined(separator: "\n")
                try text.write(to: target, atomically: true, encoding: .utf8)
            }
            return [target]
        }
        if format == "pdf" { return try run("createPDF", inputs: [input], outputDirectory: outputDirectory, options: options) }
        if ext == "pdf", ["png", "jpg", "jpeg", "tiff", "tif"].contains(format) {
            let source = try pdf(input)
            let scale = min(8, max(0.5, (Double(options["dpi"] ?? "144") ?? 144) / 72))
            return try pageIndices(options["pages"], count: source.pageCount).map { index in
                guard let page = source.page(at: index) else { throw Failure("Cannot read PDF page.") }
                let bounds = page.bounds(for: .mediaBox)
                let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let encoded = bitmap.representation(using: format == "png" ? .png : (["tif", "tiff"].contains(format) ? .tiff : .jpeg), properties: [.compressionFactor: 0.92]) else { throw Failure("Could not render PDF page.") }
                let target = unique(stem + "-page-\(index + 1)", format, outputDirectory)
                try encoded.write(to: target)
                return target
            }
        }
        if format == "txt", ext == "pdf" { return try run("extractText", inputs: [input], outputDirectory: outputDirectory, options: options) }
        if ["md", "epub", "textclipping", "pages", "rtfd", "pptx", "srt", "vtt", "ass", "ssa"].contains(ext) || ["md", "pages"].contains(format) || (ext == "pdf" && ["docx", "rtf", "html"].contains(format)) {
            guard ["txt", "md", "rtf", "rtfd", "html", "doc", "docx", "odt", "pdf", "pages"].contains(format) else { throw Failure("Unsupported text conversion.") }
            let text = try extractedText(input, ocr: options["ocr"] != "false")
            let target = unique(stem, format, outputDirectory)
            if format == "pages" { try PagesIO.write(text: text, to: target) }
            else if format == "md" || format == "txt" { try text.write(to: target, atomically: true, encoding: .utf8) }
            else {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try text.write(to: temporary, atomically: true, encoding: .utf8)
                _ = try process("/usr/bin/textutil", ["-convert", format, "-output", target.path, temporary.path])
            }
            return [target]
        }
        let textFormats = ["txt", "rtf", "rtfd", "html", "doc", "docx", "odt", "webarchive"]
        guard textFormats.contains(ext), textFormats.contains(format), format != "webarchive" else { throw Failure("Unsupported document conversion: \(ext) to \(format).") }
        let target = unique(stem, format, outputDirectory)
        let source = ext == "rtfd" ? input.appendingPathComponent("TXT.rtf") : input
        _ = try process("/usr/bin/textutil", ["-convert", format, "-output", target.path, source.path])
        guard FileManager.default.fileExists(atPath: target.path) else { throw Failure("Document converter produced no output.") }
        return [target]
    }

    private static func pdf(_ url: URL) throws -> PDFDocument {
        try PDFTools.readable(url)
    }
    private static func writePDF(_ source: PDFDocument, _ target: URL) throws {
        guard source.pageCount > 0, source.write(to: target) else { throw Failure("Could not write PDF.") }
    }
    private static func scaledPage(_ page: PDFPage, width: CGFloat) throws -> PDFPage {
        let sourceBounds = page.bounds(for: .mediaBox)
        guard sourceBounds.width > 0, width > 0 else { throw Failure("Invalid PDF page dimensions.") }
        let rotated=abs(page.rotation%180)==90
        let visibleSize=CGSize(width:rotated ? sourceBounds.height:sourceBounds.width,height:rotated ? sourceBounds.width:sourceBounds.height)
        let factor = width / visibleSize.width
        var bounds = CGRect(x: 0, y: 0, width: width, height: visibleSize.height * factor)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw Failure("Could not resize PDF page.") }
        context.beginPDFPage(nil)
        guard let ref=page.pageRef else{throw Failure("Cannot render PDF page.")}
        // The copied PDFPage rotation can differ from its underlying CGPDFPage.
        let extra=(page.rotation-Int(ref.rotationAngle))%360
        context.concatenate(ref.getDrawingTransform(.mediaBox,rect:bounds,rotate:Int32(extra),preserveAspectRatio:true))
        context.drawPDFPage(ref)
        context.endPDFPage()
        context.closePDF()
        guard let result = PDFDocument(data: data as Data)?.page(at: 0)?.copy() as? PDFPage else { throw Failure("Could not verify resized PDF page.") }
        return result
    }
    private static func unique(_ name: String, _ ext: String, _ directory: URL) -> URL {
        var index = 1
        var candidate = directory.appendingPathComponent(name + (ext.isEmpty ? "" : "." + ext))
        while FileManager.default.fileExists(atPath: candidate.path) { index += 1; candidate = directory.appendingPathComponent(name + " \(index)" + (ext.isEmpty ? "" : "." + ext)) }
        return candidate
    }
    private static func process(_ executable: String, _ arguments: [String]) throws -> String {
        let data = try DocumentImport.commandData(executable, arguments)
        guard let text = String(data: data, encoding: .utf8) else { throw Failure("Document reader returned invalid text data.") }
        if executable == "/usr/bin/textutil" && (text.lowercased().hasPrefix("error reading") || text.lowercased().hasPrefix("error converting")) { throw Failure(text) }
        return text
    }
    private static func pageIndices(_ specification: String?, count: Int) throws -> [Int] {
        guard let specification, !specification.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(0..<count) }
        var result: [Int] = []
        for token in specification.split(separator: ",") {
            let range = token.trimmingCharacters(in: .whitespaces).split(separator: "-")
            guard let first = range.first.flatMap({ Int($0) }), first > 0, first <= count else { throw Failure("Invalid page selection: \(token)") }
            if range.count == 1 { result.append(first - 1) }
            else if range.count == 2, let end = Int(range[1]), end >= first, end <= count { result.append(contentsOf: (first...end).map { $0 - 1 }) }
            else { throw Failure("Invalid page range: \(token)") }
        }
        guard !result.isEmpty else { throw Failure("Choose at least one page.") }
        return result
    }
    static func readText(_ input: URL) throws -> String {
        let ext = input.pathExtension.lowercased()
        if ext == "pages" { return try PagesIO.readText(input) }
        if ext == "pptx" { return try OfficeConversion.presentationText(input) }
        if ["xlsx", "xls", "ods"].contains(ext) { return try readSpreadsheet(input).map { $0.joined(separator: "\t") }.joined(separator: "\n") }
        if ["srt", "vtt", "ass", "ssa"].contains(ext) {
            let cues = try subtitleCues(DocumentImport.decode(Data(contentsOf: input)), format: ext)
            guard !cues.isEmpty else { throw Failure("No subtitle cues found.") }
            return cues.map { $0.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }.joined(separator: "\n")
        }
        return try DocumentImport.readText(input)
    }
    private static func textPDF(_ text: String, to url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else { throw Failure("Cannot create PDF context.") }
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var offset = 0
        while offset < attributed.length {
            context.beginPDFPage(nil)
            let path = CGPath(rect: bounds.insetBy(dx: 42, dy: 42), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { context.closePDF(); throw Failure("Text could not be laid out.") }
            offset += visible.length
        }
        context.closePDF()
    }
    private static func extractedText(_ input: URL, ocr: Bool) throws -> String {
        if input.pathExtension.lowercased() == "pdf" {
            let source = try pdf(input)
            return try (0..<source.pageCount).map { index in
                guard let page = source.page(at: index) else { return "" }
                let text = page.string ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ocr { return text }
                let bounds = page.bounds(for: .mediaBox)
                return try recognize(page.thumbnail(of: NSSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox))
            }.joined(separator: "\n\n")
        }
        if let image = NSImage(contentsOf: input) { return try recognize(image) }
        return try readText(input)
    }
    private static func recognize(_ image: NSImage) throws -> String {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw Failure("Cannot decode image for text recognition.") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private struct Cue { let start: Double; let end: Double; let text: String }
    private static func seconds(_ value: String) -> Double? {
        let fields = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        if fields.count == 3 { return fields[0] * 3600 + fields[1] * 60 + fields[2] }
        if fields.count == 2 { return fields[0] * 60 + fields[1] }
        return nil
    }
    private static func stamp(_ value: Double, comma: Bool = false, ass: Bool = false) -> String {
        let unit = ass ? 100 : 1000
        let ticks = Int((max(0, value) * Double(unit)).rounded())
        let whole = ticks / unit
        if ass { return String(format: "%d:%02d:%02d.%02d", whole / 3600, whole / 60 % 60, whole % 60, ticks % unit) }
        return String(format: "%02d:%02d:%02d%@%03d", whole / 3600, whole / 60 % 60, whole % 60, comma ? "," : ".", ticks % unit)
    }
    private static func subtitleCues(_ text: String, format: String) throws -> [Cue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var cues: [Cue] = []
        if format == "ass" || format == "ssa" {
            for line in lines where line.lowercased().hasPrefix("dialogue:") {
                let fields = String(line.dropFirst(9)).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
                if fields.count == 10, let start = seconds(String(fields[1])), let end = seconds(String(fields[2])) {
                    let body = String(fields[9]).replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ").replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                    cues.append(Cue(start: start, end: end, text: body))
                }
            }
        } else {
            var index = 0
            while index < lines.count {
                let parts = lines[index].components(separatedBy: "-->")
                if parts.count == 2, let start = seconds(parts[0]), let end = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) {
                    index += 1
                    var body: [String] = []
                    while index < lines.count && !lines[index].isEmpty { body.append(lines[index]); index += 1 }
                    cues.append(Cue(start: start, end: end, text: body.joined(separator: "\n")))
                }
                index += 1
            }
        }
        return cues
    }
    private static func parseDelimited(_ text: String, separator: Character) throws -> [[String]] {
        let characters = Array(text)
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, index = 0
        while index < characters.count {
            let c = characters[index]
            if c == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" { field.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if c == separator && !quoted { row.append(field); field = "" }
            else if (c == "\n" || c == "\r") && !quoted {
                if c == "\r" && index + 1 < characters.count && characters[index + 1] == "\n" { index += 1 }
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(c) }
            index += 1
        }
        guard !quoted else { throw Failure("Unterminated quoted field in table.") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
    private static func readXLSX(_ input: URL) throws -> [[String]] {
        let listing = try process("/usr/bin/unzip", ["-Z1", input.path]).components(separatedBy: "\n")
        guard let sheet = listing.filter({ $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") && !URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".") }).sorted().first else { throw Failure("Workbook has no readable worksheet.") }
        var shared: [String] = []
        if listing.contains("xl/sharedStrings.xml") {
            let xml = try XMLDocument(xmlString: process("/usr/bin/unzip", ["-p", input.path, "xl/sharedStrings.xml"]), options: [.nodeLoadExternalEntitiesNever])
            shared = try xml.nodes(forXPath: "//*[local-name()='si']").map { node in try node.nodes(forXPath: ".//*[local-name()='t']").compactMap { $0.stringValue }.joined() }
        }
        let xml = try XMLDocument(xmlString: process("/usr/bin/unzip", ["-p", input.path, sheet]), options: [.nodeLoadExternalEntitiesNever])
        var result: [[String]] = []
        for rowNode in try xml.nodes(forXPath: "//*[local-name()='sheetData']/*[local-name()='row']") {
            guard result.count < 100_000 else { throw Failure("Worksheet exceeds 100,000 rows.") }
            if let element = rowNode as? XMLElement, let rowIndex = element.attribute(forName: "r")?.stringValue.flatMap(Int.init), rowIndex > 0 {
                guard rowIndex <= 100_000 else { throw Failure("Worksheet exceeds 100,000 rows.") }
                while result.count < rowIndex - 1 { result.append([]) }
            }
            var row: [String] = []
            for cell in try rowNode.nodes(forXPath: "./*[local-name()='c']") {
                guard let element = cell as? XMLElement else { continue }
                let reference = element.attribute(forName: "r")?.stringValue ?? ""
                let letters = reference.uppercased().prefix { $0.isLetter }
                guard !letters.isEmpty, letters.utf8.count <= 3, letters.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else { throw Failure("Invalid worksheet cell reference.") }
                let column = letters.utf8.reduce(0) { $0 * 26 + Int($1) - 64 } - 1
                guard column >= 0, column < 16_384 else { throw Failure("Invalid worksheet cell reference.") }
                while row.count <= column { row.append("") }
                let type = element.attribute(forName: "t")?.stringValue ?? ""
                let value = try cell.nodes(forXPath: "./*[local-name()='v']").first?.stringValue ?? ""
                if type == "s", let index = Int(value), shared.indices.contains(index) { row[column] = shared[index] }
                else if type == "inlineStr" { row[column] = try cell.nodes(forXPath: ".//*[local-name()='t']").compactMap { $0.stringValue }.joined() }
                else { row[column] = value }
            }
            result.append(row)
        }
        return result
    }
    static func writeXLSX(_ rows: [[String]], to target: URL) throws {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        for path in ["_rels", "xl/_rels", "xl/worksheets"] { try FileManager.default.createDirectory(at: stage.appendingPathComponent(path), withIntermediateDirectories: true) }
        func write(_ name: String, _ text: String) throws { try text.write(to: stage.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try write("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>")
        try write("_rels/.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        try write("xl/workbook.xml", "<?xml version=\"1.0\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        try write("xl/_rels/workbook.xml.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>")
        var body = "<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (rowIndex, row) in rows.enumerated() {
            body += "<row r=\"\(rowIndex + 1)\">"
            for (columnIndex, value) in row.enumerated() {
                guard columnIndex < 16_384, rowIndex < 1_048_576 else { throw Failure("Table exceeds XLSX size limits.") }
                var column = "", remainder = columnIndex + 1
                while remainder > 0 { let digit = (remainder - 1) % 26; column = String(UnicodeScalar(65 + digit)!) + column; remainder = (remainder - 1) / 26 }
                let escaped = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                body += "<c r=\"\(column)\(rowIndex + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escaped)</t></is></c>"
            }
            body += "</row>"
        }
        body += "</sheetData></worksheet>"
        try write("xl/worksheets/sheet1.xml", body)
        _ = try process("/usr/bin/ditto", ["-c", "-k", "--norsrc", stage.path, target.path])
    }
}

extension DocumentEngine {
    static func readSpreadsheet(_ input: URL) throws -> [[String]] {
        switch input.pathExtension.lowercased() {
        case "xlsx": return try readXLSX(input)
        case "xls": return try DocumentImport.readXLS(input)
        case "ods": return try DocumentImport.readODS(input)
        case "csv", "tsv": return try parseDelimited(DocumentImport.decode(Data(contentsOf: input)), separator: input.pathExtension.lowercased() == "csv" ? "," : "\t")
        case "json":
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: input))
            if let values = object as? [[String: Any]] {
                let keys = Array(Set(values.flatMap { $0.keys })).sorted()
                return [keys] + values.map { row in keys.map { key in row[key].map { String(describing: $0) } ?? "" } }
            }
            if let values = object as? [[Any]] { return values.map { $0.map { String(describing: $0) } } }
            throw Failure("JSON spreadsheet must contain an array of objects or rows.")
        default: throw Failure("Unsupported spreadsheet input format.")
        }
    }
    static func writeSpreadsheet(_ rows: [[String]], format: String, to target: URL) throws {
        if format == "xlsx" { try writeXLSX(rows, to: target); return }
        if format == "ods" { try DocumentImport.writeODS(rows, to: target); return }
        let separator = format == "tsv" ? "\t" : ","
        let text = rows.map { row in row.map { field -> String in
            field.contains(separator) || field.contains("\"") || field.contains("\n") || field.contains("\r") ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
        }.joined(separator: separator) }.joined(separator: "\n")
        try text.write(to: target, atomically: true, encoding: .utf8)
    }
    private static func spreadsheetPDF(_ rows: [[String]], to target: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 792, height: 612)
        guard let context = CGContext(target as CFURL, mediaBox: &bounds, nil) else { throw Failure("Cannot create spreadsheet PDF.") }
        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        let columns = max(1, rows.map(\.count).max() ?? 1)
        let lineHeight: CGFloat = 14, left: CGFloat = 32, top: CGFloat = 574, bottom: CGFloat = 32
        func draw(_ string: String, at point: CGPoint) {
            context.textMatrix = .identity
            context.textPosition = point
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.black])), context)
        }
        for firstColumn in stride(from: 0, to: columns, by: 10) {
            let count = min(10, columns - firstColumn), width = (bounds.width - left * 2) / CGFloat(count)
            let characters = max(3, Int((width - 10) / 5.8))
            var y: CGFloat = top
            func begin() { context.beginPDFPage(nil); draw("Sheet 1 · Columns \(firstColumn + 1)–\(firstColumn + count)", at: CGPoint(x: left, y: top + 14)); y = top }
            func wrapped(_ value: String) -> [String] {
                value.components(separatedBy: "\n").flatMap { paragraph -> [String] in
                    var lines: [String] = [], chunk = ""
                    for character in paragraph.replacingOccurrences(of: "\t", with: " ") {
                        chunk.append(character)
                        if chunk.count >= characters { lines.append(chunk); chunk = "" }
                    }
                    if !chunk.isEmpty || lines.isEmpty { lines.append(chunk) }
                    return lines
                }
            }
            begin()
            for row in rows {
                let cells = (firstColumn..<firstColumn + count).map { wrapped($0 < row.count ? row[$0] : "") }
                let height = cells.map(\.count).max() ?? 1
                var offset = 0
                while offset < height {
                    let available = Int((y - bottom - 8) / lineHeight)
                    if available < 1 { context.endPDFPage(); begin(); continue }
                    let lines = min(available, height - offset), blockHeight = CGFloat(lines) * lineHeight + 8
                    for (index, cell) in cells.enumerated() {
                        let x = left + CGFloat(index) * width
                        context.setStrokeColor(CGColor(gray: 0.75, alpha: 1)); context.setLineWidth(0.4)
                        context.stroke(CGRect(x: x, y: y - blockHeight, width: width, height: blockHeight))
                        for line in 0..<lines where offset + line < cell.count { draw(cell[offset + line], at: CGPoint(x: x + 5, y: y - 13 - CGFloat(line) * lineHeight)) }
                    }
                    y -= blockHeight; offset += lines
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
