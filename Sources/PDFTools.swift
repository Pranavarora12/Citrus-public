import AppKit
import PDFKit
import Vision
import CoreImage
import CoreVideo

struct PDFMetadataField: Identifiable {
    let id: String
    let label: String
    var value: String
}

enum PDFTools {
    static func readMetadata(_ url:URL) throws -> [PDFMetadataField] {
        let document=try readable(url)
        let labels=["Title":"Title","Author":"Author","Subject":"Subject","Keywords":"Keywords","Creator":"Creator","Producer":"Producer","CreationDate":"Created","ModDate":"Modified"]
        return (document.documentAttributes ?? [:]).compactMap { key,value in
            let id=String(describing:key)
            let string:String
            if let date=value as? Date {string=ISO8601DateFormatter().string(from:date)}
            else if let array=value as? [String] {string=array.joined(separator:", ")}
            else if let value=value as? String {string=value}
            else{return nil}
            guard !string.isEmpty else{return nil}
            return PDFMetadataField(id:id,label:labels[id] ?? id,value:string)
        }.sorted{$0.label.localizedStandardCompare($1.label) == .orderedAscending}
    }

    static func saveMetadata(_ url:URL,fields:[PDFMetadataField],outputDirectory:URL) throws -> URL {
        let source=try readable(url)
        // A fresh catalog also drops embedded XMP, which clearing only the Info
        // dictionary on the source PDF can otherwise leave behind.
        let result=PDFDocument()
        for i in 0..<source.pageCount {
            guard let page=source.page(at:i)?.copy() as? PDFPage else{throw UIError.message("Cannot read PDF page \(i+1).")}
            result.insert(page,at:result.pageCount)
        }
        var attributes:[AnyHashable:Any]=[:]
        for field in fields where !field.value.isEmpty {
            if ["CreationDate","ModDate"].contains(field.id) {
                guard let date=ISO8601DateFormatter().date(from:field.value) else{throw UIError.message("Enter \(field.label.lowercased()) as an ISO date, for example 2026-10-21T12:00:00Z.")}
                attributes[field.id]=date
            } else if field.id == "Keywords" {
                attributes[field.id]=field.value.components(separatedBy:",").map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}
            } else {attributes[field.id]=field.value}
        }
        result.documentAttributes=attributes
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        let output=unique(url.deletingPathExtension().lastPathComponent+"-metadata",extension:"pdf",in:outputDirectory)
        guard result.write(to:output),let verify=PDFDocument(url:output),verify.pageCount==source.pageCount else{
            try? FileManager.default.removeItem(at:output)
            throw UIError.message("Could not save PDF metadata.")
        }
        return output
    }

    static func qrPayloads(_ url:URL) throws -> [String] {
        let document=try readable(url)
        var payloads:[String]=[]
        // Scan every page, including PDFs containing only scanned images.
        for index in 0..<document.pageCount {
            guard let page=document.page(at:index) else{continue}
            let bounds=page.bounds(for:.cropBox)
            let ratio=min(3,2200/max(bounds.width,bounds.height))
            let size=NSSize(width:max(1,bounds.width*ratio),height:max(1,bounds.height*ratio))
            let thumbnail=page.thumbnail(of:size,for:.cropBox)
            guard let image=thumbnail.cgImage(forProposedRect:nil,context:nil,hints:nil) else{continue}
            let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
            var detected:[String]=[]
            if (try? VNImageRequestHandler(cgImage:image).perform([request])) != nil {
                detected=(request.results ?? []).compactMap(\.payloadStringValue)
            }
            if detected.isEmpty {
                // Older CPU detection consumes a normal memory-backed pixel
                // buffer. It does not depend on ANE models or IOSurface-backed
                // conversion, which may be unavailable on some hosts.
                detected=try cpuQRPayloads(image)
            }
            for value in detected where !payloads.contains(value){payloads.append(value)}
        }
        guard !payloads.isEmpty else{throw UIError.message("No readable QR code found in \(url.lastPathComponent).")}
        return payloads
    }

    private static func cpuQRPayloads(_ image:CGImage)throws->[String] {
        let width=image.width,height=image.height
        var result:CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,nil,&result)==kCVReturnSuccess,let buffer=result else{
            throw UIError.message("The QR detector could not allocate its page buffer.")
        }
        CVPixelBufferLockBaseAddress(buffer,[])
        defer{CVPixelBufferUnlockBaseAddress(buffer,[])}
        guard let y=CVPixelBufferGetBaseAddressOfPlane(buffer,0),let uv=CVPixelBufferGetBaseAddressOfPlane(buffer,1) else{throw UIError.message("The QR detector could not read its page buffer.")}
        let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
        guard let gray=CGContext(data:y,width:width,height:height,bitsPerComponent:8,bytesPerRow:stride,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else{throw UIError.message("Could not render the PDF page for QR detection.")}
        gray.setFillColor(CGColor(gray:1,alpha:1));gray.fill(CGRect(x:0,y:0,width:width,height:height))
        gray.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        memset(uv,128,CVPixelBufferGetBytesPerRowOfPlane(buffer,1)*CVPixelBufferGetHeightOfPlane(buffer,1))
        func detect()throws->[String] {
            let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
            request.revision=1
            request.usesCPUOnly=true
            try VNImageRequestHandler(cvPixelBuffer:buffer).perform([request])
            return (request.results ?? []).compactMap(\.payloadStringValue)
        }
        let first=try detect()
        if !first.isEmpty{return first}
        // Thin antialiased seams between adjacent vector QR modules can prevent
        // recognition. A second pass closes these light seams in the raster.
        let bytes=y.assumingMemoryBound(to:UInt8.self)
        for row in 0..<height {for column in 0..<width {
            let offset=row*stride+column
            bytes[offset]=bytes[offset]<204 ? 0:255
        }}
        return try detect()
    }

    static func webURL(_ text:String)->URL? {
        guard let url=URL(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),["http","https"].contains(url.scheme?.lowercased() ?? ""),url.host?.isEmpty==false else{return nil}
        return url
    }

    static func readable(_ url:URL)throws->PDFDocument {
        return try FolderAccessStore.withAccess([],for:[url]) {
            guard url.isFileURL else{throw UIError.message("Choose a local PDF file.")}
            let pathURL=(url as NSURL).filePathURL ?? url
            let data:Data
            do {data=try Data(contentsOf:pathURL,options:.mappedIfSafe)}
            catch {
                let underlying=error as NSError
                if underlying.domain==NSCocoaErrorDomain && underlying.code==NSFileReadNoPermissionError {
                    throw UIError.message("Citrus cannot access \(pathURL.lastPathComponent). Choose its folder in Settings → Folders, then try again.")
                }
                throw UIError.message("Could not open \(pathURL.lastPathComponent): \(error.localizedDescription)")
            }
            guard !data.isEmpty,let document=PDFDocument(data:data) else{throw UIError.message("\(pathURL.lastPathComponent) is empty or is not a readable PDF.")}
            guard !document.isLocked else{throw UIError.message("\(pathURL.lastPathComponent) is password protected. Unlock it before using this tool.")}
            guard document.pageCount>0 else{throw UIError.message("\(pathURL.lastPathComponent) contains no readable PDF pages.")}
            return document
        }
    }

    static func unique(_ stem:String,extension ext:String,in directory:URL)->URL {
        var number=1
        var target=directory.appendingPathComponent(stem+(ext.isEmpty ? "":"."+ext))
        while FileManager.default.fileExists(atPath:target.path) {
            number+=1;target=directory.appendingPathComponent(stem+" \(number)"+(ext.isEmpty ? "":"."+ext))
        }
        return target
    }
}
