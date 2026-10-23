import AppKit
import ImageIO
import Combine

@MainActor
enum ImageToolTests {
    static func run(in directory:URL) async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var count=0
        func check(_ value:Bool,_ message:String)throws{guard value else{throw UIError.message("Image tool check failed: "+message)};count+=1;print("PASS "+message)}
        let input=directory.appendingPathComponent("Image Fixture.png")
        let image=try ImageTools.bitmap(CGSize(width:360,height:240)){_ in
            NSColor.blue.setFill();CGRect(x:0,y:0,width:360,height:240).fill()
            NSColor.red.setFill();CGRect(x:0,y:0,width:180,height:120).fill()
            NSColor.green.setFill();CGRect(x:180,y:120,width:180,height:120).fill()
            ("Private text 123" as NSString).draw(at:CGPoint(x:30,y:140),withAttributes:[.font:NSFont.systemFont(ofSize:24),.foregroundColor:NSColor.white])
        }
        try ImageTools.encoded(image,type:"public.png",quality:1).write(to:input)
        let original=try Data(contentsOf:input)
        func pixel(_ image:CGImage,_ x:Int,_ y:Int)->NSColor {NSBitmapImageRep(cgImage:image).colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!}
        try check(pixel(image,10,10).redComponent>0.9 && pixel(image,200,200).greenComponent>0.4,"pixel rendering uses a consistent top-left origin")
        let cropped=ImageCanvasState(url:input,mode:.crop,preview:true);cropped.crop=CGRect(x:0,y:0,width:100,height:60)
        let crop=try cropped.render();try check(crop.width==100 && crop.height==60 && pixel(crop,10,10).redComponent>0.9,"crop exports the selected top-left pixels at exact dimensions")
        cropped.aspect="16:9";cropped.setAspect();try check(abs(cropped.crop.width/cropped.crop.height-16.0/9)<0.001,"crop aspect lock preserves the requested ratio")
        cropped.undo();try check(cropped.crop.width==100 && cropped.crop.height==60,"crop undo restores selection dimensions")
        let redact=ImageCanvasState(url:input,mode:.redact,preview:true)
        redact.redactions=[.init(rect:CGRect(x:0,y:0,width:50,height:50),blur:false,color:.black)]
        let hidden=try redact.render();try check(pixel(hidden,10,10).redComponent<0.01 && pixel(hidden,100,10).redComponent>0.9,"solid redaction hides only the selected pixels")
        let originalPixels=try ImagePixels.rgba(redact.source!),hiddenPixels=try ImagePixels.rgba(hidden)
        let outsideUnchanged=(0..<240).allSatisfy{y in (0..<360).allSatisfy{x in
            if x<50 && y<50{return true};let offset=(y*360+x)*4
            return (0..<4).allSatisfy{abs(originalPixels[offset+$0]-hiddenPixels[offset+$0])<0.005}
        }}
        try check(outsideUnchanged,"redaction preserves every pixel outside the selected region")
        redact.redactions=[.init(rect:CGRect(x:150,y:20,width:60,height:80),blur:true,color:.black)]
        let blurred=try redact.render();try check(abs(pixel(blurred,179,50).redComponent-pixel(image,179,50).redComponent)>0.05 && pixel(blurred,10,10).redComponent>0.9,"blur redaction changes the selected boundary and preserves outside pixels")
        let annotations=ImageCanvasState(url:input,mode:.annotate,preview:true)
        for tool in ImageDrawingTool.allCases where tool != .select {
            var mark=ImageDrawingMark(tool:tool,points:[CGPoint(x:60,y:50),CGPoint(x:160,y:100)],color:.yellow,thickness:5)
            if tool == .step || tool == .magnify{mark.points=[CGPoint(x:220,y:70)]}
            mark.placedImage=image;annotations.marks=[mark]
            let result=try annotations.render();try check(try ImageTools.encoded(result,type:"public.png",quality:1) != original,"\(tool.rawValue) renders visible annotation pixels")
        }
        annotations.checkpoint();annotations.marks=[];annotations.undo();try check(annotations.marks.count==1,"annotation undo restores the removed mark");annotations.redo();try check(annotations.marks.isEmpty,"annotation redo reapplies the edit")
        for adjustment in ImageAdjustment.all {
            let value=adjustment.id=="exposure" ? 1:50.0
            let result=try ImageTools.adjusted(image,values:[adjustment.id:value]);try check(result.width==360 && result.height==240,"\(adjustment.label) adjustment renders at original dimensions")
            try check(try ImageTools.encoded(result,type:"public.png",quality:1) != original,"\(adjustment.label) changes exported pixels")
        }
        var bg=ImageBackground();bg.padding=20;bg.corners=10;bg.shadow=8
        let framed=try ImageTools.background(image,settings:bg);try check(framed.width==400 && framed.height==280,"background padding produces exact output dimensions")
        for ratio in ["1:1","16:9","4:5"] {bg.ratio=ratio;let rendered=try ImageTools.background(image,settings:bg);let parts=ratio.split(separator:":").map{Double($0)!};try check(abs(Double(rendered.width)/Double(rendered.height)-parts[0]/parts[1])<0.01,"background \(ratio) ratio preserves the complete image")}
        let annotatedOutput=try ImageTools.save(framed,input:input,directory:directory,suffix:"Background")
        let repeated=try ImageTools.save(framed,input:input,directory:directory,suffix:"Background")
        try check(annotatedOutput != repeated,"repeated saves use unique filenames")
        let compressed=try ImageTools.compress(input,directory:directory,mode:"percentage",preset:"balanced",reduction:50,size:1,unit:"MB")
        try check(try Data(contentsOf:compressed).count<=original.count/2,"percentage compression verifies the output byte limit")
        let fileSize=try ImageTools.compress(input,directory:directory,mode:"fileSize",preset:"balanced",reduction:50,size:2,unit:"KB")
        try check(try Data(contentsOf:fileSize).count<=2000,"file-size compression verifies the output byte limit")
        var rejected=false
        do{_ = try ImageTools.compress(input,directory:directory,mode:"fileSize",preset:"balanced",reduction:50,size:0,unit:"KB")}catch{rejected=true}
        try check(rejected,"invalid compression targets report an error")
        let transparent=try ImageTools.bitmap(CGSize(width:100,height:80)){_ in NSColor.red.setFill();CGRect(x:20,y:20,width:40,height:40).fill()}
        let alphaInput=directory.appendingPathComponent("Alpha.png");try ImageTools.encoded(transparent,type:"public.png",quality:1).write(to:alphaInput)
        let alphaOutput=try ImageTools.compress(alphaInput,directory:directory,mode:"preset",preset:"small",reduction:50,size:1,unit:"MB")
        try check(alphaOutput.pathExtension=="png" && ImageTools.hasTransparency(try ImageTools.load(alphaOutput)),"compression preserves transparent pixels")
        let tagged=directory.appendingPathComponent("Metadata.tiff"),writer=CGImageDestinationCreateWithURL(tagged as CFURL,"public.tiff" as CFString,1,nil)!
        CGImageDestinationAddImage(writer,image,[kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFArtist:"Original Author"],kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:12.5,kCGImagePropertyGPSLatitudeRef:"N"]] as CFDictionary)
        try check(CGImageDestinationFinalize(writer),"tagged metadata fixture saves")
        var fields=try ImageTools.metadata(tagged)
        let artist=fields.firstIndex{$0.path.last==kCGImagePropertyTIFFArtist as String}!,gps=fields.firstIndex{$0.path.last==kCGImagePropertyGPSLatitude as String}!
        fields[artist].value="New Author";fields[artist].edited=true;fields[gps].removed=true
        let edited=try ImageTools.saveMetadata(tagged,directory:directory,fields:fields,removeAll:false),editedFields=try ImageTools.metadata(edited)
        try check(editedFields.contains{$0.path.last==kCGImagePropertyTIFFArtist as String && $0.value=="New Author"},"metadata edits persist in the saved file")
        try check(!editedFields.contains{$0.path.last==kCGImagePropertyGPSLatitude as String},"per-field metadata removal persists")
        let clean=try ImageTools.saveMetadata(tagged,directory:directory,fields:fields,removeAll:true),cleanFields=try ImageTools.metadata(clean)
        try check(!cleanFields.contains{$0.path.last==kCGImagePropertyTIFFArtist as String || $0.group=="GPS"},"Remove All strips author and location metadata")
        var detected:[CGRect]?
        do{detected=try ImageTools.detectedRegions(image,text:true)}catch{
            if NSApplication.shared.isRunning{throw error}
            print("SKIP Vision text detection: service unavailable in headless execution (\(error)); verify in Image Live Checks.")
        }
        if let textRegions=detected{try check(!textRegions.isEmpty && textRegions.allSatisfy{$0.minX>=0 && $0.maxX<=360 && $0.minY>=0 && $0.maxY<=240},"text detection returns source-pixel redaction regions")}
        let previewState=ImagePreviewState(url:input)
        let loadingDeadline=Date().addingTimeInterval(5)
        while previewState.loading && Date()<loadingDeadline{try await Task.sleep(nanoseconds:20_000_000)}
        try check(!previewState.loading && previewState.source != nil,"adjustment preview loads without depending on window appearance events")
        previewState.values=["brightness":40];previewState.refresh()
        let refreshDeadline=Date().addingTimeInterval(5)
        while (previewState.display.map{pixel($0,10,10).greenComponent} ?? 0)<0.1 && Date()<refreshDeadline{try await Task.sleep(nanoseconds:20_000_000)}
        try check((previewState.display.map{pixel($0,10,10).greenComponent} ?? 0)>0.1,"asynchronous brightness preview returns adjusted display pixels")
        var savedPreview:URL?
        previewState.save(background:false,destination:directory){savedPreview=$0}
        let savingDeadline=Date().addingTimeInterval(5)
        while savedPreview==nil && previewState.busy && Date()<savingDeadline{try await Task.sleep(nanoseconds:20_000_000)}
        try check(savedPreview != nil && !previewState.busy,"asynchronous adjustment save reports its completed output")
        // A sustained stream of slider events must publish frames before the stream stops.
        var liveFrames=0
        let previewObservation=previewState.$display.dropFirst().sink{_ in liveFrames+=1}
        previewState.original=true
        for value in 0..<20{
            previewState.values=["brightness":Double(value*4)];previewState.refresh()
            try await Task.sleep(nanoseconds:15_000_000)
        }
        try check(liveFrames>=2 && !previewState.original,"edit preview publishes changed frames while slider events are still arriving")
        let liveDeadline=Date().addingTimeInterval(5)
        while (previewState.display.map{pixel($0,10,10).greenComponent} ?? 0)<0.37 && Date()<liveDeadline{try await Task.sleep(nanoseconds:20_000_000)}
        try check((previewState.display.map{pixel($0,10,10).greenComponent} ?? 0)>0.37,"coalesced edit preview finishes with the latest slider value")
        withExtendedLifetime(previewObservation){}
        let backgroundState=ImagePreviewState(url:input,preview:true,renderBackground:true)
        var backgroundFrames=0
        let backgroundObservation=backgroundState.$display.dropFirst().sink{_ in backgroundFrames+=1}
        for value in 0..<20{
            backgroundState.background.padding=Double(20+value*8);backgroundState.refresh(background:true)
            try await Task.sleep(nanoseconds:15_000_000)
        }
        try check(backgroundFrames>=2,"background preview publishes frames during continuous padding changes")
        let backgroundDeadline=Date().addingTimeInterval(5)
        while backgroundState.display?.width != 704 && Date()<backgroundDeadline{try await Task.sleep(nanoseconds:20_000_000)}
        try check(backgroundState.display?.width==704,"background preview uses the final padding value")
        withExtendedLifetime(backgroundObservation){}

        let markerState=ImageCanvasState(url:input,mode:.annotate,preview:true)
        markerState.install(try ImageTools.bitmap(CGSize(width:720,height:480)){_ in ImageTools.draw(image,in:CGRect(x:0,y:0,width:720,height:480))})
        markerState.tool = .step;markerState.color = .yellow;markerState.canvasScale=0.15
        let firstMarker=markerState.newMark(CGPoint(x:150,y:120));markerState.marks=[firstMarker]
        let secondMarker=markerState.newMark(CGPoint(x:230,y:120))
        try check(firstMarker.number==1 && secondMarker.number==2,"numbered markers increment when placed")
        try check(abs(firstMarker.bounds.width*markerState.canvasScale-28)<0.01,"marker diameter stays 28 screen points when the photo is scaled down")
        markerState.selected=0;markerState.color = .cyan;markerState.updateSelected()
        try check(abs(markerState.marks[0].fontSize*markerState.canvasScale-28)<0.01,"changing marker color preserves its visible size")
        markerState.markerSize=40;markerState.updateSelected()
        try check(abs(markerState.marks[0].fontSize*markerState.canvasScale-40)<0.01,"marker size control resizes the selected number")
        markerState.color = .yellow;markerState.updateSelected()
        let markerImage=try markerState.render(),markerPixels=try ImagePixels.rgba(markerImage)
        let markerBounds=markerState.marks[0].bounds.integral.intersection(markerState.bounds)
        var darkGlyphPixels=0
        for y in Int(markerBounds.minY)..<Int(markerBounds.maxY){for x in Int(markerBounds.minX)..<Int(markerBounds.maxX){let offset=(y*markerImage.width+x)*4;if markerPixels[offset]<0.15 && markerPixels[offset+1]<0.15 && markerPixels[offset+2]<0.15{darkGlyphPixels+=1}}}
        try check(darkGlyphPixels>20,"yellow number markers render readable dark digits")
        let smallScreen=NSRect(x:0,y:0,width:1280,height:680)
        let bounded=imageToolPanelSize(NSSize(width:500,height:820),visibleFrame:smallScreen)
        try check(bounded.height==656,"tall image panels fit inside the screen's usable height")
        if NSApplication.shared.isRunning{
            for operation in ["compress","removeMetadata"]{
                let (body,size)=imageToolContent(operation:operation,url:input,destination:directory,onSave:{_ in},onClose:{})
                let panel=PDFToolWindow.make(view:body,size:size)
                panel.orderFront(nil);panel.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:100_000_000)
                try check(abs(panel.frame.height-size.height)<1 && abs(panel.contentView!.bounds.height-size.height)<1,"\(operation) glass panel keeps its requested height with footer onscreen")
                panel.close()
            }
        }
        let model=AppModel();var presented:[String]=[];model.imageToolPresenter={operation,urls,dest in presented.append(operation)}
        for id in ["compress","removeMetadata","editImage","annotateImage","frameImage","cropImage","redactImage"] {model.submitWheelDrop(Tool.all.first{$0.id==id}!,urls:[input],destination:directory)}
        try check(presented.count==7 && model.pendingJobs==0,"all seven image wheel actions open editors instead of running stale processing options")
        try check(try Data(contentsOf:input)==original,"all image tools preserve original file bytes")
        print("IMAGE TOOL CHECKS PASSED: \(count)")
    }
}
