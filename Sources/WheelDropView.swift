import AppKit

/// Native Finder drop receiver with rounded radial segments and glass backing.
final class WheelDropView:NSView {
    static let panelSize:CGFloat=262
    static let designSize:CGFloat=460
    static let visibleDiameter:CGFloat=panelSize*(442/designSize)
    var usesMaterial=true
    private weak var materialHost:NSView?
    static let legacyFiles=NSPasteboard.PasteboardType("NSFilenamesPboardType")
    let group:String
    let inputs:[URL]
    let onDrop:(Tool,[URL])->Void
    let onClose:()->Void
    let onHighlight:()->Void
    var page=0
    var highlighted:Int? {didSet{if oldValue != highlighted {
        animateHighlight()
        if highlighted != nil {onHighlight()}
    }}}
    var tracking:NSTrackingArea?
    var pageTimer:Timer?
    private var highlightLayers:[CALayer]=[]
    private var selectedImages:[CGImage]=[]
    private var centerImages:[String:CGImage]=[:]
    private var centerTextLayer:CALayer?
    private var dragPasteboardChange:Int?
    private var dragHasFiles=false
    private var pathCache:[Int:NSBezierPath]=[:]
    private var symbolCache:[String:NSImage]=[:]
    private lazy var centerLabel:String = {
        let total=inputs.reduce(Int64(0)){$0+Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
        return inputs.isEmpty ? (group == "Conversions" ? "Convert":group) : total>0 ? ByteCountFormatter.string(fromByteCount:total,countStyle:.file):"\(inputs.count) files"
    }()
    override var isFlipped:Bool {true}
    override var acceptsFirstResponder:Bool {true}
    override var isOpaque:Bool {false}
    lazy var tools:[Tool] = {
        let ext=inputs.first?.pathExtension.lowercased() ?? ""
        let imageTypes:Set<String>=["png","jpg","jpeg","heic","webp","tif","tiff","avif","bmp","gif","svg"]
        let audioTypes=AudioTrim.extensions
        let videoTypes=VideoTools.extensions
        if group == "Conversions" {
            func targets(_ raw:String)->[String] {
                let source=["jpeg":"jpg","jpe":"jpg","tif":"tiff","heif":"heic","gz":"gzip","tgz":"gzip" ][raw] ?? raw
                if source=="json" {return ["csv","tsv","xlsx"]}
                if source=="ass" {return ["srt","vtt","txt"]}
                return SettingsCatalog.targets(source)
            }
            // Only offer targets shared by every dragged input; unknown files do not
            // inherit the unrelated image/audio/document choices of the old fallback.
            var formats=inputs.isEmpty ? targets("png"):targets(ext)
            for input in inputs.dropFirst() {let eligible=Set(targets(input.pathExtension.lowercased()));formats.removeAll{!eligible.contains($0)}}
            return formats.map{Tool(id:$0,name:$0.uppercased(),icon:"doc",group:"Format")}
        }
        if group == "Actions" {return Tool.all.filter{$0.group=="Actions"}}
        let ids:[String]
        if imageTypes.contains(ext) {ids=["compress","removeMetadata","editImage","annotateImage","frameImage","cropImage","redactImage"]}
        else if audioTypes.contains(ext) {ids=["trimAudio"]}
        else if videoTypes.contains(ext) {ids=VideoTools.singleToolIDs+(inputs.count>1 ? ["joinVideos"]:[])}
        else if ext == "pdf" {ids=["compress","removeMetadata","splitPDF","organizePDF","readQRCode"]}
        else if ["zip","tar","gz","tgz"].contains(ext) {ids=["extractArchive"]}
        else {return Tool.all.filter{!["Actions","Conversions"].contains($0.group)}}
        return ids.compactMap{id in Tool.all.first{$0.id==id}}
    }()
    var pageSize:Int {
        // Conversion formats fit in one ring (PDF has ten). A drag should not
        // require finding the tiny center pager to reach its remaining outputs.
        if group == "Conversions" || (group == "Tools" && VideoTools.extensions.contains(inputs.first?.pathExtension.lowercased() ?? "")) {return max(1,tools.count)}
        return group == "Tools" && ["png","jpg","jpeg","heic","webp","tif","tiff","avif","bmp","gif","svg"].contains(inputs.first?.pathExtension.lowercased() ?? "") ? 7:8
    }
    var pageCount:Int {max(1,(tools.count+pageSize-1)/pageSize)}
    var current:[Tool] {Array(tools.dropFirst(page*pageSize).prefix(pageSize))}
    init(group:String,inputs:[URL]=[],onHighlight:@escaping()->Void={},onDrop:@escaping(Tool,[URL])->Void,onClose:@escaping()->Void) {
        self.group=group;self.inputs=inputs;self.onHighlight=onHighlight;self.onDrop=onDrop;self.onClose=onClose
        super.init(frame:NSRect(x:0,y:0,width:Self.panelSize,height:Self.panelSize))
        setBoundsSize(NSSize(width:Self.designSize,height:Self.designSize))
        wantsLayer=true
        registerForDraggedTypes([.fileURL,Self.legacyFiles,.URL])
        setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel("Citrus \(group) wheel. Drop files onto a segment. Escape closes.")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is unsupported")}
    deinit{pageTimer?.invalidate()}
    /// A single masked backdrop serves the rim, separated petals, and center badge.
    func materialBackdrop(frame:NSRect)->NSView {
        let host=NSView(frame:frame);host.wantsLayer=true;materialHost=host;rebuildMaterials();prepareHoverLayers();return host
    }
    private func rebuildMaterials(){
        guard let host=materialHost else{return}
        host.subviews.forEach{$0.removeFromSuperview()}
        host.layer?.sublayers?.forEach{$0.removeFromSuperlayer()}
        let maskPath=NSBezierPath()
        for index in current.indices {maskPath.append(segmentPath(index))}
        maskPath.append(NSBezierPath(roundedRect:NSRect(x:168,y:198,width:124,height:64),xRadius:32,yRadius:32))
        guard usesMaterial else{return}
        let surface:NSView
        if #available(macOS 26.0,*) {
            let glass=NSGlassEffectView(frame:host.bounds);glass.style = .regular;glass.cornerRadius=0;glass.tintColor=nil
            surface=glass
        } else {
            let glass=NSVisualEffectView(frame:host.bounds);glass.material = .hudWindow;glass.blendingMode = .behindWindow;glass.state = .active
            surface=glass
        }
        surface.appearance=NSAppearance(named:.darkAqua);surface.wantsLayer=true
        var transform=CGAffineTransform(a:host.bounds.width/Self.designSize,b:0,c:0,d:-host.bounds.height/Self.designSize,tx:0,ty:host.bounds.height)
        let mask=CAShapeLayer();mask.path=Self.cgPath(maskPath).copy(using:&transform)
        surface.layer?.mask=mask;host.addSubview(surface)
    }
    private static func cgPath(_ path:NSBezierPath)->CGPath {
        if #available(macOS 14.0,*) {return path.cgPath}
        let output=CGMutablePath();var points=[NSPoint](repeating:.zero,count:3)
        for index in 0..<path.elementCount {
            switch path.element(at:index,associatedPoints:&points).rawValue{
            case NSBezierPath.ElementType.moveTo.rawValue:output.move(to:points[0])
            case NSBezierPath.ElementType.lineTo.rawValue:output.addLine(to:points[0])
            case NSBezierPath.ElementType.curveTo.rawValue:output.addCurve(to:points[2],control1:points[0],control2:points[1])
            case NSBezierPath.ElementType.closePath.rawValue:output.closeSubpath()
            default:break
            }
        }
        return output
    }
    override func updateTrackingAreas(){super.updateTrackingAreas();if let old=tracking{removeTrackingArea(old)};let area=NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseMoved,.mouseEnteredAndExited],owner:self,userInfo:nil);tracking=area;addTrackingArea(area)}
    var segmentCount:Int {max(1,current.count)}
    func angle(_ index:Int)->CGFloat {-CGFloat.pi/2+CGFloat(index)*2*CGFloat.pi/CGFloat(segmentCount)}
    func polar(_ radius:CGFloat,_ angle:CGFloat)->NSPoint {NSPoint(x:230+cos(angle)*radius,y:230+sin(angle)*radius)}
    func slotRect(_ index:Int)->NSRect {
        let center=polar(153,angle(index));return NSRect(x:center.x-48,y:center.y-38,width:96,height:76)
    }
    /// One rounded annular sector. The drawn path also defines its drop target.
    func segmentPath(_ index:Int)->NSBezierPath {
        if let path=pathCache[index] {return path}
        let outer:CGFloat=211,inner:CGFloat=84,rounding:CGFloat=24
        let span=min(2*CGFloat.pi/CGFloat(segmentCount),CGFloat.pi/2)
        let start=angle(index)-span/2+0.014,end=angle(index)+span/2-0.014
        let outerInset=rounding/outer,innerInset=rounding/inner
        let p=NSBezierPath();p.move(to:polar(outer,start+outerInset))
        for step in 1...40 {let t=CGFloat(step)/40;p.line(to:polar(outer,start+outerInset+(end-start-outerInset*2)*t))}
        p.curve(to:polar(outer-rounding,end),controlPoint1:polar(outer,end),controlPoint2:polar(outer,end))
        p.line(to:polar(inner+rounding,end))
        p.curve(to:polar(inner,end-innerInset),controlPoint1:polar(inner,end),controlPoint2:polar(inner,end))
        for step in 1...30 {let t=CGFloat(step)/30;p.line(to:polar(inner,end-innerInset-(end-start-innerInset*2)*t))}
        p.curve(to:polar(inner+rounding,start),controlPoint1:polar(inner,start),controlPoint2:polar(inner,start))
        p.line(to:polar(outer-rounding,start))
        p.curve(to:polar(outer,start+outerInset),controlPoint1:polar(outer,start),controlPoint2:polar(outer,start));p.close();pathCache[index]=p;return p
    }
    func slot(at point:NSPoint)->Int? {current.indices.first{segmentPath($0).contains(point)}}
    var nextRect:NSRect {NSRect(x:194,y:269,width:72,height:20)}
    static func fileURLs(from pasteboard:NSPasteboard)->[URL] {
        if let urls=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty{return urls.filter(\.isFileURL)}
        if let paths=pasteboard.propertyList(forType:legacyFiles) as? [String] {return paths.filter{$0.hasPrefix("/")}.map{URL(fileURLWithPath:$0)}}
        return (pasteboard.pasteboardItems ?? []).compactMap{item in guard let text=item.string(forType:.fileURL),let url=URL(string:text),url.isFileURL else{return nil};return url}
    }
    @discardableResult func receive(_ pasteboard:NSPasteboard,at point:NSPoint)->Bool {
        guard let index=slot(at:point) else{return false}
        let urls=Self.fileURLs(from:pasteboard);guard !urls.isEmpty else{return false}
        onDrop(current[index],urls);return true
    }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {dragPasteboardChange=nil;return draggingUpdated(sender)}
    override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation {
        let point=convert(sender.draggingLocation,from:nil);highlighted=slot(at:point)
        if nextRect.contains(point),tools.count>pageSize {
            if pageTimer==nil {let timer=Timer(timeInterval:0.65,repeats:false){[weak self] _ in self?.advancePage()};pageTimer=timer;RunLoop.main.add(timer,forMode:.common)}
        } else {pageTimer?.invalidate();pageTimer=nil}
        let board=sender.draggingPasteboard
        if dragPasteboardChange != board.changeCount {
            dragPasteboardChange=board.changeCount;dragHasFiles = !Self.fileURLs(from:board).isEmpty
        }
        return highlighted != nil && dragHasFiles ? .copy:[]
    }
    func advancePage(){page=(page+1)%pageCount;highlighted=nil;pathCache=[:];highlightLayers.forEach{$0.removeFromSuperlayer()};highlightLayers=[];selectedImages=[];centerImages=[:];centerTextLayer?.removeFromSuperlayer();centerTextLayer=nil;rebuildMaterials();prepareHoverLayers();needsDisplay=true;pageTimer?.invalidate();pageTimer=nil}
    override func draggingExited(_ sender:NSDraggingInfo?){highlighted=nil;pageTimer?.invalidate();pageTimer=nil}
    override func prepareForDragOperation(_ sender:NSDraggingInfo)->Bool {slot(at:convert(sender.draggingLocation,from:nil)) != nil && !Self.fileURLs(from:sender.draggingPasteboard).isEmpty}
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {pageTimer?.invalidate();pageTimer=nil;return receive(sender.draggingPasteboard,at:convert(sender.draggingLocation,from:nil))}
    override func draggingEnded(_ sender:NSDraggingInfo){highlighted=nil;pageTimer?.invalidate();pageTimer=nil;onClose()}
    override func wantsPeriodicDraggingUpdates()->Bool {true}
    override func mouseMoved(with event:NSEvent){highlighted=slot(at:convert(event.locationInWindow,from:nil))}
    override func mouseExited(with event:NSEvent){highlighted=nil}
    override func mouseDown(with event:NSEvent){let p=convert(event.locationInWindow,from:nil);if nextRect.contains(p),tools.count>pageSize{advancePage()}else{highlighted=slot(at:p)}}
    override func keyDown(with event:NSEvent){if event.keyCode==53{onClose()}else{super.keyDown(with:event)}}
    private let centerTextRect=NSRect(x:174,y:219,width:112,height:26)
    private func raster(in rect:NSRect,_ draw:()->Void)->CGImage {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(ceil(rect.width)),pixelsHigh:Int(ceil(rect.height)),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        let cg=context.cgContext;cg.translateBy(x:-rect.minX,y:rect.maxY);cg.scaleBy(x:1,y:-1)
        NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
        draw();NSGraphicsContext.restoreGraphicsState();return bitmap.cgImage!
    }
    private func badgeText(_ index:Int?)->String {
        index.map{group == "Conversions" ? current[$0].name.uppercased():shortName(current[$0])} ?? centerLabel
    }
    private func badgeImage(_ text:String)->CGImage {
        if let image=centerImages[text] {return image}
        let image=raster(in:centerTextRect){self.drawText(text,in:self.centerTextRect,font:.systemFont(ofSize:18,weight:.semibold),color:self.ink)}
        centerImages[text]=image;return image
    }
    /// All bitmaps are prepared before the wheel appears. Hover changes only
    /// compositor opacity/contents; it never invalidates the static NSView.
    private func overlayFrame(_ rect:NSRect,in parent:CALayer)->NSRect {
        parent.isGeometryFlipped ? rect:NSRect(x:rect.minX,y:bounds.height-rect.maxY,width:rect.width,height:rect.height)
    }
    override func layout(){
        super.layout();guard let backing=layer else{return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        for (index,highlight) in highlightLayers.enumerated() {highlight.frame=overlayFrame(segmentPath(index).bounds.insetBy(dx:-2,dy:-2).integral,in:backing)}
        centerTextLayer?.frame=overlayFrame(centerTextRect,in:backing)
        CATransaction.commit()
    }
    func prepareHoverLayers(){
        guard let backing=layer else{return}
        guard highlightLayers.count != current.count || centerTextLayer==nil else{return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        for index in current.indices {
            let rect=segmentPath(index).bounds.insetBy(dx:-2,dy:-2).integral
            let image=raster(in:rect){self.drawSegment(index,selected:true)}
            selectedImages.append(image)
            let highlight=CALayer();highlight.frame=overlayFrame(rect,in:backing);highlight.contents=image;highlight.opacity=0
            backing.addSublayer(highlight);highlightLayers.append(highlight)
            _ = badgeImage(badgeText(index))
        }
        let text=CALayer();text.frame=overlayFrame(centerTextRect,in:backing);text.contents=badgeImage(badgeText(nil))
        backing.addSublayer(text);centerTextLayer=text
        CATransaction.commit()
    }
    func animateHighlight(){
        prepareHoverLayers()
        CATransaction.begin();CATransaction.setAnimationDuration(0.1)
        for (index,highlight) in highlightLayers.enumerated(){highlight.opacity=highlighted==index ? 1:0}
        CATransaction.commit()
        CATransaction.begin();CATransaction.setDisableActions(true)
        centerTextLayer?.contents=badgeImage(badgeText(highlighted))
        CATransaction.commit()
    }
    private let ink=NSColor.white.withAlphaComponent(0.94)
    private func gray(_ white:CGFloat,_ alpha:CGFloat=1)->NSColor {NSColor(srgbRed:white,green:white,blue:white,alpha:alpha)}
    override func draw(_ dirtyRect:NSRect) {
        // A clear rim and center let the desktop show through.
        let rim=NSBezierPath(ovalIn:NSRect(x:9,y:9,width:442,height:442))
        rim.appendOval(in:NSRect(x:154,y:154,width:152,height:152));rim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(usesMaterial ? 0.12:0.3).setFill();rim.fill()
        gray(1,0.22).setStroke();rim.lineWidth=0.8;rim.stroke()
        let edge=NSBezierPath(ovalIn:NSRect(x:11,y:11,width:438,height:438))
        gray(1,0.08).setStroke();edge.lineWidth=0.7;edge.stroke()
        for i in current.indices {drawSegment(i,selected:false)}
        drawCenter()
    }
    private func drawSegment(_ i:Int,selected:Bool){
            let target=current[i]
            let path=segmentPath(i)
            if selected {
                NSGradient(starting:NSColor(srgbRed:0.77,green:0.35,blue:0.15,alpha:1),ending:NSColor(srgbRed:0.94,green:0.51,blue:0.36,alpha:1))?.draw(in:path,angle:90)
            } else {
                let top=NSColor(srgbRed:0.07,green:0.10,blue:0.14,alpha:usesMaterial ? 0.10:0.95)
                let bottom=NSColor(srgbRed:0.07,green:0.09,blue:0.11,alpha:usesMaterial ? 0.16:0.95)
                NSGradient(starting:top,ending:bottom)?.draw(in:path,angle:90)
            }
            gray(1,0.10).setStroke();path.lineWidth=1;path.stroke()
            let inset=AffineTransform(translationByX:0,byY:-0.8)
            let lip=path.copy() as! NSBezierPath;lip.transform(using:inset)
            gray(1,0.08).setStroke();lip.lineWidth=0.7;lip.stroke()
            let center=polar(153,angle(i)),color=selected ? NSColor.white:ink
            if group == "Conversions" {
                drawText(target.name,in:NSRect(x:center.x-57,y:center.y-12,width:114,height:27),font:.systemFont(ofSize:21,weight:.semibold),color:color)
            } else {
                let key=target.icon+(selected ? ".selected":"")
                if symbolCache[key]==nil {symbolCache[key]=NSImage(systemSymbolName:target.icon,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:24,weight:.medium))?.withSymbolConfiguration(.init(paletteColors:[color]))}
                if let icon=symbolCache[key] {icon.draw(in:NSRect(x:center.x-12,y:center.y-20,width:24,height:24),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)}
                drawText(shortName(target),in:NSRect(x:center.x-53,y:center.y+5,width:106,height:24),font:.systemFont(ofSize:14.5,weight:.semibold),color:color)
            }
        }
    func drawCenter(){
        let pill=NSBezierPath(roundedRect:NSRect(x:168,y:198,width:124,height:64),xRadius:32,yRadius:32)
        NSGradient(starting:gray(0.16,usesMaterial ? 0.17:0.95),ending:gray(0.22,usesMaterial ? 0.22:0.95))?.draw(in:pill,angle:90)
        gray(1,0.26).setStroke();pill.lineWidth=0.8;pill.stroke()
        if tools.count>pageSize {drawText("\(page+1)/\(pageCount)  ›",in:nextRect,font:.systemFont(ofSize:13,weight:.medium),color:ink)}
    }
    func writePreview(to url:URL) throws {
        let pixels=Int(Self.panelSize*2)
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        let cg=context.cgContext;cg.translateBy(x:0,y:CGFloat(pixels));cg.scaleBy(x:CGFloat(pixels)/Self.designSize,y:-CGFloat(pixels)/Self.designSize)
        NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
        gray(0.95).setFill();bounds.fill()
        // Offscreen preview approximates glass; the live window samples the desktop.
        for index in current.indices {NSColor(srgbRed:0.07,green:0.10,blue:0.14,alpha:0.87).setFill();segmentPath(index).fill()}
        let badge=NSBezierPath(roundedRect:NSRect(x:168,y:198,width:124,height:64),xRadius:32,yRadius:32)
        gray(0.18,0.8).setFill();badge.fill()
        draw(bounds)
        prepareHoverLayers()
        if let index=highlighted {
            let rect=segmentPath(index).bounds.insetBy(dx:-2,dy:-2).integral
            NSImage(cgImage:selectedImages[index],size:rect.size).draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        NSImage(cgImage:badgeImage(badgeText(highlighted)),size:centerTextRect.size).draw(in:centerTextRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using:.png,properties:[:])!.write(to:url)
    }
    func shortName(_ tool:Tool)->String {
        let names=["trimAudio":"TRIM","muteVideo":"MUTE","trimVideo":"TRIM","cropVideo":"CROP","changeVideoSpeed":"SPEED","videoSnapshots":"SNAPSHOT","splitVideo":"SPLIT","redactVideo":"REDACT","joinVideos":"JOIN","compress":"COMPRESS","removeMetadata":"METADATA","editImage":"EDIT","annotateImage":"ANNOTATE","frameImage":"ADD BG","cropImage":"CROP","redactImage":"REDACT","resizeImage":"RESIZE","rotateImage":"ROTATE","createCollage":"COLLAGE","readQRCode":"QR CODE","copyPath":"COPY PATH","openTerminal":"TERMINAL","float":"FLOAT","copy":"COPY","move":"MOVE","airDrop":"AIRDROP"]
        return names[tool.id] ?? tool.name.uppercased()
    }
    func drawText(_ text:String,in rect:NSRect,font:NSFont,color:NSColor){let p=NSMutableParagraphStyle();p.alignment = .center;p.lineBreakMode = .byWordWrapping;(text as NSString).draw(in:rect,withAttributes:[.font:font,.foregroundColor:color,.paragraphStyle:p,.kern:font.pointSize<16 ? 0.5:0])}
}
