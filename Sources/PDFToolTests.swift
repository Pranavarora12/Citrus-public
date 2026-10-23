import Foundation
import AppKit
import PDFKit
import CryptoKit

enum PDFToolTests {
    @discardableResult static func run(in directory:URL,reference:URL?=nil)throws->Int {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var checks=0
        func check(_ condition:Bool,_ label:String)throws {guard condition else{throw UIError.message("PDF tool audit: "+label)};checks+=1;print("PASS "+label)}
        let input=directory.appendingPathComponent("PDF tool fixture.pdf")
        try fixture(to:input)
        let original=try Data(contentsOf:input)
        let source=try PDFTools.readable(input)
        var editorLoad:Result<Bool,Error>?
        Task { @MainActor in
            let state=PDFOrganizerState()
            state.load(input)
            for _ in 0..<300 {
                if !state.loading && (state.thumbnails.count==3 || !state.message.isEmpty){break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            editorLoad = .success(state.pages.count==3 && state.thumbnails.count==3 && state.message.isEmpty)
            state.cancel()
        }
        let loadDeadline=Date().addingTimeInterval(10)
        while editorLoad==nil && Date()<loadDeadline {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.02))}
        try check(try editorLoad?.get()==true,"Live organizer loading fills its page list and thumbnails without preview seeding")
        let missing=directory.appendingPathComponent("missing-source.pdf")
        do {_ = try PDFTools.readable(missing);throw UIError.message("Missing file accepted")}
        catch {try check(error.localizedDescription.contains("missing-source.pdf") && !error.localizedDescription.contains("password protected"),"Missing PDF reports its real file-open error")}
        let invalid=directory.appendingPathComponent("invalid.pdf")
        try Data("This is not a PDF".utf8).write(to:invalid)
        do {_ = try PDFTools.readable(invalid);throw UIError.message("Invalid PDF accepted")}
        catch {try check(error.localizedDescription.contains("not a readable PDF"),"Invalid PDF is distinguished from file-access failures")}
        let outputs=directory.appendingPathComponent("outputs",isDirectory:true)
        try FileManager.default.createDirectory(at:outputs,withIntermediateDirectories:true)

        let folders=try ProcessingJob.run("splitPDF",inputs:[input],outputDirectory:outputs,options:[:])
        let folder=folders[0]
        let pages=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).sorted{$0.lastPathComponent<$1.lastPathComponent}
        try check(folders.count==1 && folder.lastPathComponent=="PDF tool fixture Pages" && pages.map(\.lastPathComponent)==["Page 1.pdf","Page 2.pdf","Page 3.pdf"],"Split creates the named Pages folder and Page N.pdf files")
        try check(pages.allSatisfy{PDFDocument(url:$0)?.pageCount==1},"Split exports one readable PDF page per original page")
        try check(PDFDocument(url:pages[0])?.string?.contains("FIRST PAGE") == true && PDFDocument(url:pages[2])?.string?.contains("LAST PAGE") == true,"Split preserves page content and order")
        let secondFolder=try ProcessingJob.run("splitPDF",inputs:[input],outputDirectory:outputs,options:[:])[0]
        try check(folder != secondFolder && FileManager.default.fileExists(atPath:folder.path),"Repeated Split preserves earlier output folders")

        let order=["order":"3,1,2","rotations":"90,0,180"]
        let organized=try ProcessingJob.run("organizePDF",inputs:[input],outputDirectory:outputs,options:order)[0]
        let organizedDoc=try PDFTools.readable(organized)
        try check(organizedDoc.pageCount==3 && organizedDoc.page(at:0)?.string?.contains("LAST PAGE")==true && organizedDoc.page(at:1)?.string?.contains("FIRST PAGE")==true,"Organize saves the selected order with every page retained")
        try check(organizedDoc.page(at:0)?.rotation==90 && organizedDoc.page(at:2)?.rotation==180,"Organize saves independent clockwise rotations")
        var equal=order;equal["equalWidths"]="true"
        let equalURL=try ProcessingJob.run("organizePDF",inputs:[input],outputDirectory:outputs,options:equal)[0]
        let equalDoc=try PDFTools.readable(equalURL)
        let widths=(0..<equalDoc.pageCount).map{equalDoc.page(at:$0)!.bounds(for:.mediaBox).width}
        try check(widths.allSatisfy{abs($0-300)<0.1},"Equal widths uses the narrowest page after chosen rotations")
        let firstBounds=equalDoc.page(at:0)!.bounds(for:.mediaBox)
        try check(abs(firstBounds.height-200)<0.1 && equalDoc.page(at:0)?.rotation==0,"Equal widths preserves rotated page proportions and bakes orientation")
        do {_ = try ProcessingJob.run("organizePDF",inputs:[input],outputDirectory:outputs,options:["order":"1,1,2"]);throw UIError.message("Invalid page order accepted")}catch is DocumentEngine.Failure {try check(true,"Organize rejects duplicate or missing pages")}

        let metadata=try PDFTools.readMetadata(input)
        try check(metadata.contains{$0.id=="Creator" && $0.value=="Citrus PDF audit"},"Metadata reads the original Creator field")
        var fields=metadata.filter{!["Author","CreationDate","ModDate"].contains($0.id)}
        if let index=fields.firstIndex(where:{$0.id=="Creator"}){fields[index].value="Edited creator"}
        let edited=try PDFTools.saveMetadata(input,fields:fields,outputDirectory:outputs)
        let editedFields=try PDFTools.readMetadata(edited)
        try check(editedFields.contains{$0.id=="Creator" && $0.value=="Edited creator"} && !editedFields.contains{$0.id=="Author"},"Metadata saves edited values and removes selected fields")
        let clean=try PDFTools.saveMetadata(input,fields:[],outputDirectory:outputs)
        let cleanFields=try PDFTools.readMetadata(clean)
        try check(!cleanFields.contains{["Author","Creator","Title","Subject","Keywords"].contains($0.id)},"Remove All clears source document metadata")
        try check(PDFDocument(url:clean)?.pageCount==source.pageCount && PDFDocument(url:clean)?.string?.contains("FIRST PAGE")==true,"Metadata saving preserves PDF pages and selectable text")

        let payloads=try PDFTools.qrPayloads(input)
        try check(payloads==["https://example.com/citrus-pdf-qr"],"Read QR finds the link on a later PDF page")
        try check(PDFTools.webURL("https://example.com/citrus-pdf-qr") != nil && PDFTools.webURL("file:///etc/passwd")==nil && PDFTools.webURL("plain QR text")==nil,"QR opens web links and treats other payloads as text")
        do {_ = try PDFTools.qrPayloads(pages[0]);throw UIError.message("QR-free document accepted")}catch {try check(error.localizedDescription.contains("No readable QR code"),"Read QR reports when a PDF has no readable QR")}

        let model=AppModel();model.feedbackEnabled=false
        var requested:[String]=[],destinationCorrect=true
        model.pdfToolPresenter={operation,urls,destination in requested.append(operation);destinationCorrect = destinationCorrect && urls == [input] && destination == outputs}
        for operation in ["compress","removeMetadata","organizePDF"] {
            model.submitWheelDrop(Tool.all.first{$0.id==operation}!,urls:[input],destination:outputs)
        }
        try check(requested==["compress","removeMetadata","organizePDF"] && destinationCorrect && model.pendingJobs==0,"PDF wheel opens the three editors instead of executing stale options")
        var opened:[URL]=[],finished:Result<[URL],Error>?
        model.openQRURL={opened.append($0);return true}
        model.showQRText={_ in}
        model.onJobFinished={finished=$0}
        model.submitWheelDrop(Tool.all.first{$0.id=="readQRCode"}!,urls:[input],destination:outputs)
        let deadline=Date().addingTimeInterval(30)
        while finished==nil && Date()<deadline {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.02))}
        try check(try finished?.get()==[URL(string:"https://example.com/citrus-pdf-qr")!] && opened.count==1 && model.results.isEmpty,"PDF wheel QR action invokes the browser opener without a saved-item popup")
        let wheel=WheelDropView(group:"Tools",inputs:[input],onDrop:{_,_ in},onClose:{})
        try check(wheel.current.map(\.id)==["compress","removeMetadata","splitPDF","organizePDF","readQRCode"] && wheel.pageCount==1,"PDF Command wheel exposes all five requested actions")
        for index in wheel.current.indices {let rect=wheel.slotRect(index);try check(wheel.slot(at:NSPoint(x:rect.midX,y:rect.midY))==index,"PDF Command wheel target \(index+1) accepts a drop")}

        try check(try PDFCompression.targetBytes(original:1000,options:["pdfCompressionMode":"percentage","pdfReduction":"50"])==500,"Percentage compression calculates the requested byte limit")
        try check(try PDFCompression.targetBytes(original:1000,options:["pdfCompressionMode":"fileSize","pdfTargetSize":"0.5","pdfTargetUnit":"MB"])==500000,"File Size compression uses the selected size and units")
        do {_ = try PDFCompression.targetBytes(original:1000,options:["pdfCompressionMode":"fileSize","pdfTargetSize":"-1"]);throw UIError.message("Invalid size accepted")}catch {try check(!error.localizedDescription.contains("Invalid size accepted"),"Compression rejects invalid size limits")}

        if let reference {
            let bytes=try Data(contentsOf:reference)
            let originalPDF=try PDFTools.readable(reference)
            for preset in ["small","balanced","high"] {
                let result=try PDFCompression.run(input:reference,outputDirectory:outputs,options:["pdfCompressionMode":"preset","pdfCompressionPreset":preset])
                let count=try result.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                try check(count>0 && count<bytes.count && PDFDocument(url:result)?.pageCount==originalPDF.pageCount,"\(preset) compression preset produces a smaller PDF with every page")
            }
            for options in [["pdfCompressionMode":"percentage","pdfReduction":"50"],["pdfCompressionMode":"fileSize","pdfTargetSize":"221","pdfTargetUnit":"KB"]] {
                let result=try PDFCompression.run(input:reference,outputDirectory:outputs,options:options)
                let count=try result.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                let target=try PDFCompression.targetBytes(original:bytes.count,options:options)!
                try check(count>0 && count<=target && PDFDocument(url:result)?.pageCount==originalPDF.pageCount,"\(options["pdfCompressionMode"]!) compression meets its byte limit and retains all \(originalPDF.pageCount) pages")
                print("COMPRESSION \(result.path) \(count) <= \(target) bytes")
            }
            let actualFolders=try ProcessingJob.run("splitPDF",inputs:[reference],outputDirectory:outputs,options:[:])
            let actualPages=try FileManager.default.contentsOfDirectory(at:actualFolders[0],includingPropertiesForKeys:nil)
            try check(actualPages.count==originalPDF.pageCount && actualPages.allSatisfy{PDFDocument(url:$0)?.pageCount==1},"Reference PDF Split exports all \(originalPDF.pageCount) single-page PDFs")
            try check(try Data(contentsOf:reference)==bytes,"Reference PDF original bytes are unchanged")
        }
        try check(try Data(contentsOf:input)==original,"All PDF Command tools preserve the input file bytes")
        print("PDF TOOL AUDIT: \(checks) checks passed. Outputs: \(directory.path)")
        return checks
    }

    private static func fixture(to url:URL)throws {
        var media=CGRect(x:0,y:0,width:400,height:300)
        guard let consumer=CGDataConsumer(url:url as CFURL),let context=CGContext(consumer:consumer,mediaBox:&media,[kCGPDFContextTitle as String:"PDF test",kCGPDFContextAuthor as String:"Original author",kCGPDFContextCreator as String:"Citrus PDF audit"] as CFDictionary) else{throw UIError.message("Cannot make PDF audit fixture")}
        func page(_ size:CGSize,_ text:String,_ qr:Bool=false) {
            var bounds=CGRect(origin:.zero,size:size)
            let data=Data(bytes:&bounds,count:MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String:data] as CFDictionary)
            context.setFillColor(NSColor.white.cgColor);context.fill(bounds)
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
            (text as NSString).draw(at:NSPoint(x:20,y:size.height-35),withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.black]);NSGraphicsContext.restoreGraphicsState()
            if qr {
                // Fixed independently encoded fixture (ReportLab QR, version 3,
                // medium EC). Drawing modules directly avoids a GPU dependency
                // when tests run outside a desktop application session.
                let modules="""
                11111110001100100001001111111
                10000010110001000111101000001
                10111010001000010010101011101
                10111010001101001010001011101
                10111010111101001001001011101
                10000010010110111001101000001
                11111110101010101010101111111
                00000000000100010100000000000
                10101010001000001100100010010
                01100100101011011110101001001
                00011110001010111000001110111
                10101001010001101110110010010
                01010110000110111101111001011
                00101100101100110110011001001
                10110111001101001110010111011
                11100000011010000111110101010
                01101011101100000111111001011
                01000101111001001000111001101
                10010111000100100000011010011
                01011001101101110110100111010
                10000111111010100101111110000
                00000000100100101111100010111
                11111110001111000011101011011
                10000010001100011100100011000
                10111010101010011100111110001
                10111010001110000100110010111
                10111010101001001000100111001
                10000010001000101101101000010
                11111110101000001101100110011
                """.split(separator:"\n")
                let cell=CGFloat(200.0/37.0)
                context.setFillColor(NSColor.black.cgColor)
                for (row,line) in modules.enumerated() {for (col,value) in line.enumerated() where value=="1" {
                    context.fill(CGRect(x:50+CGFloat(col+4)*cell,y:40+CGFloat(32-row)*cell,width:cell,height:cell))
                }}
            }
            context.endPDFPage()
        }
        page(CGSize(width:400,height:300),"FIRST PAGE")
        page(CGSize(width:300,height:300),"QR PAGE",true)
        page(CGSize(width:200,height:300),"LAST PAGE")
        context.closePDF()
    }
}
