import Foundation
import AppKit

/// Readers for document containers, kept separate from transformation routing.
enum DocumentImport {
    typealias Failure = DocumentEngine.Failure
    static func commandData(_ executable: String, _ arguments: [String]) throws -> Data {
        let task = Process(), out = Pipe()
        let errors = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errors) }
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? errorHandle.close() }
        task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.standardOutput = out; task.standardError = errorHandle
        try task.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        let diagnostics = String(data: (try? Data(contentsOf: errors)) ?? Data(), encoding: .utf8) ?? ""
        let reportedReadError = executable == "/usr/bin/textutil" && (diagnostics.lowercased().contains("error reading") || diagnostics.lowercased().contains("error converting"))
        guard task.terminationStatus == 0, !reportedReadError else { throw Failure(String(diagnostics.prefix(2000)).isEmpty ? "Document reader failed." : diagnostics) }
        return data
    }
    static func archiveData(_ input: URL, _ member: String) throws -> Data {
        guard !member.hasPrefix("/"), !member.split(separator: "/").contains(".."), !member.contains("\\") else { throw Failure("Unsafe document member path.") }
        return try commandData("/usr/bin/unzip", ["-p", input.path, member])
    }
    static func xml(_ data: Data, html: Bool = false) throws -> XMLDocument {
        try XMLDocument(data: data, options: html ? [.documentTidyHTML, .nodeLoadExternalEntitiesNever] : [.nodeLoadExternalEntitiesNever])
    }
    static func attribute(_ element: XMLElement, _ name: String) -> String? {
        element.attributes?.first { $0.name?.components(separatedBy: ":").last == name }?.stringValue
    }
    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s.replacingOccurrences(of: "\u{feff}", with: "") }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        throw Failure("Unsupported text encoding.")
    }
    static func htmlText(_ data: Data) throws -> String {
        let document = try xml(data, html: true)
        let root = try document.nodes(forXPath: "//*[local-name()='body']").first ?? document
        let blocks: Set<String> = ["p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "blockquote"]
        func visit(_ node: XMLNode) -> String {
            if node.kind == .text { return node.stringValue ?? "" }
            let name = node.name?.lowercased().components(separatedBy: ":").last ?? ""
            if ["script", "style", "head"].contains(name) { return "" }
            if name == "br" { return "\n" }
            let text = (node.children ?? []).map(visit).joined()
            return blocks.contains(name) ? text + "\n" : (name == "td" || name == "th" ? text + "\t" : text)
        }
        return visit(root).replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func readText(_ input: URL) throws -> String {
        let ext = input.pathExtension.lowercased()
        switch ext {
        case "txt", "md", "csv", "tsv", "json", "log": return try decode(Data(contentsOf: input))
        case "html", "htm", "xhtml": return try htmlText(Data(contentsOf: input))
        case "rtf": return try NSAttributedString(data: Data(contentsOf: input), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
        case "rtfd":
            if let attr = try? NSAttributedString(url: input, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) { return attr.string }
            return try readText(input.appendingPathComponent("TXT.rtf"))
        case "docx":
            let document = try xml(archiveData(input, "word/document.xml"))
            let paragraphs = try document.nodes(forXPath: "//*[local-name()='body']//*[local-name()='p']")
            return try paragraphs.map { paragraph in
                try paragraph.nodes(forXPath: ".//*[local-name()='t' or local-name()='br' or local-name()='tab']").map { node in
                    switch node.name?.components(separatedBy: ":").last { case "br": return "\n"; case "tab": return "\t"; default: return node.stringValue ?? "" }
                }.joined()
            }.joined(separator: "\n")
        case "epub": return try epubText(input)
        case "textclipping": return try clippingText(input)
        case "doc", "odt", "webarchive":
            try validateDocument(input)
            let data = try commandData("/usr/bin/textutil", ["-convert", "txt", "-stdout", input.path])
            let text = try decode(data)
            guard !text.lowercased().hasPrefix("error reading"), !text.lowercased().hasPrefix("error converting") else { throw Failure(text) }
            return text
        default: throw Failure("No text reader for .\(ext) documents.")
        }
    }
    static func validateDocument(_ input: URL) throws {
        let ext = input.pathExtension.lowercased()
        if ext == "doc" {
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 512) ?? Data()
            let prefix = String(data: data, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard data.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) || prefix.hasPrefix("{\\rtf") || prefix.hasPrefix("<html") || prefix.hasPrefix("<!doctype html") else { throw Failure("The .doc source is not a supported Word, RTF, or HTML document.") }
        }
    }
    static func clippingText(_ input: URL) throws -> String {
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: input), options: [], format: nil)
        guard let root = object as? [String: Any], let values = root["UTI-Data"] as? [String: Any] else { throw Failure("This text clipping has no readable UTI-Data payload.") }
        for key in ["public.utf8-plain-text", "public.plain-text", "public.text", "public.utf16-plain-text"] {
            if let value = values[key] as? String { return value }
            if let data = values[key] as? Data {
                if key.contains("utf16"), !data.starts(with: [0xff, 0xfe]), !data.starts(with: [0xfe, 0xff]), let value = String(data: data, encoding: .utf16LittleEndian) { return value }
                return try decode(data)
            }
        }
        for key in ["public.rtf", "NeXT Rich Text Format v1.0 pasteboard type"] {
            if let data = values[key] as? Data { return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string }
        }
        if let data = values["public.html"] as? Data { return try htmlText(data) }
        if let string = values["public.html"] as? String { return try htmlText(Data(string.utf8)) }
        throw Failure("Text clipping contains no supported text representation.")
    }
    static func epubText(_ input: URL) throws -> String {
        let container = try xml(archiveData(input, "META-INF/container.xml"))
        guard let rootfile = try container.nodes(forXPath: "//*[local-name()='rootfile']").first as? XMLElement, let path = attribute(rootfile, "full-path") else { throw Failure("EPUB has no package document.") }
        let package = try xml(archiveData(input, path))
        var manifest: [String: String] = [:]
        for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            if let id = attribute(item, "id"), let href = attribute(item, "href") { manifest[id] = href }
        }
        let directory = URL(fileURLWithPath: "/" + path).deletingLastPathComponent()
        var chapters: [String] = []
        for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            guard let id = attribute(item, "idref"), let href = manifest[id], !href.contains("://") else { throw Failure("EPUB spine refers to a missing chapter.") }
            let stripped = href.components(separatedBy: "#")[0].removingPercentEncoding ?? href
            guard !stripped.hasPrefix("/") else { throw Failure("Invalid EPUB chapter path.") }
            let member = directory.appendingPathComponent(stripped).standardizedFileURL.path.dropFirst()
            chapters.append(try htmlText(archiveData(input, String(member))))
        }
        guard !chapters.isEmpty else { throw Failure("EPUB has no readable spine chapters.") }
        return chapters.joined(separator: "\n\n")
    }
    static func readODS(_ input: URL) throws -> [[String]] {
        let document = try xml(archiveData(input, "content.xml"))
        guard let table = try document.nodes(forXPath: "//*[local-name()='spreadsheet']/*[local-name()='table']").first else { throw Failure("ODS has no worksheet.") }
        var rows: [[String]] = []
        for case let row as XMLElement in try table.nodes(forXPath: ".//*[local-name()='table-row']") {
            var cells: [String] = []
            for case let cell as XMLElement in try row.nodes(forXPath: "./*[local-name()='table-cell' or local-name()='covered-table-cell']") {
                let count = Int(attribute(cell, "number-columns-repeated") ?? "1") ?? 1
                let paragraphs = try cell.nodes(forXPath: ".//*[local-name()='p']").map { try odsNodeText($0) }
                let value = paragraphs.isEmpty ? (attribute(cell, "string-value") ?? attribute(cell, "value") ?? attribute(cell, "date-value") ?? attribute(cell, "boolean-value") ?? "") : paragraphs.joined(separator: "\n")
                guard count > 0, count <= 16_384 else { if value.isEmpty { continue }; throw Failure("ODS column repetition is too large.") }
                if value.isEmpty && cells.count + count > 16_384 { continue }
                guard cells.count + count <= 16_384 else { throw Failure("ODS exceeds the column limit.") }
                cells.append(contentsOf: repeatElement(value, count: count))
            }
            while cells.last == "" { cells.removeLast() }
            let count = Int(attribute(row, "number-rows-repeated") ?? "1") ?? 1
            if cells.isEmpty && count > 1000 { continue }
            guard count > 0, count <= 100_000, rows.count + count <= 100_000 else { throw Failure("ODS exceeds 100,000 rows.") }
            rows.append(contentsOf: repeatElement(cells, count: count))
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func odsNodeText(_ node: XMLNode) throws -> String {
        if node.kind == .text { return node.stringValue ?? "" }
        let name = node.name?.components(separatedBy: ":").last ?? ""
        if name == "s", let element = node as? XMLElement {
            let count = Int(attribute(element, "c") ?? "1") ?? 1
            guard count > 0, count <= 1_000_000 else { throw Failure("Invalid ODS whitespace repetition.") }
            return String(repeating: " ", count: count)
        }
        if name == "tab" { return "\t" }
        if name == "line-break" { return "\n" }
        return try (node.children ?? []).map { try odsNodeText($0) }.joined()
    }
    private static func odsParagraph(_ value: String) -> String {
        var output = "", spaces = 0
        func flush() { if spaces > 0 { output += "<text:s text:c=\"\(spaces)\"/>"; spaces = 0 } }
        for character in value {
            if character == " " { spaces += 1; continue }
            flush()
            if character == "\t" { output += "<text:tab/>" }
            else { output += escape(String(character)) }
        }
        flush()
        return output
    }
    static func writeODS(_ rows: [[String]], to output: URL) throws {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("citrus-ods-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try "application/vnd.oasis.opendocument.spreadsheet".write(to: stage.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        let body = rows.map { row in "<table:table-row>" + row.map { "<table:table-cell office:value-type=\"string\"><text:p>\($0.components(separatedBy: "\n").map(odsParagraph).joined(separator: "</text:p><text:p>"))</text:p></table:table-cell>" }.joined() + "</table:table-row>" }.joined()
        let content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\"><office:body><office:spreadsheet><table:table table:name=\"Sheet1\">\(body)</table:table></office:spreadsheet></office:body></office:document-content>"
        try content.write(to: stage.appendingPathComponent("content.xml"), atomically: true, encoding: .utf8)
        let manifest = "<?xml version=\"1.0\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"
        try manifest.write(to: stage.appendingPathComponent("META-INF/manifest.xml"), atomically: true, encoding: .utf8)
        func zip(_ args: [String]) throws {
            let task = Process(), pipe = Pipe(); task.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); task.arguments = args; task.currentDirectoryURL = stage; task.standardError = pipe; task.standardOutput = pipe
            try task.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw Failure(String(data: data, encoding: .utf8) ?? "ODS packaging failed.") }
        }
        try zip(["-q", "-0", output.path, "mimetype"])
        try zip(["-q", "-r", output.path, "content.xml", "META-INF"])
    }
}

extension DocumentImport {
    /// BIFF5/8 workbook values in an OLE Compound File. Formulas use cached values.
    static func readXLS(_ input: URL) throws -> [[String]] {
        let bytes = [UInt8](try Data(contentsOf: input))
        func integer(_ data: [UInt8], _ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, count <= 8, offset <= data.count - count else { throw Failure("Truncated XLS file.") }
            return (0..<count).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
        }
        func u16(_ b: [UInt8], _ p: Int) throws -> Int { Int(try integer(b,p,2)) }
        func u32(_ b: [UInt8], _ p: Int) throws -> Int { Int(try integer(b,p,4)) }
        guard bytes.count >= 512, Array(bytes.prefix(8)) == [0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1] else {
            if let text = String(bytes: bytes, encoding: .utf8), text.contains("<") { return try htmlSpreadsheet(Data(bytes)) }
            throw Failure("XLS is not a supported OLE BIFF workbook.")
        }
        let shift = try u16(bytes,30)
        guard shift == 9 || shift == 12 else { throw Failure("Invalid XLS sector size.") }
        let sectorSize = 1 << shift
        func sector(_ id: Int) throws -> [UInt8] {
            guard id >= 0, id < bytes.count / sectorSize else { throw Failure("Invalid XLS sector reference.") }
            let start = (id + 1) * sectorSize
            guard start <= bytes.count - sectorSize else { throw Failure("Truncated XLS sector.") }
            return Array(bytes[start..<start + sectorSize])
        }
        let endMarker = 0xfffffff0
        var fatIDs: [Int] = []
        for index in 0..<109 { let id = try u32(bytes,76 + index * 4); if id < endMarker { fatIDs.append(id) } }
        var difat = try u32(bytes,68), seenDifat: Set<Int> = []
        while difat < endMarker {
            guard seenDifat.insert(difat).inserted else { throw Failure("Cyclic XLS allocation table.") }
            let block = try sector(difat)
            for index in 0..<(sectorSize / 4 - 1) { let id = try u32(block,index * 4); if id < endMarker { fatIDs.append(id) } }
            difat = try u32(block,sectorSize - 4)
        }
        var fat: [Int] = []
        for id in fatIDs { let block = try sector(id); for index in stride(from: 0,to: block.count,by: 4) { fat.append(try u32(block,index)) } }
        func chain(_ start: Int, _ allocation: [Int], _ read: (Int) throws -> [UInt8]) throws -> [UInt8] {
            var id = start, result: [UInt8] = [], seen: Set<Int> = []
            while id < endMarker {
                guard allocation.indices.contains(id), seen.insert(id).inserted, result.count < 256_000_000 else { throw Failure("Invalid or excessive XLS stream chain.") }
                result += try read(id); id = allocation[id]
            }
            return result
        }
        let directory = try chain(u32(bytes,48),fat,sector)
        var book: (Int,Int)?, root: (Int,Int)?
        for offset in stride(from: 0,to: directory.count - 127,by: 128) {
            let nameLength = try u16(directory,offset + 64)
            guard nameLength >= 2, nameLength <= 64 else { continue }
            let name = String(data: Data(directory[offset..<offset + nameLength - 2]), encoding: .utf16LittleEndian) ?? ""
            let start = try u32(directory,offset + 116), size64 = try integer(directory,offset + 120,8)
            guard size64 <= 256_000_000 else { throw Failure("XLS stream is too large.") }
            let info = (start,Int(size64))
            if directory[offset + 66] == 5 { root = info }
            if name == "Workbook" || name == "Book" { book = info }
        }
        guard let book else { throw Failure("XLS contains no Workbook stream.") }
        var workbook: [UInt8]
        if book.1 < 4096 {
            guard let root else { throw Failure("Missing XLS mini stream.") }
            let miniStream = try chain(root.0,fat,sector)
            let miniFatBytes = try chain(u32(bytes,60),fat,sector)
            var miniFat: [Int] = []
            for i in stride(from: 0,to: miniFatBytes.count,by: 4) { miniFat.append(try u32(miniFatBytes,i)) }
            workbook = try chain(book.0,miniFat) { id in
                let offset = id * 64
                guard offset >= 0, offset <= miniStream.count - 64 else { throw Failure("Invalid XLS mini sector.") }
                return Array(miniStream[offset..<offset + 64])
            }
        } else { workbook = try chain(book.0,fat,sector) }
        workbook = Array(workbook.prefix(book.1))
        struct Record { let id: Int; let start: Int; let bytes: [UInt8] }
        var records: [Record] = [], position = 0
        while position + 4 <= workbook.count {
            let id = try u16(workbook,position), count = try u16(workbook,position + 2)
            guard position + 4 + count <= workbook.count else { throw Failure("Truncated XLS BIFF record.") }
            records.append(Record(id: id,start: position,bytes: Array(workbook[position + 4..<position + 4 + count])))
            position += count + 4
        }
        guard !records.contains(where: { $0.id == 0x2f }) else { throw Failure("Password protected XLS workbooks are unsupported.") }
        var shared: [String] = []
        if let index = records.firstIndex(where: { $0.id == 0xfc }) {
            var chunks = [records[index].bytes], next = index + 1
            while next < records.count && records[next].id == 0x3c { chunks.append(records[next].bytes); next += 1 }
            var chunk = 0, offset = 8
            func byte() throws -> UInt8 {
                while chunk < chunks.count && offset >= chunks[chunk].count { chunk += 1; offset = 0 }
                guard chunk < chunks.count else { throw Failure("Truncated XLS shared string table.") }
                defer { offset += 1 }; return chunks[chunk][offset]
            }
            func number(_ count: Int) throws -> Int { var value = 0; for index in 0..<count { value |= Int(try byte()) << (8 * index) }; return value }
            let total = try u32(chunks[0],4)
            guard total <= 1_000_000 else { throw Failure("XLS string table is too large.") }
            for _ in 0..<total {
                let count = try number(2), flags = try number(1)
                let runs = flags & 8 != 0 ? try number(2) : 0
                let extensionBytes = flags & 4 != 0 ? try number(4) : 0
                var wide = flags & 1 != 0, units: [UInt16] = []
                for _ in 0..<count {
                    if chunk < chunks.count && offset >= chunks[chunk].count { chunk += 1; offset = 0; wide = try byte() & 1 != 0 }
                    let low = UInt16(try byte()), high = wide ? UInt16(try byte()) : 0
                    units.append(low | high << 8)
                }
                shared.append(String(decoding: units,as: UTF16.self))
                guard runs <= 1_000_000, extensionBytes <= 16_000_000 else { throw Failure("Excessive XLS rich text data.") }
                for _ in 0..<(runs * 4 + extensionBytes) { _ = try byte() }
            }
        }
        let biff8 = try records.first(where: { $0.id == 0x809 && $0.bytes.count >= 2 }).map { try u16($0.bytes,0) >= 0x600 } ?? true
        let sheetOffset = try records.first(where: { $0.id == 0x85 && $0.bytes.count >= 6 && $0.bytes[5] == 0 }).map { try u32($0.bytes,0) }
        guard let sheetOffset else { throw Failure("XLS has no worksheet.") }
        var cells: [Int: [Int: String]] = [:], maxRow = -1, maxColumn = -1
        func put(_ r: Int, _ c: Int, _ value: String) throws {
            guard r < 100_000, c < 16_384 else { throw Failure("XLS worksheet dimensions exceed supported limits.") }
            if !value.isEmpty { cells[r,default: [:]][c] = value; maxRow = max(maxRow,r); maxColumn = max(maxColumn,c) }
        }
        func rk(_ value: Int) -> String {
            var number: Double
            if value & 2 != 0 { number = Double(Int32(bitPattern: UInt32(value)) >> 2) }
            else { number = Double(bitPattern: UInt64(value & 0xfffffffc) << 32) }
            if value & 1 != 0 { number /= 100 }
            return String(number)
        }
        for record in records where record.start >= sheetOffset {
            if record.id == 0x0a { break }
            let b = record.bytes
            guard b.count >= 6 else { continue }
            let row = try u16(b,0), column = try u16(b,2)
            switch record.id {
            case 0xfd where b.count >= 10:
                let index = try u32(b,6); guard shared.indices.contains(index) else { throw Failure("Invalid XLS shared string reference.") }; try put(row,column,shared[index])
            case 0x203 where b.count >= 14: try put(row,column,String(Double(bitPattern: integer(b,6,8))))
            case 0x27e where b.count >= 10: try put(row,column,rk(u32(b,6)))
            case 0xbd where b.count >= 12:
                for offset in stride(from: 4,to: b.count - 2,by: 6) where offset + 6 <= b.count - 2 { try put(row,column + (offset - 4) / 6,rk(u32(b,offset + 2))) }
            case 0x205 where b.count >= 8: try put(row,column,b[7] == 0 ? (b[6] == 0 ? "FALSE" : "TRUE") : "#ERROR")
            case 0x6 where b.count >= 14:
                if b[12] != 0xff || b[13] != 0xff { try put(row,column,String(Double(bitPattern: integer(b,6,8)))) }
            case 0x204 where b.count >= 8:
                guard !biff8 || b.count >= 9 else { throw Failure("Truncated XLS label.") }
                let count = try u16(b,6), wide = biff8 && b[8] & 1 != 0, length = count * (wide ? 2 : 1), start = biff8 ? 9 : 8
                guard start + length <= b.count else { throw Failure("Truncated XLS label.") }
                try put(row,column,String(data: Data(b[start..<start + length]),encoding: wide ? .utf16LittleEndian : .isoLatin1) ?? "")
            default: break
            }
        }
        guard maxRow >= 0 else { return [] }
        guard (maxRow + 1) * (maxColumn + 1) <= 5_000_000 else { throw Failure("XLS worksheet is too large to materialize.") }
        return (0...maxRow).map { row in (0...maxColumn).map { cells[row]?[$0] ?? "" } }
    }
    private static func htmlSpreadsheet(_ data: Data) throws -> [[String]] {
        let document = try xml(data,html: true)
        return try document.nodes(forXPath: "//*[local-name()='table'][1]//*[local-name()='tr']").map { row in
            try row.nodes(forXPath: "./*[local-name()='td' or local-name()='th']").map { $0.stringValue ?? "" }
        }
    }
}
