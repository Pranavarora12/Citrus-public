import Foundation
import AppKit
import PDFKit
import ImageIO
import CryptoKit

struct SelfTests {
    static func run(requirePasteboard:Bool=false) throws {
        let fm=FileManager.default
        let dir=fm.temporaryDirectory.appendingPathComponent("citrus-tests-"+UUID().uuidString)
        try fm.createDirectory(at:dir,withIntermediateDirectories:true)
        defer{try? fm.removeItem(at:dir)}
        var count=0
        func check(_ yes:Bool,_ message:String)throws{guard yes else{throw UIError.message(message)};count+=1;print("PASS \(message)")}
        let text=dir.appendingPathComponent("hello.txt")
        try "Citrus test\nA real local document.\n".write(to:text,atomically:true,encoding:.utf8)
        let original=try Data(contentsOf:text)
        let bmp=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:320,pixelsHigh:240,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bmp);NSColor.orange.setFill();NSRect(x:0,y:0,width:320,height:240).fill();NSColor.blue.setFill();NSRect(x:30,y:30,width:80,height:80).fill();NSGraphicsContext.restoreGraphicsState()
        let image=dir.appendingPathComponent("sample.png");try bmp.representation(using:.png,properties:[:])!.write(to:image)
        let imageOriginal=try Data(contentsOf:image)
        func doc(_ op:String,_ files:[URL],_ opts:[String:String]=[:])throws->[URL]{try DocumentEngine.run(op,inputs:files,outputDirectory:dir,options:opts)}
        func media(_ op:String,_ files:[URL],_ opts:[String:String]=[:])throws->[URL]{try MediaEngine.run(op,inputs:files,outputDirectory:dir,options:opts)}
        let unavailablePages=dir.appendingPathComponent("Unavailable.pages")
        do {try PagesIO.write(text:"Sample",to:unavailablePages,pagesApplication:nil);throw UIError.message("Pages export accepted a missing application")}
        catch let error as PagesIO.Failure {try check(error.message.contains("requires Apple Pages") && !fm.fileExists(atPath:unavailablePages.path),"missing Pages reports its requirement without creating output")}
        let existingPages=dir.appendingPathComponent("Existing.pages")
        try Data("Keep original".utf8).write(to:existingPages)
        do {try PagesIO.write(text:"Replacement",to:existingPages,pagesApplication:nil);throw UIError.message("Pages export overwrote its destination")}
        catch let error as PagesIO.Failure {try check(error.message.contains("already exists") && (try? String(contentsOf:existingPages)) == "Keep original","Pages export refuses existing destinations without changing their bytes")}
        let pdf=try doc("createPDF",[text,image])[0]
        try check(PDFDocument(url:pdf)?.pageCount==2,"create PDF has text and image pages")
        let splitFolder=try doc("splitPDF",[pdf])[0]
        let split=(1...2).map{splitFolder.appendingPathComponent("Page \($0).pdf")}
        try check(splitFolder.lastPathComponent=="Combined Pages" && split.allSatisfy{PDFDocument(url:$0)?.pageCount==1},"split PDF saves every page in a named Pages folder")
        let merge=try doc("mergePDF",split)[0];try check(PDFDocument(url:merge)?.pageCount==2,"merge PDF page count")
        let organized=try doc("organizePDF",[pdf],["order":"2,1","rotations":"90,0"])[0]
        try check(PDFDocument(url:organized)?.page(at:0)?.rotation==90,"organize PDF reorders and rotates")
        let render=try doc("convert",[pdf],["format":"png"]);try check(render.count==2 && NSImage(contentsOf:render[0]) != nil,"PDF pages render as images")
        let extracted=try doc("extractText",[split[0]])[0];try check(try String(contentsOf:extracted).contains("Citrus test"),"PDF text extraction")
        let docx=try doc("convert",[text],["format":"docx"])[0];try check((try Data(contentsOf:docx)).starts(with:[0x50,0x4b]),"DOCX is a valid ZIP document container")
        let csv=dir.appendingPathComponent("table.csv");try "Name,Note\nAlice,\"a,b\"\nBob,\"two\"\"quotes\"\n".write(to:csv,atomically:true,encoding:.utf8)
        let json=try doc("convert",[csv],["format":"json"])[0];let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:json)) as! [[String:String]]
        try check(rows[0]["Note"]=="a,b" && rows[1]["Note"]=="two\"quotes","CSV quoted fields survive JSON conversion")
        let srt=dir.appendingPathComponent("subtitle.srt");try "1\n00:00:01,000 --> 00:00:02,500\nHello\n".write(to:srt,atomically:true,encoding:.utf8)
        let vtt=try doc("convert",[srt],["format":"vtt"])[0];try check(try String(contentsOf:vtt).contains("00:00:02.500"),"subtitle timing conversion")
        let zip=try doc("createArchive",[text,image],["format":"zip"])[0];let unzipped=try doc("extractArchive",[zip])[0]
        try check(fm.fileExists(atPath:unzipped.appendingPathComponent("hello.txt").path),"ZIP creation and extraction")
        let resized=try media("resizeImage",[image],["width":"160","height":"120"])[0]
        let ri=NSBitmapImageRep(data:try Data(contentsOf:resized))!
        try check(ri.pixelsWide==160 && ri.pixelsHigh==120,"image resize pixel dimensions")
        let cropped=try media("cropImage",[image],["x":"10","y":"10","width":"80","height":"60"])[0]
        let ci=NSBitmapImageRep(data:try Data(contentsOf:cropped))!;try check(ci.pixelsWide==80 && ci.pixelsHigh==60,"image crop pixel dimensions")
        for op in ["rotateImage","editImage","redactImage","frameImage","annotateImage"] {let urls=try media(op,[image],["angle":"90","x":"10","y":"10","width":"20","height":"20","text":"Test"]);try check(!urls.isEmpty && NSImage(contentsOf:urls[0]) != nil,"\(op) writes decodable image")}
        let collage=try media("createCollage",[image,image],["columns":"2"])[0];try check(NSImage(contentsOf:collage) != nil,"collage image export")
        let tone=dir.appendingPathComponent("tone.wav"),video=dir.appendingPathComponent("clip.mp4")
        try process(["-f","lavfi","-i","sine=frequency=440:duration=2",tone.path])
        try process(["-f","lavfi","-i","color=c=orange:s=160x120:r=12:d=2","-i",tone.path,"-shortest","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac",video.path])
        for (op,files,opts) in [
            ("convert",[tone],["format":"mp3"]), ("trimAudio",[tone],["start":"0.2","duration":"0.5","end":"0.7"]),
            ("normalizeAudio",[tone],[:]), ("audioChannels",[tone],["channels":"2"]), ("redactAudio",[tone],["start":"0.2","end":"0.7"]),
            ("audioToVideo",[tone],[:]), ("muteVideo",[video],[:]), ("trimVideo",[video],["start":"0.2","duration":"0.5","end":"0.7"]),
            ("cropVideo",[video],["width":"80","height":"60"]), ("changeVideoSpeed",[video],["speed":"2"]),
            ("redactVideo",[video],["width":"30","height":"30"]), ("joinVideos",[video,video],[:]),
            ("splitVideo",[video],["times":"1","duration":"1"]), ("videoSnapshots",[video],["times":"0,1","interval":"1"])
        ] {
            let out=try media(op,files,opts);try check(!out.isEmpty && out.allSatisfy{((try? $0.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>0},"\(op) produces nonempty media")
        }
        do{_ = try media("cropImage",[image],["width":"-1"]);throw UIError.message("Invalid crop was accepted")}catch is MediaEngine.Failure{try check(true,"invalid crop rejected")}
        try check(try Data(contentsOf:text)==original && Data(contentsOf:image)==imageOriginal,"processing leaves original bytes unchanged")
        // Verify that the defaults exposed in Settings change actual exported data.
        func commandText(_ executable:String,_ args:[String])throws->String {
            let task=Process();task.executableURL=URL(fileURLWithPath:executable);task.arguments=args
            let pipe=Pipe();task.standardOutput=pipe;task.standardError=pipe;try task.run()
            let data=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
            guard task.terminationStatus==0 else{throw UIError.message(String(data:data,encoding:.utf8) ?? "Test command failed")}
            return String(data:data,encoding:.utf8) ?? ""
        }
        func zipText(_ url:URL,_ member:String)throws->String{try commandText("/usr/bin/unzip",["-p",url.path,member])}
        let pageDOCX=try doc("convert",[pdf],["format":"docx","pdfLayout":"pages"])[0]
        let pageDOCXList=try commandText("/usr/bin/unzip",["-Z1",pageDOCX.path])
        try check(pageDOCXList.contains("word/media/page1.png") && pageDOCXList.contains("word/media/page2.png"),"preserved-page DOCX contains every PDF page")
        try check(try zipText(pageDOCX,"word/document.xml").contains("w:drawing"),"preserved-page DOCX references embedded page artwork")
        let pagePPTX=try doc("convert",[pdf],["format":"pptx"])[0]
        let pagePPTXList=try commandText("/usr/bin/unzip",["-Z1",pagePPTX.path])
        let pageSlideRelationships=try zipText(pagePPTX,"ppt/slides/_rels/slide1.xml.rels")
        try check(pagePPTXList.contains("ppt/media/page2.png") && pagePPTXList.contains("ppt/slideMasters/slideMaster1.xml") && pageSlideRelationships.contains("/slideLayout"),"PDF-to-PPTX preserves every page with a complete native slide layout graph")
        let reflowEPUB=try doc("convert",[text],["format":"epub","epubLayout":"reflow"])[0]
        try check(try zipText(reflowEPUB,"OEBPS/text.xhtml").contains("Citrus test") && zipText(reflowEPUB,"OEBPS/content.opf").contains("reflowable"),"reflow EPUB contains selectable source text and reflow metadata")
        let fixedEPUB=try doc("convert",[pdf],["format":"epub","epubLayout":"pages"])[0]
        try check(try zipText(fixedEPUB,"OEBPS/content.opf").contains("pre-paginated") && zipText(fixedEPUB,"OEBPS/page2.xhtml").contains("page2.png"),"fixed EPUB preserves all pages with fixed-layout metadata")
        let gzip=try doc("createArchive",[text,image],["format":"gzip","archiveCompression":"smallest"])[0]
        let gunzipped=try doc("extractArchive",[gzip])[0]
        try check(try Data(contentsOf:gunzipped.appendingPathComponent("hello.txt"))==original,"GZIP compression setting produces an extractable archive")
        let convertedTar=try doc("convertArchive",[zip],["format":"tar"])[0]
        let tarListing=try commandText("/usr/bin/tar",["-tf",convertedTar.path])
        try check(tarListing.contains("hello.txt") && !tarListing.contains("Archive.zip"),"archive conversion repackages contents rather than nesting the source")
        let metadataInput=dir.appendingPathComponent("metadata.tiff")
        let imageSource=CGImageSourceCreateWithURL(image as CFURL,nil)!
        let metadataWriter=CGImageDestinationCreateWithURL(metadataInput as CFURL,"public.tiff" as CFString,1,nil)!
        CGImageDestinationAddImageFromSource(metadataWriter,imageSource,0,[kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFArtist:"Citrus metadata test"],kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:12.5,kCGImagePropertyGPSLatitudeRef:"N"]] as CFDictionary)
        try check(CGImageDestinationFinalize(metadataWriter),"metadata fixture encodes successfully")
        let preserved=try media("convert",[metadataInput],["format":"jpg","quality":"95","preserveMetadata":"true"])[0]
        let stripped=try media("convert",[metadataInput],["format":"jpg","quality":"60","preserveMetadata":"false"])[0]
        func imageProperties(_ url:URL)->[String:Any]{let source=CGImageSourceCreateWithURL(url as CFURL,nil)!;return CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] ?? [:]}
        try check((imageProperties(preserved)[kCGImagePropertyTIFFDictionary as String] as? [String:Any])?[kCGImagePropertyTIFFArtist as String] as? String == "Citrus metadata test","preserve metadata retains the image author")
        try check(imageProperties(stripped)[kCGImagePropertyGPSDictionary as String]==nil && (imageProperties(stripped)[kCGImagePropertyTIFFDictionary as String] as? [String:Any])?[kCGImagePropertyTIFFArtist as String]==nil,"metadata-off strips GPS and author tags")
        let pcm24=try media("convert",[tone],["format":"wav","audioBitDepth":"24"])[0]
        let pcmBits=try commandText("/opt/homebrew/bin/ffprobe",["-v","error","-select_streams","a:0","-show_entries","stream=bits_per_sample","-of","csv=p=0",pcm24.path])
        try check(pcmBits.trimmingCharacters(in:.whitespacesAndNewlines)=="24","audio bit-depth setting writes 24-bit PCM")
        let smallVideo=try media("convert",[video],["format":"mp4","maxVideoHeight":"60","qualityPreset":"higher"])[0]
        let videoHeight=try commandText("/opt/homebrew/bin/ffprobe",["-v","error","-select_streams","v:0","-show_entries","stream=height","-of","csv=p=0",smallVideo.path])
        try check(videoHeight.trimmingCharacters(in:.whitespacesAndNewlines)=="60","maximum video height limits exported dimensions")
        let gif=try media("convert",[video],["format":"gif","gifFrameRate":"10","gifMaxWidth":"80"])[0]
        let gifInfo=try commandText("/opt/homebrew/bin/ffprobe",["-v","error","-select_streams","v:0","-show_entries","stream=width,r_frame_rate","-of","json",gif.path])
        let gifStream=(try JSONSerialization.jsonObject(with:Data(gifInfo.utf8)) as! [String:Any])["streams"] as! [[String:Any]]
        try check(gifStream[0]["width"] as? Int==80 && gifStream[0]["r_frame_rate"] as? String=="10/1","GIF settings control frame rate and width")
        let compressedImage=try media("compress",[image],["quality":"45","maxImageEdge":"100","width":""])[0]
        let compressedBitmap=NSBitmapImageRep(data:try Data(contentsOf:compressedImage))!
        try check(max(compressedBitmap.pixelsWide,compressedBitmap.pixelsHigh)==100,"image compression longest-edge setting constrains the output")
        let board=NSPasteboard.withUniqueName()
        defer{board.releaseGlobally()}
        let pasteboardAvailable=board.writeObjects([image as NSURL])
        if requirePasteboard && !pasteboardAvailable {throw UIError.message("Desktop pasteboard service unavailable")}
        if pasteboardAvailable {
        var received:[URL]=[];var targetID=""
        let wheel=WheelDropView(group:"Conversions",onDrop:{target,urls in targetID=target.id;received=urls},onClose:{})
        let jpgSlot=wheel.slotRect(wheel.current.firstIndex{$0.id=="jpg"}!)
        try check(wheel.receive(board,at:NSPoint(x:jpgSlot.midX,y:jpgSlot.midY)),"native wheel accepts Finder file URL drop")
        try check(targetID=="jpg" && received==[image],"native wheel maps the actual dropped slot and file")
        try check(!wheel.receive(board,at:NSPoint(x:230,y:230)),"drop on empty wheel center is rejected")
        board.clearContents();board.setPropertyList([text.path,image.path],forType:WheelDropView.legacyFiles)
        try check(WheelDropView.fileURLs(from:board)==[text,image],"legacy Finder multi-file drag preserves order")
        board.clearContents();board.setString("not a local file",forType:.string)
        try check(!wheel.receive(board,at:NSPoint(x:jpgSlot.midX,y:jpgSlot.midY)),"non-file wheel drops are rejected")
        } else {print("SKIP native pasteboard checks: service unavailable in command-line sandbox")}
        try check(AppModel.desktopDirectory.lastPathComponent=="Desktop","default destination is Desktop")
        let background=AppModel();background.feedbackEnabled=true;background.hapticsEnabled=false
        var jobResults:[Result<[URL],Error>]=[]
        background.onJobFinished={jobResults.append($0)}
        background.submitWheelDrop(Tool(id:"jpg",name:"JPG",icon:"doc",group:"Format"),urls:[image],destination:dir)
        background.submitWheelDrop(Tool(id:"png",name:"PNG",icon:"doc",group:"Format"),urls:[image],destination:dir)
        let deadline=Date().addingTimeInterval(30)
        while jobResults.count<2 && Date()<deadline {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05))}
        try check(jobResults.count==2,"consecutive wheel drops both finish without being discarded")
        var exports:[URL]=[]
        for result in jobResults {exports += try result.get()}
        try check(exports.map(\.pathExtension)==["jpg","png"] && exports.allSatisfy{$0.deletingLastPathComponent().path==dir.path},"wheel drops run selected conversion directly in requested output folder")
        try check(background.mainWindow==nil && !background.busy,"background wheel processing needs no main window")
        try check(background.feedbackPanel==nil,"successful wheel exports create no progress or completion popup")
        var imageSet:[URL]=[]
        for index in 0..<10 {
            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:120+index*10,pixelsHigh:80,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
            NSColor(srgbRed:CGFloat(index)/10,green:0.4,blue:0.8,alpha:1).setFill();NSRect(x:0,y:0,width:120+index*10,height:80).fill();NSGraphicsContext.restoreGraphicsState()
            let jpeg=index%2==1,url=dir.appendingPathComponent("batch-\(index)."+(jpeg ? "jpg":"png"))
            try bitmap.representation(using:jpeg ? .jpeg:.png,properties:[:])!.write(to:url);imageSet.append(url)
        }
        let batchOriginals=try imageSet.map{try Data(contentsOf:$0)}
        background.submitWheelDrop(Tool(id:"pdf",name:"PDF",icon:"doc",group:"Format"),urls:imageSet,destination:dir)
        let batchDeadline=Date().addingTimeInterval(30)
        while jobResults.count<3 && Date()<batchDeadline {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05))}
        guard jobResults.count==3 else{throw UIError.message("Multi-image PDF wheel job did not complete")}
        let batchOutputs=try jobResults[2].get()
        let batchPDF=batchOutputs.first.flatMap{PDFDocument(url:$0)}
        try check(batchOutputs.count==1 && batchPDF?.pageCount==10,"Shift PDF combines ten mixed-format images into one ten-page PDF")
        try check((0..<10).allSatisfy{index in guard let bounds=batchPDF?.page(at:index)?.bounds(for:.mediaBox) else{return false};return abs(bounds.width/bounds.height-CGFloat(120+index*10)/80)<0.01},"combined image PDF preserves every image and its input order")
        try check(try imageSet.enumerated().allSatisfy{try Data(contentsOf:$0.element)==batchOriginals[$0.offset]},"combined PDF leaves all original image bytes unchanged")
        let imageTools=WheelDropView(group:"Tools",inputs:[image],onDrop:{_,_ in},onClose:{})
        try check(imageTools.current.count==7 && imageTools.pageCount==1,"image tools use seven slots on a single wheel")
        try check(abs(imageTools.frame.width-262)<0.01 && abs(imageTools.bounds.width-460)<0.01,"compact wheel scales drawing and hit-test coordinates together")
        try check(abs(WheelDropView.visibleDiameter-252)<1,"visible wheel diameter is approximately 252 points")
        let host=NSView(frame:NSRect(x:0,y:0,width:262,height:262));host.addSubview(imageTools)
        let designPoint=NSPoint(x:imageTools.slotRect(0).midX,y:imageTools.slotRect(0).midY)
        let screenPoint=imageTools.convert(designPoint,to:host)
        try check(imageTools.slot(at:imageTools.convert(screenPoint,from:host))==0,"scaled native drag coordinates still hit the visible segment")

        let firstPath=imageTools.segmentPath(0)
        try check(firstPath === imageTools.segmentPath(0),"hover hit testing reuses cached segment geometry")
        let backdrop=imageTools.materialBackdrop(frame:host.bounds)
        try check(backdrop.subviews.count==1,"wheel uses one shared backdrop instead of overlapping glass views")
        imageTools.needsDisplay=false;imageTools.highlighted=0
        try check(!imageTools.needsDisplay,"hover changes do not invalidate static wheel rendering")
        try check(imageTools.layer?.sublayers?.count==imageTools.current.count+1,"hover and badge graphics are prepared as compositor layers")
        let firstHoverImage=imageTools.layer!.sublayers!.first!.contents as AnyObject?
        let firstBadgeImage=imageTools.layer!.sublayers!.last!.contents as AnyObject?
        imageTools.highlighted=1;imageTools.highlighted=0
        try check(firstHoverImage === (imageTools.layer!.sublayers!.first!.contents as AnyObject?) && firstBadgeImage === (imageTools.layer!.sublayers!.last!.contents as AnyObject?),"repeated hovering reuses the same prepared images")
        let audioWheel=WheelDropView(group:"Conversions",inputs:[URL(fileURLWithPath:"/tmp/sample.wav")],onDrop:{_,_ in},onClose:{})
        try check(audioWheel.current.map(\.id)==["mp3","m4a","flac","ogg","opus","aiff","wma"],"WAV conversion wheel includes every eligible audio target")
        let pdfWheel=WheelDropView(group:"Conversions",inputs:[pdf],onDrop:{_,_ in},onClose:{})
        var reachablePDFFormats=Set<String>()
        for index in pdfWheel.current.indices {
            let rect=pdfWheel.slotRect(index),point=NSPoint(x:rect.midX,y:rect.midY)
            if let slot=pdfWheel.slot(at:point) {reachablePDFFormats.insert(pdfWheel.current[slot].id)}
        }
        try check(pdfWheel.pageCount==1 && reachablePDFFormats==Set(["docx","pages","pptx","txt","md","html","epub","jpg","png","xlsx"]),"all ten PDF formats have a visible drop target without changing pages")
        let mixedImages=WheelDropView(group:"Conversions",inputs:[URL(fileURLWithPath:"/tmp/a.png"),URL(fileURLWithPath:"/tmp/b.jpg")],onDrop:{_,_ in},onClose:{})
        try check(!mixedImages.tools.contains{$0.id=="png" || $0.id=="jpg" || $0.id=="mp3"} && mixedImages.tools.contains{$0.id=="pdf"},"mixed-image wheel offers only conversions eligible for both files")
        let incompatible=WheelDropView(group:"Conversions",inputs:[URL(fileURLWithPath:"/tmp/a.docx"),URL(fileURLWithPath:"/tmp/b.wav")],onDrop:{_,_ in},onClose:{})
        try check(incompatible.tools.isEmpty,"incompatible mixed sources do not receive unrelated conversion choices")
        imageTools.advancePage()
        for i in imageTools.current.indices {let rect=imageTools.slotRect(i);try check(imageTools.slot(at:NSPoint(x:rect.midX,y:rect.midY))==i,"page change rebuilds matching segment geometry \(i)")}
        imageTools.advancePage()
        for i in imageTools.current.indices {let rect=imageTools.slotRect(i);try check(imageTools.slot(at:NSPoint(x:rect.midX,y:rect.midY))==i,"rounded tool segment \(i) accepts its visible center")}
        try check(imageTools.slot(at:NSPoint(x:230,y:230))==nil,"file-preview center remains outside the drop targets")
        try check(try Data(contentsOf:image)==imageOriginal,"wheel conversion preserves the dragged original")
        var dismissals=0
        let canceledDrag=WheelDismissal(startedDragging:true,installMonitors:false){dismissals+=1}
        canceledDrag.samplePressedButtons(1)
        try check(dismissals==0,"wheel remains available while the drag is held")
        canceledDrag.samplePressedButtons(0);canceledDrag.samplePressedButtons(0)
        try check(dismissals==0,"drag release leaves time for AppKit to deliver a valid drop")
        let dismissalDeadline=Date().addingTimeInterval(0.3)
        while Date()<dismissalDeadline {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        try check(dismissals==1,"release without a selection dismisses the wheel exactly once")
        let completedDrag=WheelDismissal(startedDragging:true,installMonitors:false){dismissals+=1}
        completedDrag.dragReleased();completedDrag.invalidate()
        let completedDeadline=Date().addingTimeInterval(0.25)
        while Date()<completedDeadline {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        try check(dismissals==1,"completed or replaced wheels cancel pending dismissal callbacks")
        let manualWheel=WheelDismissal(startedDragging:false,installMonitors:false){dismissals+=1}
        manualWheel.samplePressedButtons(0);manualWheel.dragReleased()
        manualWheel.dismiss();manualWheel.dismiss()
        try check(dismissals==2,"manual wheels dismiss once on cancellation or an outside click")
        count += try PDFToolTests.run(in:dir.appendingPathComponent("pdf-command-tools",isDirectory:true))
        print("SELF-TEST PASSED: \(count) checks")
    }
    static func process(_ args:[String])throws{let p=Process();p.executableURL=URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg");p.arguments=["-hide_banner","-loglevel","error","-nostdin"]+args;let pipe=Pipe();p.standardOutput=pipe;p.standardError=pipe;try p.run();let d=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();if p.terminationStatus != 0{throw UIError.message(String(data:d,encoding:.utf8) ?? "ffmpeg failed")}}
}
