import Foundation
import AppKit
import PDFKit

/// Standard OOXML/EPUB packages for the layout choices exposed in Settings.
struct DocumentLayoutWriter {
    private static func escape(_ text:String)->String{text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
    private static func stage()->URL{FileManager.default.temporaryDirectory.appendingPathComponent("citrus-layout-"+UUID().uuidString)}
    private static func write(_ text:String,_ path:String,_ root:URL)throws{
        let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:url)
    }
    private static func zip(_ root:URL,to output:URL,epub:Bool=false)throws{
        if epub {try command("/usr/bin/zip",["-q","-0",output.path,"mimetype"],root)}
        try command("/usr/bin/zip",epub ? ["-q","-r",output.path,"META-INF","OEBPS"]:["-q","-r",output.path,"[Content_Types].xml","_rels","word"],root)
    }
    private static func command(_ executable:String,_ args:[String],_ cwd:URL)throws{
        let task=Process();task.executableURL=URL(fileURLWithPath:executable);task.arguments=args;task.currentDirectoryURL=cwd
        let pipe=Pipe();task.standardOutput=pipe;task.standardError=pipe;try task.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
        guard task.terminationStatus==0 else{throw UIError.message(String(data:data,encoding:.utf8) ?? "Could not create document package.")}
    }
    private static func renderedPages(_ input:URL)throws->[(Data,CGSize)]{
        guard let pdf=PDFDocument(url:input),!pdf.isLocked,pdf.pageCount>0 else{throw UIError.message("Cannot read source PDF.")}
        return try (0..<pdf.pageCount).map{index in
            guard let page=pdf.page(at:index) else{throw UIError.message("Cannot read page.")}
            let size=page.bounds(for:.mediaBox).size
            guard size.width>0,size.height>0,size.width*size.height*4<150_000_000 else{throw UIError.message("PDF page dimensions are too large.")}
            let image=page.thumbnail(of:NSSize(width:size.width*2,height:size.height*2),for:.mediaBox)
            guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let data=bitmap.representation(using:.png,properties:[:]) else{throw UIError.message("Cannot render source PDF page.")}
            return(data,size)
        }
    }
    static func docxPreservingPages(_ input:URL,to output:URL)throws{
        let root=stage();try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let pages=try renderedPages(input)
        var body="",relationships=""
        for (index,page) in pages.enumerated(){
            let i=index+1,path="word/media/page\(i).png";let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try page.0.write(to:url)
            relationships+="<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/page\(i).png\"/>"
            let width=Int(page.1.width*12700),height=Int(max(1,page.1.height-2)*12700)
            body+="<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr><w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(width)\" cy=\"\(height)\"/><wp:docPr id=\"\(i)\" name=\"Page \(i)\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(i)\" name=\"Page \(i)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"rId\(i)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
            let section="<w:sectPr><w:type w:val=\"nextPage\"/><w:pgSz w:w=\"\(Int(page.1.width*20))\" w:h=\"\(Int(page.1.height*20))\"/><w:pgMar w:top=\"0\" w:right=\"0\" w:bottom=\"0\" w:left=\"0\" w:header=\"0\" w:footer=\"0\"/></w:sectPr>"
            body += index==pages.count-1 ? section:"<w:p><w:pPr>\(section)</w:pPr></w:p>"
        }
        try write("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>\(body)</w:body></w:document>","word/document.xml",root)
        try write("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>","word/_rels/document.xml.rels",root)
        try write("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>","_rels/.rels",root)
        try write("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>","[Content_Types].xml",root)
        try zip(root,to:output)
    }
    static func epub(_ input:URL,text:String,keepPages:Bool,to output:URL)throws{
        let root=stage();try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        try write("application/epub+zip","mimetype",root)
        try write("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>","META-INF/container.xml",root)
        var manifest="",spine="",navigation=""
        if keepPages && input.pathExtension.lowercased()=="pdf" {
            for (index,page) in try renderedPages(input).enumerated(){
                let id="page\(index+1)";let imageURL=root.appendingPathComponent("OEBPS/\(id).png");try FileManager.default.createDirectory(at:imageURL.deletingLastPathComponent(),withIntermediateDirectories:true);try page.0.write(to:imageURL)
                try write("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Page \(index+1)</title><meta name=\"viewport\" content=\"width=\(Int(page.1.width*2)),height=\(Int(page.1.height*2))\"/></head><body style=\"margin:0\"><img src=\"\(id).png\" style=\"width:100%;height:100%\" alt=\"Page \(index+1)\"/></body></html>","OEBPS/\(id).xhtml",root)
                manifest+="<item id=\"\(id)\" href=\"\(id).xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"img\(index)\" href=\"\(id).png\" media-type=\"image/png\"/>";spine+="<itemref idref=\"\(id)\"/>";navigation+="<li><a href=\"\(id).xhtml\">Page \(index+1)</a></li>"
            }
        }else{
            let paragraphs=text.components(separatedBy:.newlines).filter{!$0.isEmpty}.map{"<p>\(escape($0))</p>"}.joined()
            try write("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(escape(input.deletingPathExtension().lastPathComponent))</title></head><body>\(paragraphs)</body></html>","OEBPS/text.xhtml",root)
            manifest="<item id=\"text\" href=\"text.xhtml\" media-type=\"application/xhtml+xml\"/>";spine="<itemref idref=\"text\"/>";navigation="<li><a href=\"text.xhtml\">Contents</a></li>"
        }
        try write("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol>\(navigation)</ol></nav></body></html>","OEBPS/nav.xhtml",root)
        let layout=keepPages && input.pathExtension.lowercased()=="pdf" ? "pre-paginated":"reflowable"
        try write("<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\" prefix=\"rendition: http://www.idpf.org/vocab/rendition/#\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"book-id\">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(escape(input.deletingPathExtension().lastPathComponent))</dc:title><dc:language>en</dc:language><meta property=\"dcterms:modified\">\(ISO8601DateFormatter().string(from:Date()))</meta><meta property=\"rendition:layout\">\(layout)</meta></metadata><manifest>\(manifest)<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/></manifest><spine>\(spine)</spine></package>","OEBPS/content.opf",root)
        try zip(root,to:output,epub:true)
    }
}
