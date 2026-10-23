import Foundation
import AppKit
import PDFKit
import ImageIO

/// Shift-only audit. Calls the same AppModel submission route as a wheel drop.
struct ConversionAudit {
    static let marker="Citrus conversion audit 48271"
    static func command(_ exe:String,_ args:[String])throws->String {
        let p=Process();p.executableURL=URL(fileURLWithPath:exe);p.arguments=args
        let out=Pipe();p.standardOutput=out;p.standardError=out;try p.run()
        let data=out.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        let value=String(data:data,encoding:.utf8) ?? ""
        guard p.terminationStatus==0 else{throw UIError.message(String(value.prefix(1200)))}
        return value
    }
    static func inventory()->[[String:Any]] {
        SettingsCatalog.all.filter{$0 != "html"}.map{source in
            let wheel=WheelDropView(group:"Conversions",inputs:[URL(fileURLWithPath:"/tmp/audit.\(source)")],onDrop:{_,_ in},onClose:{})
            return ["source":source,"offered":wheel.tools.map(\.id),"reference":SettingsCatalog.targets(source)]
        }
    }
    static func fixtures(_ root:URL)throws {
        let fm=FileManager.default;try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let txt=root.appendingPathComponent("sample.txt");try (marker+"\nSecond paragraph.\n").write(to:txt,atomically:true,encoding:.utf8)
        try (marker+"\n").write(to:root.appendingPathComponent("sample.md"),atomically:true,encoding:.utf8)
        try ("Name,Value\n\(marker),42\n").write(to:root.appendingPathComponent("sample.csv"),atomically:true,encoding:.utf8)
        try ("Name\tValue\n\(marker)\t42\n").write(to:root.appendingPathComponent("sample.tsv"),atomically:true,encoding:.utf8)
        try "1\n00:00:00,100 --> 00:00:00,700\n\(marker)\n".write(to:root.appendingPathComponent("sample.srt"),atomically:true,encoding:.utf8)
        try "WEBVTT\n\n00:00:00.100 --> 00:00:00.700\n\(marker)\n".write(to:root.appendingPathComponent("sample.vtt"),atomically:true,encoding:.utf8)
        try "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"96\" height=\"64\"><rect width=\"96\" height=\"64\" fill=\"orange\"/><circle cx=\"32\" cy=\"32\" r=\"16\" fill=\"blue\"/></svg>".write(to:root.appendingPathComponent("sample.svg"),atomically:true,encoding:.utf8)
        let bmp=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:96,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bmp);NSColor.orange.setFill();NSRect(x:0,y:0,width:96,height:64).fill();NSColor.blue.setFill();NSRect(x:12,y:10,width:24,height:20).fill();NSGraphicsContext.restoreGraphicsState()
        let png=root.appendingPathComponent("sample.png");try bmp.representation(using:.png,properties:[:])!.write(to:png)
        func attempt(_ ext:String,_ work:()throws->URL){do{let url=try work();let target=root.appendingPathComponent("sample.\(ext)");if url != target {try? fm.removeItem(at:target);try fm.moveItem(at:url,to:target)};print("FIXTURE \(ext)")}catch{print("NO_FIXTURE \(ext): \(error.localizedDescription)")}}
        for ext in ["jpg","tiff","bmp","webp","avif","heic"] {attempt(ext){try MediaEngine.run("convert",inputs:[png],outputDirectory:root,options:["format":ext,"preserveMetadata":"true","quality":"80"])[0]}}
        for ext in ["docx","rtf","rtfd"] {attempt(ext){try DocumentEngine.run("convert",inputs:[txt],outputDirectory:root,options:["format":ext])[0]}}
        attempt("pdf"){try DocumentEngine.run("createPDF",inputs:[txt],outputDirectory:root,options:[:])[0]}
        attempt("epub"){try DocumentEngine.run("convert",inputs:[txt],outputDirectory:root,options:["format":"epub"])[0]}
        attempt("xlsx"){try DocumentEngine.run("convert",inputs:[root.appendingPathComponent("sample.csv")],outputDirectory:root,options:["format":"xlsx"])[0]}
        for ext in ["zip","tar","gzip"] {attempt(ext){try DocumentEngine.run("createArchive",inputs:[txt],outputDirectory:root,options:["format":ext])[0]}}
        // .gzip is the archive fixture's UI extension; content is a genuine TAR.GZ.
        for ext in ["mp3","m4a","wav","flac","ogg","opus","aiff","wma"] {attempt(ext){
            let target=root.appendingPathComponent("sample.\(ext)")
            let codec=ext=="ogg" ? ["-ac","2","-c:a","vorbis","-strict","-2"]:ext=="opus" ? ["-c:a","libopus"]:[]
            _=try command("/opt/homebrew/bin/ffmpeg",["-v","error","-nostdin","-y","-f","lavfi","-i","sine=frequency=440:duration=0.8"]+codec+[target.path]);return target
        }}
        for ext in ["mp4","mov","mkv","webm","avi","wmv","gif"] {attempt(ext){
            let target=root.appendingPathComponent("sample.\(ext)")
            var args=["-v","error","-nostdin","-y","-f","lavfi","-i","testsrc2=size=96x64:rate=10:duration=0.8"]
            if ext != "gif" {args += ["-f","lavfi","-i","sine=frequency=440:duration=0.8","-shortest"]}
            if ["mp4","mov","mkv"].contains(ext) {args += ["-c:v","libx264","-c:a","aac","-pix_fmt","yuv420p"]}
            if ext=="webm" {args += ["-c:v","libvpx-vp9","-c:a","libopus"]}
            args += [target.path];_=try command("/opt/homebrew/bin/ffmpeg",args);return target
        }}
        // Native Pages fixtures are opt-in because export opens Pages and can request Automation permission.
        if ProcessInfo.processInfo.environment["CITRUS_AUDIT_PAGES"] == "1" {
            attempt("pages") {
                let target=root.appendingPathComponent("sample.pages")
                try PagesIO.write(text:marker+"\n",to:target)
                return target
            }
        }
    }
    static func rtfdFixture(_ root:URL)throws {
        let text=NSMutableAttributedString(string:marker+"\n")
        let attachment=NSTextAttachment();let file=FileWrapper(regularFileWithContents:try Data(contentsOf:root.appendingPathComponent("sample.png")));file.preferredFilename="audit.png";attachment.fileWrapper=file
        text.append(NSAttributedString(attachment:attachment))
        let wrapper=try text.fileWrapper(from:NSRange(location:0,length:text.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtfd])
        let target=root.appendingPathComponent("sample.rtfd");try? FileManager.default.removeItem(at:target)
        try wrapper.write(to:target,options:.atomic,originalContentsURL:nil)
    }
    static func run(_ source:URL,target:String,output:URL)throws->[String:Any] {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let model=AppModel();model.feedbackEnabled=false
        var result:Result<[URL],Error>?
        model.onJobFinished={result=$0}
        let start=Date(), timeout:TimeInterval=target == "pages" ? 145:25
        model.submitWheelDrop(Tool(id:target,name:target.uppercased(),icon:"doc",group:"Format"),urls:[source],destination:output)
        while result==nil && Date().timeIntervalSince(start)<timeout {_ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        guard let result=result else{throw UIError.message("Timed out after \(Int(timeout)) seconds")}
        let files=try result.get()
        guard !files.isEmpty else{throw UIError.message("No output files")}
        for url in files {try validate(url,expected:target,source:source)}
        var evidence:[String:Any]=["status":"PASS","outputs":files.map(\.path),"seconds":Date().timeIntervalSince(start)]
        if target=="pages" {evidence["validationLimit"]="Per-file checks cover package and text. Native compatibility is verified separately on representative exports."}
        return evidence
    }
    static func validate(_ url:URL,expected:String,source:URL)throws {
        let expectedText=ProcessInfo.processInfo.environment["CITRUS_AUDIT_EXPECTED_TEXT"] ?? marker
        let blankSource=ProcessInfo.processInfo.environment["CITRUS_AUDIT_BLANK_SOURCE"]=="1"
        func containsText(_ value:String)->Bool {
            value.replacingOccurrences(of:"\\s+",with:" ",options:.regularExpression).contains(expectedText.replacingOccurrences(of:"\\s+",with:" ",options:.regularExpression))
        }
        let fm=FileManager.default
        guard fm.fileExists(atPath:url.path) else{throw UIError.message("Output does not exist")}
        if ["jpg","png","webp","heic","tiff","avif","bmp"].contains(expected) {
            var decoded=url
            let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("citrus-audit-decode-"+UUID().uuidString+".png")
            defer{try? FileManager.default.removeItem(at:temporary)}
            if expected=="heic" {
                let decoder=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/ConversionRuntime/dependencies/native/libheif/libheif/bin/heif-dec")
                _=try command(decoder.path,["--quiet",url.path,temporary.path]);decoded=temporary
            }else if expected=="avif" {_=try command("/opt/homebrew/bin/ffmpeg",["-v","error","-nostdin","-y","-i",url.path,"-frames:v","1",temporary.path]);decoded=temporary}
            guard let s=CGImageSourceCreateWithURL(decoded as CFURL,nil),let cg=CGImageSourceCreateImageAtIndex(s,0,nil),cg.width>0,cg.height>0 else{throw UIError.message("Output is not a decodable image")}
        }else if expected=="pdf" {
            guard let p=PDFDocument(url:url),p.pageCount>0 else{throw UIError.message("Output is not a readable PDF")}
            if (p.string ?? "").contains("Error reading") {throw UIError.message("PDF contains a source-read error instead of the source document")}
            if source.pathExtension.lowercased()=="textclipping" && ((p.string ?? "").contains("bplist00") || (p.string ?? "").contains("UTI-Data")) {throw UIError.message("PDF contains raw text-clipping plist data, not rendered text")}
            if ["txt","md","docx","rtf","rtfd","csv","tsv","xlsx","epub","pptx","ods","srt","vtt","textclipping","pages"].contains(source.pathExtension.lowercased()) && !blankSource && !containsText(p.string ?? "") {throw UIError.message("PDF output lost the known source text")}
        }else if ["mp3","m4a","wav","flac","ogg","opus","aiff","wma","mp4","mov","mkv","webm","avi","wmv","gif"].contains(expected) {
            let probe=try command("/opt/homebrew/bin/ffprobe",["-v","error","-show_streams","-of","json",url.path])
            guard let obj=try JSONSerialization.jsonObject(with:Data(probe.utf8)) as? [String:Any],let streams=obj["streams"] as? [[String:Any]],!streams.isEmpty else{throw UIError.message("No readable media stream")}
            let video=["mp4","mov","mkv","webm","avi","wmv","gif"].contains(expected)
            guard streams.contains(where:{$0["codec_type"] as? String == (video ? "video":"audio")}) else{throw UIError.message("Required media stream missing")}
            _=try command("/opt/homebrew/bin/ffmpeg",["-v","error","-nostdin","-i",url.path,"-f","null","-"])
        }else if ["zip","tar","gzip"].contains(expected) {
            let listing=try command(expected=="zip" ? "/usr/bin/unzip":"/usr/bin/tar",expected=="zip" ? ["-Z1",url.path]:["-tf",url.path])
            guard listing.contains("sample.txt") || listing.contains(source.lastPathComponent) else{throw UIError.message("Archive lost expected input file")}
        }else if expected=="epub" {
            let listing=try command("/usr/bin/unzip",["-Z1",url.path])
            guard listing.contains("META-INF/container.xml"),listing.contains("OEBPS/content.opf") else{throw UIError.message("Incomplete EPUB package")}
            let content=try command("/usr/bin/unzip",["-p",url.path,"OEBPS/text.xhtml"])
            if content.contains("Error reading") {throw UIError.message("EPUB contains a source-read error instead of the source document")}
            if source.pathExtension.lowercased()=="textclipping" && (content.contains("bplist00") || content.contains("UTI-Data")) {throw UIError.message("EPUB contains raw text-clipping plist data, not extracted text")}
            if !blankSource && !content.contains(expectedText) {throw UIError.message("EPUB lost the known source text")}
        }else if expected=="pages" {
            let listing=try command("/usr/bin/unzip",["-Z1",url.path])
            guard listing.contains("Index/Document.iwa") || listing.contains("index.xml") else{throw UIError.message("Invalid Pages package")}
            let text=try PagesIO.readText(url)
            guard blankSource || text.contains(expectedText) else{throw UIError.message("Pages package lost the known source text")}
        }else if expected=="pptx" {
            let listing=try command("/usr/bin/unzip",["-Z1",url.path])
            guard listing.contains("ppt/presentation.xml"),listing.contains("ppt/media/page1.png"),listing.contains("ppt/slideMasters/slideMaster1.xml"),listing.contains("ppt/slideLayouts/slideLayout7.xml") else{throw UIError.message("Incomplete PowerPoint package: slide master, layout, or page image missing")}
            let slideRelationships=try command("/usr/bin/unzip",["-p",url.path,"ppt/slides/_rels/slide1.xml.rels"])
            guard slideRelationships.contains("/slideLayout"),slideRelationships.contains("/image") else{throw UIError.message("PowerPoint slide is missing its layout or image relationship")}
            let slides=listing.components(separatedBy:.newlines).filter{$0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml")}
            if let pdf=PDFDocument(url:source),pdf.pageCount != slides.count {throw UIError.message("PowerPoint output lost PDF pages")}
            let content=try command("/usr/bin/unzip",["-p",url.path,"ppt/slides/slide1.xml"])
            guard content.contains(expectedText) else{throw UIError.message("PowerPoint output lost the source page's text description")}
        }else if expected=="ods" {
            let listing=try command("/usr/bin/unzip",["-Z1",url.path])
            guard listing.contains("META-INF/manifest.xml"),listing.contains("content.xml") else{throw UIError.message("Invalid ODS package")}
            let xml=try command("/usr/bin/unzip",["-p",url.path,"content.xml"])
            let document=try XMLDocument(xmlString:xml,options:[.nodeLoadExternalEntitiesNever])
            func content(_ node:XMLNode)->String {
                if node.kind == .text {return node.stringValue ?? ""}
                if node.localName=="s" {return String(repeating:" ",count:min(100000,max(1,Int((node as? XMLElement)?.attribute(forName:"text:c")?.stringValue ?? "1") ?? 1)))}
                if node.localName=="tab" {return "\t"}
                if node.localName=="line-break" {return "\n"}
                return (node.children ?? []).map(content).joined()
            }
            guard blankSource || containsText(content(document)) else{throw UIError.message("ODS output lost known cell text")}
        }else if expected=="xlsx" {
            let listing=try command("/usr/bin/unzip",["-Z1",url.path]);guard listing.contains("xl/workbook.xml") else{throw UIError.message("Invalid XLSX package")}
            let strings=try command("/usr/bin/unzip",["-p",url.path,"xl/worksheets/sheet1.xml"])
            guard blankSource || strings.contains(expectedText) else{throw UIError.message("Spreadsheet lost known cell text")}
        }else if ["docx","rtf","rtfd","html","txt","md","srt","vtt","ass","csv","tsv","json"].contains(expected) {
            let text:String
            if expected=="html" {text=try String(contentsOf:url,encoding:.utf8).replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression)}
            else if ["docx","rtf","rtfd"].contains(expected) {text=try command("/usr/bin/textutil",["-convert","txt","-stdout",(expected=="rtfd" ? url.appendingPathComponent("TXT.rtf"):url).path])}
            else{text=try String(contentsOf:url,encoding:.utf8)}
            guard blankSource || text.contains(expectedText) else{throw UIError.message("Output lost the known source text")}
            if source.pathExtension.lowercased()=="textclipping" && (text.contains("bplist00") || text.contains("UTI-Data")) {throw UIError.message("Output contains raw text-clipping plist data, not extracted text")}
            if ["srt","vtt"].contains(expected) {guard text.contains("-->") else{throw UIError.message("Subtitle output has no cue timings")}}
        }else {throw UIError.message("No independent output validator for \(expected)")}
    }
}
