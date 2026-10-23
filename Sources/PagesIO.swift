import Foundation
import AppKit

/// Plain-text Pages interchange. IWA decoding follows the Snappy framing and
/// typed protobuf archives; it never searches arbitrary binary data for strings.
/// Native export uses the installed Pages application; no Apple template is bundled.
enum PagesIO {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }
    private static let limit = 128 * 1024 * 1024
    private static let sf = "http://developer.apple.com/namespaces/sf"

    static func readText(_ url: URL) throws -> String {
        let package = try Package(url)
        defer { package.cleanUp() }
        for name in ["index.xml", "index.xml.gz"] where package.names.contains(name) {
            var xml = try package.read(name)
            if name.hasSuffix(".gz") {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("citrus-pages-" + UUID().uuidString + ".gz")
                try xml.write(to: temporary); defer { try? FileManager.default.removeItem(at: temporary) }
                xml = try command("/usr/bin/gzip", ["-dc", temporary.path], maximum: limit)
            }
            let parser = LegacyTextParser()
            return try parser.read(xml)
        }
        var objects: [Object] = []
        var decodedBytes = 0
        let names = package.names.filter { $0.hasPrefix("Index/") && $0.hasSuffix(".iwa") }.sorted { a, b in
            if a == b { return false }
            if a == "Index/Document.iwa" { return true }; if b == "Index/Document.iwa" { return false }; return a < b
        }
        guard !names.isEmpty else { throw Failure("This Pages package has no supported XML or IWA document. Password-protected Pages documents cannot be imported.") }
        for name in names {
            let raw = try snappyStream(try package.read(name))
            decodedBytes += raw.count
            guard decodedBytes <= limit else { throw Failure("The decoded Pages document exceeds the 128 MB import limit.") }
            let decoded = try archives(raw)
            let base = objects.count
            objects += decoded.enumerated().map { index, item in var item = item; item.order = base + index; return item }
        }
        guard let document = objects.first(where: { $0.type == 10000 }) else { throw Failure("The package contains no Pages document archive.") }
        let documentFields = try fields(document.payload)
        let reference = documentFields.first(where: { $0.number == 4 && $0.bytes != nil }).flatMap { $0.bytes }
        let bodyID = try reference.flatMap { try fields($0).first(where: { $0.number == 1 })?.integer }
        var texts: [String] = []
        let storages = objects.filter { $0.type == 2001 }.sorted { a,b in
            if a.id == bodyID && b.id != bodyID { return true }; if b.id == bodyID && a.id != bodyID { return false }; return a.order < b.order
        }
        for object in storages {
            let f = try fields(object.payload)
            let kind = f.first(where: { $0.number == 1 })?.integer ?? 0
            // Body, text boxes, footnotes and table cells contain user content.
            // Header/footer template storages and TOC caches are intentionally excluded.
            guard object.id == bodyID || [UInt64(0),2,3,5].contains(kind) else { continue }
            let parts = try f.filter { $0.number == 3 && $0.bytes != nil }.map { field -> String in
                guard let bytes = field.bytes, let text = String(data: bytes, encoding: .utf8) else { throw Failure("A Pages text storage contains invalid UTF-8.") }
                return text
            }
            let text = parts.joined().replacingOccurrences(of: "\u{000E}", with: "\n").replacingOccurrences(of: "\u{000C}", with: "\n")
            if !text.isEmpty { texts.append(text) }
        }
        guard !texts.isEmpty else { return "" }
        return texts.joined(separator: "\n")
    }

    private static let exportLock = NSLock()

    static var installedPagesApplication: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Pages.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Pages.app"),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages")
        ].compactMap { $0 }
        return candidates.first { Bundle(url: $0)?.bundleIdentifier == "com.apple.iWork.Pages" }
    }

    static func write(text: String, to output: URL) throws {
        try write(text: text, to: output, pagesApplication: installedPagesApplication)
    }

    /// Use Pages' public scripting interface to save a newly created document.
    /// Text and file paths are passed as data, never interpolated into script commands.
    static func write(text: String, to output: URL, pagesApplication: URL?) throws {
        guard text.utf8.count <= 32 * 1024 * 1024 else { throw Failure("The text exceeds the 32 MB Pages export limit.") }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw Failure("A file already exists at the Pages destination.") }
        guard let application = pagesApplication else {
            throw Failure("Pages export requires Apple Pages installed on this Mac. Install Pages, then try again, or choose DOCX or PDF.")
        }
        exportLock.lock(); defer { exportLock.unlock() }
        let root = fm.temporaryDirectory.appendingPathComponent("citrus-pages-export-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let input = root.appendingPathComponent("Input.txt"), staged = root.appendingPathComponent("Export.pages")
        try normalized.write(to: input, atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("Export.applescript")
        let applicationLiteral = "\"" + application.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let source = """
        use framework "Foundation"
        on run arguments
            set sourceText to current application's NSString's stringWithContentsOfFile:(item 1 of arguments) encoding:4 |error|:(missing value)
            if sourceText is missing value then error "Could not read the export text."
            set sourceText to sourceText as text
            set destinationFile to POSIX file (item 2 of arguments)
            with timeout of 120 seconds
                tell application \(applicationLiteral)
                    set exportDocument to make new document
                    try
                        set body text of exportDocument to sourceText
                        save exportDocument in destinationFile
                        close exportDocument saving no
                    on error errorMessage number errorNumber
                        try
                            close exportDocument saving no
                        end try
                        error errorMessage number errorNumber
                    end try
                end tell
            end timeout
        end run
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try runPagesScript(script, input: input, output: staged, directory: root)
        guard fm.fileExists(atPath: staged.path) else { throw Failure("Pages did not create the exported document.") }
        guard try readText(staged) == normalized else { throw Failure("The exported Pages document did not preserve its text.") }
        // copyItem refuses an existing destination, including one created while Pages was working.
        try fm.copyItem(at: staged, to: output)
    }

    private static func runPagesScript(_ script: URL, input: URL, output: URL, directory: URL) throws {
        let diagnostics = directory.appendingPathComponent("Diagnostics.txt")
        FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
        let handle = try FileHandle(forWritingTo: diagnostics)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [script.path, input.path, output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(130)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate(); process.waitUntilExit()
            throw Failure("Pages export timed out. Check for a Pages or macOS Automation prompt, then try again.")
        }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: (try? Data(contentsOf: diagnostics)) ?? Data(), as: UTF8.self)
            if detail.contains("-1743") || detail.localizedCaseInsensitiveContains("not authorized") {
                throw Failure("Allow Citrus to control Pages in System Settings → Privacy & Security → Automation, then try again.")
            }
            throw Failure("Pages could not save the document. Open Pages to finish any setup, then try again. " + String(detail.prefix(800)))
        }
    }

    private final class LegacyTextParser: NSObject, XMLParserDelegate {
        var result = "", textDepth = 0, prototypeDepth = 0, paragraphDepth = 0, hasDocument = false
        func read(_ data: Data) throws -> String {
            let prefix = String(decoding: data, as: UTF8.self).uppercased()
            guard data.count <= limit, !prefix.contains("<!DOCTYPE"), !prefix.contains("<!ENTITY") else { throw Failure("Pages XML contains unsupported declarations or exceeds the import limit.") }
            let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = self
            guard parser.parse() else { throw Failure("The Pages XML is malformed: \(parser.parserError?.localizedDescription ?? "unknown error")") }
            guard hasDocument else { throw Failure("The XML is not a Pages document.") }
            return result
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
            if name == "document" && namespaceURI == "http://developer.apple.com/namespaces/sl" { hasDocument = true }
            if name == "section-prototypes" { prototypeDepth += 1 }
            if prototypeDepth > 0 { return }
            if name == "text-body" && namespaceURI == sf { textDepth += 1 }
            if name == "p" && textDepth > 0 { paragraphDepth += 1 }
            if textDepth > 0 && paragraphDepth > 0 {
                if ["br", "pgbr", "sectbr", "layoutbr", "contbr", "footnotebr"].contains(name) { result += "\n" }
                if name == "tab" { result += "\t" }
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if textDepth > 0 && paragraphDepth > 0 && prototypeDepth == 0 { result += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "p" && textDepth > 0 { paragraphDepth = max(0,paragraphDepth-1) }
            if name == "text-body" && namespaceURI == sf { textDepth = max(0,textDepth-1) }
            if name == "section-prototypes" { prototypeDepth = max(0,prototypeDepth-1) }
        }
    }

    private struct Package {
        var url: URL
        var directory: Bool
        var names: [String]
        var temporary: URL?
        init(_ input: URL) throws {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else { throw Failure("The Pages file does not exist.") }
            directory = isDirectory.boolValue
            if directory {
                url = input; temporary = nil
                guard let enumerator = FileManager.default.enumerator(at: input, includingPropertiesForKeys: [.isSymbolicLinkKey,.isRegularFileKey], options: []) else { throw Failure("Cannot read Pages package.") }
                var collected: [String] = []
                for case let child as URL in enumerator {
                    let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey,.isRegularFileKey])
                    guard values.isSymbolicLink != true else { throw Failure("Pages packages containing symbolic links are not supported.") }
                    if values.isRegularFile == true { collected.append(String(child.path.dropFirst(input.path.count+1))) }
                    guard collected.count <= 4096 else { throw Failure("The Pages package has too many files.") }
                }
                names = collected
            } else {
                let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= limit else { throw Failure("The Pages file exceeds the 128 MB import limit.") }
                let list = try command("/usr/bin/unzip", ["-Z1", input.path], maximum: 1024 * 1024)
                let found = String(decoding: list, as: UTF8.self).split(separator: "\n").map(String.init)
                guard found.count <= 4096, found.allSatisfy({ !$0.hasPrefix("/") && !$0.contains("\\") && !$0.split(separator: "/").contains("..") }) else { throw Failure("The Pages archive contains unsupported paths or too many files.") }
                url = input; names = found; temporary = nil
            }
            if names.contains("Index.zip"), !names.contains("Index/Document.iwa") {
                let nested = FileManager.default.temporaryDirectory.appendingPathComponent("citrus-pages-index-" + UUID().uuidString + ".zip")
                do {
                    try read("Index.zip").write(to: nested)
                    let listing = try command("/usr/bin/unzip", ["-Z1", nested.path], maximum: 1024*1024)
                    let entries = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
                    guard entries.count <= 4096, entries.allSatisfy({ !$0.hasPrefix("/") && !$0.contains("\\") && !$0.split(separator: "/").contains("..") }) else { throw Failure("The nested Pages archive contains unsupported paths.") }
                    names = entries; url = nested; temporary = nested; directory = false
                } catch { try? FileManager.default.removeItem(at: nested); throw error }

            }
        }
        func read(_ name: String) throws -> Data {
            guard names.contains(name), !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), !name.contains("\\") else { throw Failure("Invalid Pages member path.") }
            if directory {
                let member = url.appendingPathComponent(name)
                guard (try member.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= limit else { throw Failure("Pages member exceeds import limit.") }
                return try Data(contentsOf: member)
            }
            return try command("/usr/bin/unzip", ["-p", url.path, name], maximum: limit)
        }
        func cleanUp() { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    }

    private struct Field { var number: Int; var integer: UInt64?; var bytes: Data? }
    private struct Object { var id: UInt64; var type: UInt64; var payload: Data; var order: Int }
    private static func varint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < bytes.count else { throw Failure("Truncated Pages protobuf integer.") }
            let b = bytes[index]; index += 1
            guard shift < 63 || b <= 1 else { throw Failure("Invalid Pages protobuf integer.") }
            value |= UInt64(b & 127) << shift
            if b & 128 == 0 { return value }
        }
        throw Failure("Invalid Pages protobuf integer.")
    }
    private static func fields(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data); var index = 0; var result: [Field] = []
        while index < bytes.count {
            let tag = try varint(bytes, &index), number = Int(tag >> 3)
            guard number > 0, result.count < 1_000_000 else { throw Failure("Invalid Pages protobuf field.") }
            switch tag & 7 {
            case 0: result.append(Field(number: number, integer: try varint(bytes, &index)))
            case 1: guard bytes.count-index >= 8 else { throw Failure("Truncated Pages fixed field.") }; index += 8
            case 2:
                let size = try varint(bytes, &index)
                guard size <= UInt64(bytes.count-index) else { throw Failure("Truncated Pages protobuf message.") }
                let end = index+Int(size); result.append(Field(number: number, bytes: Data(bytes[index..<end]))); index = end
            case 5: guard bytes.count-index >= 4 else { throw Failure("Truncated Pages fixed field.") }; index += 4
            default: throw Failure("Unsupported Pages protobuf wire type.")
            }
        }
        return result
    }
    private static func archives(_ data: Data) throws -> [Object] {
        let bytes = [UInt8](data); var index = 0; var result: [Object] = []
        while index < bytes.count {
            let length = try varint(bytes,&index)
            guard length <= UInt64(bytes.count-index) else { throw Failure("Truncated Pages archive header.") }
            let header = try fields(Data(bytes[index..<index+Int(length)])); index += Int(length)
            let id = header.first(where: { $0.number == 1 })?.integer ?? 0
            for info in header where info.number == 2 {
                guard let message = info.bytes else { throw Failure("Invalid Pages message information.") }
                let fields = try self.fields(message)
                guard let type = fields.first(where: { $0.number == 1 })?.integer, let size = fields.first(where: { $0.number == 3 })?.integer, size <= UInt64(bytes.count-index) else { throw Failure("Truncated Pages archive payload.") }
                result.append(Object(id: id, type: type, payload: Data(bytes[index..<index+Int(size)]), order: result.count)); index += Int(size)
                guard result.count <= 100_000 else { throw Failure("The Pages archive has too many objects.") }
            }
        }
        return result
    }
    private static func snappyStream(_ data: Data) throws -> Data {
        let bytes = [UInt8](data); var index = 0; var output = Data()
        while index < bytes.count {
            guard bytes.count-index >= 4 else { throw Failure("Truncated Pages Snappy chunk.") }
            let type = bytes[index], size = Int(bytes[index+1]) | Int(bytes[index+2]) << 8 | Int(bytes[index+3]) << 16; index += 4
            guard size <= bytes.count-index else { throw Failure("Truncated Pages Snappy payload.") }
            guard type == 0 else { throw Failure("Unsupported Pages compression chunk.") }
            output.append(try snappyBlock(Array(bytes[index..<index+size]))); index += size
            guard output.count <= limit else { throw Failure("Decoded Pages data exceeds the import limit.") }
        }
        return output
    }
    private static func snappyBlock(_ input: [UInt8]) throws -> Data {
        var index = 0
        let count = try varint(input,&index)
        guard count <= UInt64(limit) else { throw Failure("Pages Snappy block exceeds import limit.") }
        var output: [UInt8] = []; output.reserveCapacity(Int(count))
        while index < input.count {
            let tag = input[index]; index += 1
            var length = 0, distance = 0
            switch tag & 3 {
            case 0:
                let code = Int(tag >> 2)
                if code < 60 { length = code+1 }
                else {
                    let n = code-59
                    guard input.count-index >= n else { throw Failure("Truncated Pages Snappy literal.") }
                    for byte in 0..<n { length |= Int(input[index+byte]) << (8*byte) }; index += n; length += 1
                }
                guard length <= input.count-index, length <= Int(count)-output.count else { throw Failure("Invalid Pages Snappy literal length.") }
                output.append(contentsOf: input[index..<index+length]); index += length; continue
            case 1:
                guard index < input.count else { throw Failure("Truncated Pages Snappy copy.") }
                length = 4 + Int((tag >> 2) & 7); distance = Int(tag & 0xE0) << 3 | Int(input[index]); index += 1
            case 2:
                guard input.count-index >= 2 else { throw Failure("Truncated Pages Snappy copy.") }
                length = 1 + Int(tag >> 2); distance = Int(input[index]) | Int(input[index+1]) << 8; index += 2
            default:
                guard input.count-index >= 4 else { throw Failure("Truncated Pages Snappy copy.") }
                length = 1 + Int(tag >> 2)
                for byte in 0..<4 { distance |= Int(input[index+byte]) << (8*byte) }; index += 4
            }
            guard distance > 0, distance <= output.count, length <= Int(count)-output.count else { throw Failure("Invalid Pages Snappy back-reference.") }
            for _ in 0..<length { output.append(output[output.count-distance]) }
        }
        guard output.count == Int(count) else { throw Failure("Pages Snappy size does not match its header.") }
        return Data(output)
    }
    @discardableResult private static func command(_ executable: String, _ arguments: [String], maximum: Int, directory: URL? = nil) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.currentDirectoryURL = directory
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); var data = Data()
        while true {
            let chunk = output.fileHandleForReading.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            guard chunk.count <= maximum-data.count else { process.terminate(); process.waitUntilExit(); throw Failure("Pages package processing exceeds the import limit.") }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("Could not read or write the Pages package (\(URL(fileURLWithPath: executable).lastPathComponent)).") }
        return data
    }
}
