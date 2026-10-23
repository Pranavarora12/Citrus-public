import Foundation
import AppKit
import PDFKit
import CoreText
import ImageIO

/// Local OOXML presentation import and PDF export, without opening an Office app.
enum OfficeConversion {
    private static func fail(_ message:String)->UIError { .message(message) }
    private static func command(_ exe:String,_ args:[String],cwd:URL?=nil)throws->Data {
        let p=Process();p.executableURL=URL(fileURLWithPath:exe);p.arguments=args;p.currentDirectoryURL=cwd
        let out=Pipe(),err=Pipe();p.standardOutput=out;p.standardError=err;try p.run()
        let data=out.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        guard p.terminationStatus==0 else{throw fail(String(data:err.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? "Office package could not be read.")};return data
    }
    private static func member(_ input:URL,_ path:String)throws->Data {try command("/usr/bin/unzip",["-p",input.path,path])}
    private static func xml(_ data:Data)throws->XMLDocument {try XMLDocument(data:data,options:[.nodeLoadExternalEntitiesNever])}
    private static func nodes(_ node:XMLNode,_ path:String)->[XMLNode] {(try? node.nodes(forXPath:path)) ?? []}
    private static func attr(_ node:XMLNode?,_ name:String)->String? {
        guard let element=node as? XMLElement else{return nil}
        return element.attribute(forName:name)?.stringValue ?? element.attributes?.first(where:{$0.localName==name})?.stringValue
    }
    private static func num(_ node:XMLNode?,_ name:String,_ fallback:CGFloat=0)->CGFloat {CGFloat(Double(attr(node,name) ?? "") ?? Double(fallback))}
    private static func relations(_ input:URL,_ part:String)->[String:String] {
        let url=URL(fileURLWithPath:"/"+part),path=url.deletingLastPathComponent().appendingPathComponent("_rels").appendingPathComponent(url.lastPathComponent+".rels").path.dropFirst()
        guard let data=try? member(input,String(path)),let document=try? xml(data) else{return [:]}
        var result:[String:String]=[:]
        for rel in nodes(document,"//*[local-name()='Relationship']") where attr(rel,"TargetMode") != "External" {
            guard let id=attr(rel,"Id"),let target=attr(rel,"Target") else{continue}
            let resolved=target.hasPrefix("/") ? target:URL(fileURLWithPath:"/"+part).deletingLastPathComponent().appendingPathComponent(target).standardized.path
            result[id]=String(resolved.drop(while:{$0=="/"}))
        };return result
    }
    private struct Presentation {let size:CGSize;let slides:[String]}
    private static func presentation(_ input:URL)throws->Presentation {
        guard input.pathExtension.lowercased()=="pptx" else{throw fail("A genuine legacy PPT needs a legacy PowerPoint importer; use PPTX for this converter.")}
        let doc=try xml(member(input,"ppt/presentation.xml")),rels=relations(input,"ppt/presentation.xml")
        let dimension=nodes(doc,"//*[local-name()='sldSz']").first
        let size=CGSize(width:num(dimension,"cx",9_144_000)/12700,height:num(dimension,"cy",6_858_000)/12700)
        let slides=nodes(doc,"//*[local-name()='sldId']").compactMap{attr($0,"r:id").flatMap{rels[$0]}}
        guard !slides.isEmpty,size.width>0,size.height>0,size.width<20000,size.height<20000 else{throw fail("Presentation has no readable slides or has invalid page dimensions.")}
        return Presentation(size:size,slides:slides)
    }
    static func presentationText(_ input:URL)throws->String {
        let deck=try presentation(input)
        return try deck.slides.map{part in
            let doc=try xml(member(input,part))
            return nodes(doc,"//*[local-name()='sp']//*[local-name()='p']").map{p in nodes(p,".//*[local-name()='t']").compactMap(\.stringValue).joined()}.joined(separator:"\n")
        }.joined(separator:"\n\n")
    }
    private static let theme:[String:String]=["dk1":"000000","lt1":"FFFFFF","dk2":"44546A","lt2":"E7E6E6","accent1":"4472C4","accent2":"ED7D31","accent3":"A5A5A5","accent4":"FFC000","accent5":"5B9BD5","accent6":"70AD47","tx1":"000000","tx2":"44546A","bg1":"FFFFFF","bg2":"E7E6E6"]
    private static func color(_ node:XMLNode?,fallback:NSColor = .black)->NSColor {
        guard let node=node else{return fallback}
        let hex=nodes(node,".//*[local-name()='srgbClr']").first.flatMap{attr($0,"val")}
            ?? nodes(node,".//*[local-name()='schemeClr']").first.flatMap{attr($0,"val")}.flatMap{theme[$0]}
            ?? nodes(node,".//*[local-name()='sysClr']").first.flatMap{attr($0,"lastClr")}
        guard let hex=hex,let value=UInt32(hex,radix:16) else{return fallback}
        let opacity=nodes(node,".//*[local-name()='alpha']").first.map{num($0,"val",100000)/100000} ?? 1
        return NSColor(srgbRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:opacity)
    }
    private struct Mapping {var x:CGFloat=0;var y:CGFloat=0;var sx:CGFloat=1;var sy:CGFloat=1}
    private static func rect(_ transform:XMLNode?,_ map:Mapping)->CGRect? {
        guard let transform=transform,let off=nodes(transform,"./*[local-name()='off']").first,let ext=nodes(transform,"./*[local-name()='ext']").first else{return nil}
        return CGRect(x:map.x+num(off,"x")/12700*map.sx,y:map.y+num(off,"y")/12700*map.sy,width:num(ext,"cx")/12700*map.sx,height:num(ext,"cy")/12700*map.sy)
    }
    private static func placeholder(_ shape:XMLNode)->String {nodes(shape,".//*[local-name()='ph']").first.flatMap{attr($0,"type")} ?? "body"}
    private static func text(_ shape:XMLNode,defaultSize:CGFloat)->NSAttributedString {
        let result=NSMutableAttributedString(string:"")
        for paragraph in nodes(shape,"./*[local-name()='txBody']/*[local-name()='p']") {
            let style=NSMutableParagraphStyle();style.lineBreakMode = .byWordWrapping
            let properties=nodes(paragraph,"./*[local-name()='pPr']").first
            switch attr(properties,"algn") {case "ctr":style.alignment = .center;case "r":style.alignment = .right;case "just":style.alignment = .justified;default:style.alignment = .left}
            let defaults=properties.flatMap{nodes($0,"./*[local-name()='defRPr']").first}
            if !nodes(paragraph,"./*[local-name()='pPr']/*[local-name()='buChar']").isEmpty {result.append(NSAttributedString(string:"• ",attributes:[.font:NSFont.systemFont(ofSize:defaultSize)]))}
            for run in paragraph.children ?? [] {
                if run.localName=="br" {result.append(NSAttributedString(string:"\n"));continue}
                guard ["r","fld"].contains(run.localName ?? "") else{continue}
                let properties=nodes(run,"./*[local-name()='rPr']").first ?? defaults
                let size=max(5,min(200,num(properties,"sz",defaultSize*100)/100))
                let typeface=properties.flatMap{nodes($0,"./*[local-name()='latin']").first}.flatMap{attr($0,"typeface")} ?? "Arial"
                var font=NSFont(name:typeface,size:size) ?? NSFont.systemFont(ofSize:size)
                if attr(properties,"b")=="1" {font=NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask)}
                if attr(properties,"i")=="1" {font=NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask)}
                let body=nodes(run,"./*[local-name()='t']").compactMap(\.stringValue).joined()
                result.append(NSAttributedString(string:body,attributes:[.font:font,.foregroundColor:color(properties),.paragraphStyle:style]))
            }
            result.append(NSAttributedString(string:"\n",attributes:[.font:NSFont.systemFont(ofSize:defaultSize),.paragraphStyle:style]))
        };return result
    }
    private static func drawText(_ value:NSAttributedString,in box:CGRect,context:CGContext) {
        guard value.length>0,box.width>0,box.height>0 else{return}
        let adjusted=NSMutableAttributedString(attributedString:value)
        var setter=CTFramesetterCreateWithAttributedString(adjusted)
        for _ in 0..<12 {
            let range=CTFrameGetVisibleStringRange(CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:box,transform:nil),nil))
            if range.length>=adjusted.length {break}
            adjusted.enumerateAttribute(.font,in:NSRange(location:0,length:adjusted.length)){font,range,_ in
                if let font=font as? NSFont {adjusted.addAttribute(.font,value:NSFont(descriptor:font.fontDescriptor,size:max(5,font.pointSize*0.9)) ?? font,range:range)}
            }
            setter=CTFramesetterCreateWithAttributedString(adjusted)
        }
        context.saveGState();context.textMatrix = .identity
        CTFrameDraw(CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:box,transform:nil),nil),context)
        context.restoreGState()
    }
    private static func render(_ container:XMLNode,input:URL,rels:[String:String],size:CGSize,map:Mapping,context:CGContext)throws {
        for shape in container.children ?? [] {
            if shape.localName=="grpSp" {
                let transform=nodes(shape,"./*[local-name()='grpSpPr']/*[local-name()='xfrm']").first
                if let box=rect(transform,map),let transform=transform {
                    let off=nodes(transform,"./*[local-name()='chOff']").first,ext=nodes(transform,"./*[local-name()='chExt']").first
                    let sx=box.width/max(0.001,num(ext,"cx")/12700),sy=box.height/max(0.001,num(ext,"cy")/12700)
                    try render(shape,input:input,rels:rels,size:size,map:Mapping(x:box.minX-num(off,"x")/12700*sx,y:box.minY-num(off,"y")/12700*sy,sx:sx,sy:sy),context:context)
                };continue
            }
            guard ["sp","pic"].contains(shape.localName ?? "") else{continue}
            let transform=nodes(shape,"./*[local-name()='spPr']/*[local-name()='xfrm']").first
            let isTitle=["title","ctrTitle"].contains(placeholder(shape))
            let top=rect(transform,map) ?? CGRect(x:size.width*0.06,y:size.height*(isTitle ? 0.05:0.23),width:size.width*0.88,height:size.height*(isTitle ? 0.16:0.68))
            let box=CGRect(x:top.minX,y:size.height-top.maxY,width:top.width,height:top.height)
            if shape.localName=="pic" {
                guard let embed=nodes(shape,".//*[local-name()='blip']").first.flatMap({attr($0,"embed")}),let part=rels[embed],let data=try? member(input,part),let source=CGImageSourceCreateWithData(data as CFData,nil),var image=CGImageSourceCreateImageAtIndex(source,0,nil) else{continue}
                if let crop=nodes(shape,".//*[local-name()='srcRect']").first {
                    let w=CGFloat(image.width),h=CGFloat(image.height),l=num(crop,"l")/100000,t=num(crop,"t")/100000,r=num(crop,"r")/100000,b=num(crop,"b")/100000
                    if let clipped=image.cropping(to:CGRect(x:w*l,y:h*t,width:w*(1-l-r),height:h*(1-t-b))) {image=clipped}
                };context.draw(image,in:box);continue
            }
            if let fill=nodes(shape,"./*[local-name()='spPr']/*[local-name()='solidFill']").first {context.setFillColor(color(fill).cgColor);context.fill(box)}
            if let line=nodes(shape,"./*[local-name()='spPr']/*[local-name()='ln']").first,!nodes(line,"./*[local-name()='solidFill']").isEmpty {context.setStrokeColor(color(line).cgColor);context.setLineWidth(max(0.25,num(line,"w",12700)/12700));context.stroke(box)}
            let body=nodes(shape,"./*[local-name()='txBody']/*[local-name()='bodyPr']").first
            let inset=CGRect(x:box.minX+num(body,"lIns",91440)/12700,y:box.minY+num(body,"bIns",45720)/12700,width:box.width-(num(body,"lIns",91440)+num(body,"rIns",91440))/12700,height:box.height-(num(body,"tIns",45720)+num(body,"bIns",45720))/12700)
            drawText(text(shape,defaultSize:isTitle ? 30:18),in:inset,context:context)
        }
    }
    static func presentationPDF(_ input:URL,to output:URL)throws {
        let deck=try presentation(input);var bounds=CGRect(origin:.zero,size:deck.size)
        guard let context=CGContext(output as CFURL,mediaBox:&bounds,nil) else{throw fail("Cannot create presentation PDF.")}
        for part in deck.slides {
            let doc=try xml(member(input,part));context.beginPDFPage(nil)
            let bg=nodes(doc,"//*[local-name()='bgPr']/*[local-name()='solidFill']").first
            context.setFillColor(color(bg,fallback:.white).cgColor);context.fill(bounds)
            if let tree=nodes(doc,"//*[local-name()='spTree']").first {try render(tree,input:input,rels:relations(input,part),size:deck.size,map:Mapping(),context:context)}
            context.endPDFPage()
        };context.closePDF()
        guard let pdf=PDFDocument(url:output),pdf.pageCount==deck.slides.count else{throw fail("Presentation rendering lost slides.")}
    }
    static func pdfRows(_ input:URL)throws->[[String]] {
        guard let pdf=PDFDocument(url:input),!pdf.isLocked,pdf.pageCount>0 else{throw fail("Cannot read source PDF.")}
        return (0..<pdf.pageCount).flatMap{index->[[String]] in
            let lines=pdf.page(at:index)?.string?.components(separatedBy:.newlines) ?? []
            return lines.filter{!$0.trimmingCharacters(in:.whitespaces).isEmpty}.map{line in
                line.replacingOccurrences(of:"[ \\t]{2,}|\\t",with:"\t",options:.regularExpression).components(separatedBy:"\t")
            }
        }
    }
    private static func escape(_ s:String)->String {s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
    static func pdfPresentation(_ input:URL,to output:URL)throws {
        guard let pdf=PDFDocument(url:input),!pdf.isLocked,pdf.pageCount>0 else{throw fail("Cannot read source PDF.")}
        let stage=FileManager.default.temporaryDirectory.appendingPathComponent("citrus-pptx-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:stage)}
        let checkout=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/PowerPointBlank.pptx")
        let candidates=[Bundle.main.resourceURL?.appendingPathComponent("PowerPointBlank.pptx"),checkout].compactMap{$0}
        guard let template=candidates.first(where:{FileManager.default.fileExists(atPath:$0.path)}) else{throw fail("The blank PowerPoint export document is missing. Rebuild Citrus with its Resources folder.")}
        _=try command("/usr/bin/unzip",["-q",template.path,"-d",stage.path])
        func write(_ value:String,_ path:String)throws {let url=stage.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(value.utf8).write(to:url)}
        let size=pdf.page(at:0)!.bounds(for:.mediaBox).size,cx=Int(size.width*12700),cy=Int(size.height*12700)
        for index in 0..<pdf.pageCount {
            let n=index+1,page=pdf.page(at:index)!,bounds=page.bounds(for:.mediaBox),image=page.thumbnail(of:NSSize(width:bounds.width*2,height:bounds.height*2),for:.mediaBox)
            guard let data=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data),let png=bitmap.representation(using:.png,properties:[:]) else{throw fail("Cannot render source PDF page.")}
            let media=stage.appendingPathComponent("ppt/media/page\(n).png");try FileManager.default.createDirectory(at:media.deletingLastPathComponent(),withIntermediateDirectories:true);try png.write(to:media)
            let label=escape(page.string ?? "Page \(n)")
            try write("<p:sld xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Page \(n)\" descr=\"\(label)\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId1\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>","ppt/slides/slide\(n).xml")
            try write("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/page\(n).png\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout7.xml\"/></Relationships>","ppt/slides/_rels/slide\(n).xml.rels")
        }
        let document=try xml(Data(contentsOf:stage.appendingPathComponent("ppt/presentation.xml")))
        guard let root=document.rootElement() else{throw fail("PowerPoint export baseline has no presentation.")}
        let slideList=(nodes(document,"//*[local-name()='sldIdLst']").first as? XMLElement) ?? XMLElement(name:"p:sldIdLst")
        if slideList.parent==nil {root.insertChild(slideList,at:root.children?.firstIndex(where:{$0.localName=="sldSz"}) ?? 0)}
        slideList.setChildren([])
        let relationships=try xml(Data(contentsOf:stage.appendingPathComponent("ppt/_rels/presentation.xml.rels")))
        let types=try xml(Data(contentsOf:stage.appendingPathComponent("[Content_Types].xml")))
        for n in 1...pdf.pageCount {
            let slide=try XMLElement(xmlString:"<p:sldId xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" id=\"\(255+n)\" r:id=\"rIdCitrus\(n)\"/>")
            slideList.addChild(slide)
            relationships.rootElement()?.addChild(try XMLElement(xmlString:"<Relationship xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\" Id=\"rIdCitrus\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(n).xml\"/>"))
            types.rootElement()?.addChild(try XMLElement(xmlString:"<Override xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\" PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"))
        }
        if let dimensions=nodes(document,"//*[local-name()='sldSz']").first as? XMLElement {dimensions.attribute(forName:"cx")?.stringValue=String(cx);dimensions.attribute(forName:"cy")?.stringValue=String(cy);dimensions.attribute(forName:"type")?.stringValue="custom"}
        if nodes(types,"//*[local-name()='Default'][@Extension='png']").isEmpty {types.rootElement()?.addChild(try XMLElement(xmlString:"<Default xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\" Extension=\"png\" ContentType=\"image/png\"/>"))}
        try document.xmlData.write(to:stage.appendingPathComponent("ppt/presentation.xml"))
        try relationships.xmlData.write(to:stage.appendingPathComponent("ppt/_rels/presentation.xml.rels"))
        try types.xmlData.write(to:stage.appendingPathComponent("[Content_Types].xml"))
        _=try command("/usr/bin/zip",["-q","-r",output.path,"."],cwd:stage)
    }
}
