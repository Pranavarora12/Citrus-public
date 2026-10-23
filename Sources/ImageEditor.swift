import AppKit
import SwiftUI

// Stored in source-pixel coordinates so preview scaling never changes saved geometry.
enum ImageDrawingTool:String,CaseIterable {
    case select="Select",arrow="Arrow",line="Line",text="Text",rectangle="Rectangle",ellipse="Ellipse",pen="Pen",highlight="Highlight",step="Number",magnify="Magnifier",image="Image"
    var icon:String {switch self {case .select:return "cursorarrow";case .arrow:return "arrow.up.left";case .line:return "line.diagonal";case .text:return "textformat";case .rectangle:return "rectangle";case .ellipse:return "circle";case .pen:return "pencil.tip";case .highlight:return "highlighter";case .step:return "1.circle";case .magnify:return "plus.magnifyingglass";case .image:return "photo.badge.plus"}}
    var hint:String {switch self {case .select:return "Click a mark to select it. Drag to move; drag its handles to resize.";case .text:return "Click to place text. Edit it below; drag its border to move or its handles to resize.";case .step:return "Click to add a numbered marker. Undo removes the last marker.";case .magnify:return "Choose a zoom level, then click a detail to place a magnifier bubble.";case .image:return "Choose an image, then drag a rectangle to place it.";case .highlight:return "Drag over the image to highlight.";default:return "Drag on the image to draw. Select a mark to move or resize it."}}
}
struct ImageDrawingMark {
    var tool:ImageDrawingTool
    var points:[CGPoint]
    var color:NSColor
    var thickness:CGFloat
    var text:String="Text"
    var fontSize:CGFloat=48
    var fontName:String="System"
    var number:Int=1
    var zoom:Double=2
    var placedImage:CGImage?
    var bounds:CGRect {
        guard let first=points.first else{return .zero}
        if tool == .step {return CGRect(x:first.x-fontSize/2,y:first.y-fontSize/2,width:fontSize,height:fontSize)}
        if tool == .magnify {return CGRect(x:first.x-fontSize,y:first.y-fontSize,width:fontSize*2,height:fontSize*2)}
        if tool == .text,points.count<2 {return CGRect(x:first.x,y:first.y,width:max(120,fontSize*5),height:fontSize*1.6)}
        let xs=points.map(\.x),ys=points.map(\.y)
        return CGRect(x:xs.min() ?? 0,y:ys.min() ?? 0,width:max(1,(xs.max() ?? 0)-(xs.min() ?? 0)),height:max(1,(ys.max() ?? 0)-(ys.min() ?? 0)))
    }
}
struct ImageRedaction {
    var rect:CGRect
    var blur:Bool
    var color:NSColor
}

func drawImageMark(_ mark:ImageDrawingMark,source:CGImage) {
    guard let first=mark.points.first else{return}
    let last=mark.points.last ?? first,rect=mark.bounds
    let cg=NSGraphicsContext.current!.cgContext
    cg.saveGState();defer{cg.restoreGState()}
    mark.color.setStroke();mark.color.setFill()
    let path=NSBezierPath();path.lineWidth=mark.thickness;path.lineCapStyle = .round;path.lineJoinStyle = .round
    switch mark.tool {
    case .select:break
    case .rectangle:path.appendRect(rect);path.stroke()
    case .ellipse:path.appendOval(in:rect);path.stroke()
    case .line,.arrow:
        path.move(to:first);path.line(to:last);path.stroke()
        if mark.tool == .arrow {
            let angle=atan2(last.y-first.y,last.x-first.x),length=max(14,mark.thickness*3)
            let head=NSBezierPath();head.move(to:last);head.line(to:CGPoint(x:last.x-length*cos(angle-0.48),y:last.y-length*sin(angle-0.48)));head.line(to:CGPoint(x:last.x-length*cos(angle+0.48),y:last.y-length*sin(angle+0.48)));head.close();head.fill()
        }
    case .pen,.highlight:
        if mark.tool == .highlight {mark.color.withAlphaComponent(0.4).setStroke();path.lineWidth=max(12,mark.thickness*5)}
        path.move(to:first);for point in mark.points.dropFirst(){path.line(to:point)};path.stroke()
    case .text:
        let font=mark.fontName=="System" ? NSFont.systemFont(ofSize:mark.fontSize,weight:.semibold):NSFont(name:mark.fontName,size:mark.fontSize) ?? NSFont.systemFont(ofSize:mark.fontSize)
        let style=NSMutableParagraphStyle();style.lineBreakMode = .byWordWrapping
        (mark.text as NSString).draw(in:rect,withAttributes:[.font:font,.foregroundColor:mark.color,.paragraphStyle:style])
    case .step:
        NSBezierPath(ovalIn:rect).fill()
        let rgb=mark.color.usingColorSpace(.sRGB) ?? .red
        let light=0.2126*rgb.redComponent+0.7152*rgb.greenComponent+0.0722*rgb.blueComponent
        let label=String(mark.number) as NSString
        let typeSize=mark.fontSize*(label.length>2 ? 0.4:0.58)
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.boldSystemFont(ofSize:typeSize),.foregroundColor:light>0.6 ? NSColor.black:NSColor.white]
        let size=label.size(withAttributes:attributes);label.draw(at:CGPoint(x:rect.midX-size.width/2,y:rect.midY-size.height/2),withAttributes:attributes)
    case .magnify:
        let circle=NSBezierPath(ovalIn:rect);circle.addClip()
        NSColor.black.setFill();rect.fill()
        let sample=CGRect(x:first.x-rect.width/mark.zoom/2,y:first.y-rect.height/mark.zoom/2,width:rect.width/mark.zoom,height:rect.height/mark.zoom)
        // Draw the full image enlarged around the selected source point; this also handles edge bubbles.
        ImageTools.draw(source,in:CGRect(x:rect.minX-sample.minX*mark.zoom,y:rect.minY-sample.minY*mark.zoom,width:CGFloat(source.width)*mark.zoom,height:CGFloat(source.height)*mark.zoom))
        circle.lineWidth=max(3,mark.thickness);mark.color.setStroke();circle.stroke()
    case .image:if let image=mark.placedImage{ImageTools.draw(image,in:rect)}
    }
}

enum ImageCanvasMode {case annotate,crop,redact}
@MainActor
final class ImageCanvasState:ObservableObject {
    let url:URL
    let mode:ImageCanvasMode
    @Published var source:CGImage?
    @Published var preview:CGImage?
    @Published var loading=true
    @Published var busy=false
    @Published var message=""
    @Published var tool:ImageDrawingTool = .select
    @Published var color:Color = .red
    @Published var thickness=6.0
    @Published var markerSize=28.0
    var canvasScale:CGFloat=1
    @Published var text="Text"
    @Published var fontSize=48.0
    @Published var fontName="System"
    @Published var zoom=2.0
    @Published var placedImage:CGImage?
    @Published var marks:[ImageDrawingMark]=[]
    @Published var redactions:[ImageRedaction]=[]
    @Published var crop=CGRect.zero
    @Published var aspect="Free"
    @Published var selected:Int?
    @Published var selectedRedaction:Int?
    @Published var draft:ImageDrawingMark?
    @Published var blur=false
    @Published var blurRadius=24.0
    @Published var widthText=""
    @Published var heightText=""
    private var history:[([ImageDrawingMark],[ImageRedaction],CGRect)]=[]
    private var future:[([ImageDrawingMark],[ImageRedaction],CGRect)]=[]
    private var started=false
    init(url:URL,mode:ImageCanvasMode,preview:Bool=false){self.url=url;self.mode=mode;if mode == .redact{color = .black};if preview{do{install(try ImageTools.load(url))}catch{loading=false;message=error.localizedDescription}}else{load()}}
    var size:CGSize {CGSize(width:source?.width ?? 0,height:source?.height ?? 0)}
    var bounds:CGRect {CGRect(origin:.zero,size:size)}
    var canUndo:Bool {!history.isEmpty}
    var canRedo:Bool {!future.isEmpty}
    func load(){guard loading,!started else{return};started=true;DispatchQueue.global(qos:.userInitiated).async{let result=Result{try ImageTools.load(self.url)};DispatchQueue.main.async{switch result{case .success(let source):self.install(source);case .failure(let error):self.loading=false;self.message=error.localizedDescription}}}}
    func install(_ image:CGImage){source=image;preview=ImageTools.scaled(image,maxEdge:1600);loading=false;crop=bounds;syncDimensions()}
    func checkpoint(){history.append((marks,redactions,crop));if history.count>100{history.removeFirst()};future=[]}
    func undo(){guard let old=history.popLast() else{return};future.append((marks,redactions,crop));marks=old.0;redactions=old.1;crop=old.2;selected=nil;selectedRedaction=nil;draft=nil;syncDimensions()}
    func redo(){guard let next=future.popLast() else{return};history.append((marks,redactions,crop));marks=next.0;redactions=next.1;crop=next.2;selected=nil;selectedRedaction=nil;syncDimensions()}
    func reset(){checkpoint();marks=[];redactions=[];crop=bounds;selected=nil;selectedRedaction=nil;draft=nil;aspect="Free";message="";syncDimensions()}
    func deleteSelection(){checkpoint();if let selected,marks.indices.contains(selected){marks.remove(at:selected)};if let selectedRedaction,redactions.indices.contains(selectedRedaction){redactions.remove(at:selectedRedaction)};selected=nil;selectedRedaction=nil}
    func syncDimensions(){widthText=String(Int(crop.width.rounded()));heightText=String(Int(crop.height.rounded()))}
    var ratio:Double? {let parts=aspect.split(separator:":").compactMap{Double($0)};return parts.count==2 ? parts[0]/parts[1]:nil}
    func setAspect(){guard let ratio,source != nil else{return};checkpoint();var width=crop.width,height=width/ratio;if height>size.height {height=size.height;width=height*ratio};crop=CGRect(x:max(0,min(crop.midX-width/2,size.width-width)),y:max(0,min(crop.midY-height/2,size.height-height)),width:width,height:height);syncDimensions()}
    func setDimensions(width:Bool){guard let value=Double(width ? widthText:heightText),value.isFinite,value>=1 else{syncDimensions();return};checkpoint();var rect=crop;if width{rect.size.width=min(value,size.width-rect.minX);if let ratio{rect.size.height=rect.width/ratio}}else{rect.size.height=min(value,size.height-rect.minY);if let ratio{rect.size.width=rect.height*ratio}};if rect.maxY>size.height || rect.maxX>size.width{message="Those dimensions do not fit the image.";syncDimensions();return};crop=rect;syncDimensions()}
    func chooseImage(){let picker=NSOpenPanel();picker.allowedContentTypes=[.image];guard picker.runModal() == .OK,let url=picker.url else{return};do{placedImage=try ImageTools.load(url);tool = .image;selected=nil}catch{message=error.localizedDescription}}
    private var markerDiameter:CGFloat {
        min(max(1,markerSize/max(0.001,canvasScale)),max(1,min(size.width,size.height)))
    }
    func newMark(_ point:CGPoint)->ImageDrawingMark {
        let diameter=tool == .step ? markerDiameter:fontSize
        var center=point
        if tool == .step{let radius=diameter/2;center=CGPoint(x:max(radius,min(size.width-radius,point.x)),y:max(radius,min(size.height-radius,point.y)))}
        return ImageDrawingMark(tool:tool,points:[center],color:NSColor(color),thickness:thickness,text:text,fontSize:diameter,fontName:fontName,number:1+(marks.filter{$0.tool == .step}.map(\.number).max() ?? 0),zoom:zoom,placedImage:placedImage)
    }
    func updateSelected(){
        guard let selected,marks.indices.contains(selected) else{return}
        marks[selected].color=NSColor(color);marks[selected].thickness=thickness
        switch marks[selected].tool{
        case .text:marks[selected].text=text;marks[selected].fontSize=fontSize;marks[selected].fontName=fontName
        case .step:marks[selected].fontSize=markerDiameter
        case .magnify:marks[selected].zoom=zoom
        default:break
        }
    }
    func select(_ index:Int){
        selected=index;let mark=marks[index];color=Color(nsColor:mark.color);thickness=mark.thickness
        if mark.tool == .text{text=mark.text;fontSize=mark.fontSize;fontName=mark.fontName}
        if mark.tool == .step{markerSize=mark.fontSize*canvasScale}
        zoom=mark.zoom
    }
    func detect(text:Bool){guard let source else{return};busy=true;message="Detecting \(text ? "text":"faces")…";DispatchQueue.global(qos:.userInitiated).async{let result=Result{try ImageTools.detectedRegions(source,text:text)};DispatchQueue.main.async{self.busy=false;switch result{case .success(let boxes):self.checkpoint();self.redactions += boxes.map{ImageRedaction(rect:$0,blur:self.blur,color:NSColor(self.color))};self.message=boxes.isEmpty ? "No \(text ? "text":"faces") found.":"Added \(boxes.count) regions. Review before saving.";case .failure(let error):self.message=error.localizedDescription}}}}
    func render(previewOnly:Bool=false)throws->CGImage {
        guard let original=source else{throw UIError.message("The image has not loaded.")}
        let source=previewOnly ? (preview ?? original):original
        let factor=Double(source.width)/Double(original.width)
        let renderSize=CGSize(width:source.width,height:source.height),renderBounds=CGRect(origin:.zero,size:renderSize)
        if mode == .crop {let rect=CGRect(x:crop.minX.rounded(),y:crop.minY.rounded(),width:crop.width.rounded(),height:crop.height.rounded()).intersection(bounds);guard rect.width>=1,rect.height>=1,let image=source.cropping(to:rect) else{throw UIError.message("Choose a crop inside the image.")};return image}
        let blurred:CGImage?
        if redactions.contains(where:{$0.blur}) {blurred=try ImagePixels.blurred(source,radius:blurRadius*factor)}else{blurred=nil}
        return try ImageTools.bitmap(renderSize){cg in
            ImageTools.draw(source,in:renderBounds)
            for area in redactions {let rect=area.rect.applying(CGAffineTransform(scaleX:factor,y:factor));cg.saveGState();cg.clip(to:rect);if area.blur,let blurred{ImageTools.draw(blurred,in:renderBounds)}else{area.color.withAlphaComponent(1).setFill();rect.fill()};cg.restoreGState()}
            for mark in marks{drawImageMark(mark,source:source)}
        }
    }
    func save(destination:URL,onSave:(URL)->Void){do{let output=try ImageTools.save(render(),input:url,directory:destination,suffix:mode == .crop ? "Cropped":mode == .redact ? "Redacted":"Annotated");onSave(output)}catch{message=error.localizedDescription}}
}

@MainActor
final class ImageToolCanvas:NSView {
    var state:ImageCanvasState
    var start=CGPoint.zero
    var originalRect=CGRect.zero
    var originalMark:ImageDrawingMark?
    var handle:Int?
    var moving=false
    var drawing=false
    var cachedRedacted:CGImage?
    var redactionSignature=""
    init(state:ImageCanvasState){self.state=state;super.init(frame:.zero)}
    required init?(coder:NSCoder){fatalError()}
    override var isFlipped:Bool{true}
    override var acceptsFirstResponder:Bool{true}
    override var mouseDownCanMoveWindow:Bool{false}
    override func layout(){super.layout();state.canvasScale=scale}
    var imageRect:CGRect {let size=state.size;guard size.width>0,size.height>0 else{return .zero};let scale=min((bounds.width-20)/size.width,(bounds.height-20)/size.height);return CGRect(x:(bounds.width-size.width*scale)/2,y:(bounds.height-size.height*scale)/2,width:size.width*scale,height:size.height*scale)}
    var scale:CGFloat {imageRect.width/max(1,state.size.width)}
    func viewRect(_ rect:CGRect)->CGRect{CGRect(x:imageRect.minX+rect.minX*scale,y:imageRect.minY+rect.minY*scale,width:rect.width*scale,height:rect.height*scale)}
    func pixel(_ event:NSEvent)->CGPoint {let p=convert(event.locationInWindow,from:nil),r=imageRect;return CGPoint(x:max(0,min(state.size.width,(p.x-r.minX)/scale)),y:max(0,min(state.size.height,(p.y-r.minY)/scale)))}
    func handles(_ r:CGRect)->[CGPoint]{[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.midX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.midY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.midX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY),CGPoint(x:r.minX,y:r.midY)]}
    func drawSelection(_ rect:CGRect){let r=viewRect(rect);NSColor.systemOrange.setStroke();let path=NSBezierPath(rect:r);path.lineWidth=1.5;path.stroke();NSColor.systemOrange.setFill();for p in handles(r){NSBezierPath(roundedRect:CGRect(x:p.x-3,y:p.y-3,width:6,height:6),xRadius:1,yRadius:1).fill()}}
    override func draw(_ dirtyRect:NSRect){
        NSColor(calibratedWhite:0.015,alpha:0.9).setFill();bounds.fill()
        guard let source=state.source,let preview=state.preview else{return}
        let r=imageRect
        if state.mode == .redact {
            let signature=state.redactions.map{"\($0.rect)-\($0.blur)-\($0.color.description)"}.joined()+"\(state.blurRadius)"
            if signature != redactionSignature {cachedRedacted=try? state.render(previewOnly:true);redactionSignature=signature}
            ImageTools.draw(cachedRedacted ?? preview,in:r)
        }else{ImageTools.draw(preview,in:r)}
        if state.mode == .annotate {
            NSGraphicsContext.saveGraphicsState();let transform=NSAffineTransform();transform.translateX(by:r.minX,yBy:r.minY);transform.scale(by:scale);transform.concat();NSBezierPath(rect:state.bounds).addClip()
            for mark in state.marks{drawImageMark(mark,source:source)};if let draft=state.draft{drawImageMark(draft,source:source)};NSGraphicsContext.restoreGraphicsState()
            if let index=state.selected,state.marks.indices.contains(index){drawSelection(state.marks[index].bounds)}
        }else if state.mode == .crop {
            let hole=viewRect(state.crop),overlay=NSBezierPath(rect:r);overlay.appendRect(hole);overlay.windingRule = .evenOdd;NSColor.black.withAlphaComponent(0.5).setFill();overlay.fill();drawSelection(state.crop)
            NSColor.white.withAlphaComponent(0.25).setStroke();let grid=NSBezierPath();grid.lineWidth=0.5;for i in 1...2 {let x=hole.minX+hole.width*CGFloat(i)/3,y=hole.minY+hole.height*CGFloat(i)/3;grid.move(to:CGPoint(x:x,y:hole.minY));grid.line(to:CGPoint(x:x,y:hole.maxY));grid.move(to:CGPoint(x:hole.minX,y:y));grid.line(to:CGPoint(x:hole.maxX,y:y))};grid.stroke()
        }else if let index=state.selectedRedaction,state.redactions.indices.contains(index){drawSelection(state.redactions[index].rect)}
    }
    override func mouseDown(with event:NSEvent){
        guard state.source != nil,!state.busy,imageRect.contains(convert(event.locationInWindow,from:nil)) else{return}
        window?.makeFirstResponder(self);state.canvasScale=scale;start=pixel(event);drawing=false;moving=false;handle=nil;originalMark=nil
        let selection:CGRect?
        if state.mode == .crop {selection=state.crop}
        else if state.mode == .redact,let i=state.selectedRedaction,state.redactions.indices.contains(i){selection=state.redactions[i].rect}
        else if let i=state.selected,state.marks.indices.contains(i){selection=state.marks[i].bounds}
        else{selection=nil}
        if let selection {
            handle=handles(selection).firstIndex{hypot($0.x-start.x,$0.y-start.y)<8/scale}
            if handle != nil || selection.insetBy(dx:-3/scale,dy:-3/scale).contains(start){state.checkpoint();originalRect=selection;moving=handle==nil;if state.mode == .annotate,let i=state.selected{originalMark=state.marks[i]};return}
        }
        state.selected=nil;state.selectedRedaction=nil
        if state.mode == .annotate {
            if state.tool == .select {if let index=state.marks.lastIndex(where:{$0.bounds.insetBy(dx:-6/scale,dy:-6/scale).contains(start)}){state.select(index);state.checkpoint();originalRect=state.marks[index].bounds;originalMark=state.marks[index];moving=true};needsDisplay=true;return}
            if state.tool == .image && state.placedImage==nil{state.chooseImage();return}
            state.checkpoint();var mark=state.newMark(start)
            if [.text,.step,.magnify].contains(state.tool){if state.tool == .text{mark.points=[start,CGPoint(x:min(state.size.width,start.x+max(120,state.fontSize*6)),y:min(state.size.height,start.y+state.fontSize*2))]};state.marks.append(mark);state.selected=state.marks.count-1}
            else{state.draft=mark;drawing=true}
        }else if state.mode == .redact {
            if let i=state.redactions.lastIndex(where:{$0.rect.contains(start)}){state.selectedRedaction=i;originalRect=state.redactions[i].rect;state.checkpoint();moving=true}
            else{state.checkpoint();state.redactions.append(.init(rect:CGRect(origin:start,size:CGSize(width:1,height:1)),blur:state.blur,color:NSColor(state.color)));state.selectedRedaction=state.redactions.count-1;drawing=true}
        }else{state.checkpoint();drawing=true}
        needsDisplay=true
    }
    func changedRect(_ point:CGPoint)->CGRect {
        if moving {return CGRect(x:max(0,min(state.size.width-originalRect.width,originalRect.minX+point.x-start.x)),y:max(0,min(state.size.height-originalRect.height,originalRect.minY+point.y-start.y)),width:originalRect.width,height:originalRect.height)}
        if let handle {
            var x1=originalRect.minX,y1=originalRect.minY,x2=originalRect.maxX,y2=originalRect.maxY
            if [0,6,7].contains(handle){x1=min(point.x,x2-1)};if [2,3,4].contains(handle){x2=max(point.x,x1+1)}
            if [0,1,2].contains(handle){y1=min(point.y,y2-1)};if [4,5,6].contains(handle){y2=max(point.y,y1+1)}
            var r=CGRect(x:x1,y:y1,width:x2-x1,height:y2-y1)
            if state.mode == .crop,let ratio=state.ratio {
                if [1,5].contains(handle){r.size.width=r.height*ratio}else{r.size.height=r.width/ratio}
                if [0,1,2].contains(handle){r.origin.y=originalRect.maxY-r.height}
                if [0,6,7].contains(handle){r.origin.x=originalRect.maxX-r.width}
                if r.minX<0 || r.minY<0 || r.maxX>state.size.width || r.maxY>state.size.height{return state.crop}
            };return r
        }
        var r=CGRect(x:min(start.x,point.x),y:min(start.y,point.y),width:max(1,abs(point.x-start.x)),height:max(1,abs(point.y-start.y)))
        if state.mode == .crop,let ratio=state.ratio{r.size.height=r.width/ratio;if r.maxY>state.size.height{r.size.height=state.size.height-r.minY;r.size.width=r.height*ratio}};return r
    }
    override func mouseDragged(with event:NSEvent){
        guard moving || handle != nil || drawing else{return};let p=pixel(event)
        if state.mode == .crop{state.crop=changedRect(p);state.syncDimensions()}
        else if state.mode == .redact,let index=state.selectedRedaction{state.redactions[index].rect=changedRect(p)}
        else if let originalMark,let index=state.selected {
            let rect=changedRect(p),old=originalRect
            var mark=originalMark
            mark.points=originalMark.points.map{CGPoint(x:rect.minX+($0.x-old.minX)*rect.width/max(1,old.width),y:rect.minY+($0.y-old.minY)*rect.height/max(1,old.height))}
            if [.step,.magnify].contains(mark.tool){mark.fontSize=originalMark.fontSize*rect.width/old.width}
            state.marks[index]=mark
        }else if var mark=state.draft{
            if [.pen,.highlight].contains(mark.tool){mark.points.append(p)}else{mark.points=[start,p]};state.draft=mark
        };needsDisplay=true
    }
    override func mouseUp(with event:NSEvent){
        if let mark=state.draft,mark.points.count>1 {state.marks.append(mark);state.selected=state.marks.count-1};state.draft=nil
        if state.mode == .redact,let i=state.selectedRedaction,state.redactions.indices.contains(i),state.redactions[i].rect.width<2 || state.redactions[i].rect.height<2{state.redactions.remove(at:i);state.selectedRedaction=nil}
        moving=false;handle=nil;drawing=false;originalMark=nil;needsDisplay=true
    }
    override func keyDown(with event:NSEvent){
        if event.modifierFlags.contains(.command),event.charactersIgnoringModifiers=="z"{event.modifierFlags.contains(.shift) ? state.redo():state.undo()}
        else if event.keyCode==51 || event.keyCode==117{state.deleteSelection()}
        else if event.keyCode==53{state.selected=nil;state.selectedRedaction=nil;state.draft=nil}
        else{super.keyDown(with:event)};needsDisplay=true
    }
}
struct ImageToolCanvasView:NSViewRepresentable {
    @ObservedObject var state:ImageCanvasState
    func makeNSView(context:Context)->ImageToolCanvas{ImageToolCanvas(state:state)}
    func updateNSView(_ view:ImageToolCanvas,context:Context){view.state=state;view.needsDisplay=true}
}

struct ImageCanvasPanel:View {
    @StateObject var state:ImageCanvasState
    let destination:URL
    let onSave:(URL)->Void
    let onClose:()->Void
    init(url:URL,mode:ImageCanvasMode,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void,preview:Bool=false){_state=StateObject(wrappedValue:ImageCanvasState(url:url,mode:mode,preview:preview));self.destination=destination;self.onSave=onSave;self.onClose=onClose}
    var title:String{state.mode == .crop ? "Crop Image":state.mode == .redact ? "Redact Photo":"Annotate Photo"}
    var saveTitle:String{state.mode == .crop ? "Apply":state.mode == .redact ? "Save Redacted Copy":"Save Annotated Copy"}
    var body:some View {
        VStack(spacing:0){
            PDFToolHeader(title:title,onClose:onClose)
            ZStack {ImageToolCanvasView(state:state);if state.loading{ProgressView()}}
                .clipShape(RoundedRectangle(cornerRadius:9)).padding(10).frame(maxHeight:.infinity)
            if state.mode == .annotate{annotationControls}
            else if state.mode == .crop{cropControls}
            else{redactControls}
            Text(state.message).font(.system(size:10)).foregroundColor(.orange).frame(maxWidth:.infinity,alignment:.leading).lineLimit(2).frame(height:26).padding(.horizontal,12)
            PDFToolDivider()
            HStack{Button("Reset"){state.reset()}.buttonStyle(PDFQuietButtonStyle());Spacer();Button(saveTitle){state.save(destination:destination,onSave:onSave)}.buttonStyle(PDFOrangeButtonStyle()).disabled(state.loading || state.busy || state.source==nil || (state.mode == .redact && state.redactions.isEmpty))}.padding(.horizontal,12).frame(height:50)
        }.foregroundColor(.white.opacity(0.95)).font(.system(size:11)).tint(pdfToolOrange).preferredColorScheme(.dark).onAppear{state.load()}.onExitCommand(perform:onClose)
    }
    private var annotationControls:some View {
        VStack(alignment:.leading,spacing:9){
            HStack(spacing:3){ForEach(ImageDrawingTool.allCases,id:\.self){tool in
                Button{state.tool=tool;state.selected=nil;if tool == .highlight{state.color = .yellow};if tool == .image{state.chooseImage()}}label:{Image(systemName:tool.icon).font(.system(size:13)).frame(maxWidth:.infinity).frame(height:28).background(state.tool==tool ? pdfToolOrange:.white.opacity(0.09),in:RoundedRectangle(cornerRadius:5))}.buttonStyle(.plain).help(tool.rawValue).accessibilityLabel(tool.rawValue)
            }}
            HStack(spacing:8){
                ColorPicker("Color",selection:$state.color,supportsOpacity:false).labelsHidden().onChange(of:state.color){_ in state.updateSelected()}
                if state.tool == .text || selectedTool == .text {
                    Picker("Font",selection:$state.fontName){ForEach(["System","Helvetica","Times New Roman","Menlo","Georgia"],id:\.self){Text($0).tag($0)}}.labelsHidden().frame(width:108).onChange(of:state.fontName){_ in state.updateSelected()}
                    TextField("Size",value:$state.fontSize,format:.number).frame(width:40).onSubmit{state.fontSize=max(8,min(1000,state.fontSize));state.updateSelected()};Text("pt")
                }else if state.tool == .magnify || selectedTool == .magnify {
                    Picker("Zoom",selection:$state.zoom){ForEach([1.5,2,3,4],id:\.self){Text(String(format:"%.1g×",$0)).tag($0)}}.labelsHidden().frame(width:70).onChange(of:state.zoom){_ in state.updateSelected()}
                }else if state.tool == .step || selectedTool == .step {
                    Text("Size")
                    ImageValueSlider(value:$state.markerSize,in:16...72,step:1).frame(width:110).onChange(of:state.markerSize){_ in state.updateSelected()}.accessibilityLabel("Marker size")
                    Text("\(Int(state.markerSize)) pt").frame(width:36)
                }else{ImageValueSlider(value:$state.thickness,in:1...30).frame(width:95).onChange(of:state.thickness){_ in state.updateSelected()};Text("\(Int(state.thickness)) px").frame(width:35)}
                Spacer(minLength:0)
                Button{state.undo()}label:{Image(systemName:"arrow.uturn.backward")}.disabled(!state.canUndo).help("Undo").keyboardShortcut("z",modifiers:.command)
                Button{state.redo()}label:{Image(systemName:"arrow.uturn.forward")}.disabled(!state.canRedo).help("Redo").keyboardShortcut("z",modifiers:[.command,.shift])
                Button{state.deleteSelection()}label:{Image(systemName:"trash")}.disabled(state.selected==nil).help("Delete selected mark")
            }.buttonStyle(PDFQuietButtonStyle())
            if state.tool == .text || selectedTool == .text {TextField("Text",text:$state.text).textFieldStyle(.roundedBorder).onChange(of:state.text){_ in state.updateSelected()}}
            Text(state.tool.hint).font(.system(size:10)).foregroundColor(.white.opacity(0.65)).frame(height:30,alignment:.topLeading).fixedSize(horizontal:false,vertical:true)
        }.padding(.horizontal,10)
    }
    private var selectedTool:ImageDrawingTool?{state.selected.flatMap{state.marks.indices.contains($0) ? state.marks[$0].tool:nil}}
    private var cropControls:some View {
        VStack(spacing:10){
            HStack{Text("Aspect ratio");Spacer();Picker("Aspect ratio",selection:$state.aspect){ForEach(["Free","1:1","16:9","9:16","4:3","3:4"],id:\.self){Text($0).tag($0)}}.labelsHidden().pickerStyle(.segmented).frame(width:282).onChange(of:state.aspect){_ in state.setAspect()}}
            HStack{Text("W");TextField("Width",text:$state.widthText).frame(width:65).onSubmit{state.setDimensions(width:true)};Text("H");TextField("Height",text:$state.heightText).frame(width:65).onSubmit{state.setDimensions(width:false)};Text("px").foregroundColor(.secondary);Spacer()}.textFieldStyle(.roundedBorder)
        }.padding(.horizontal,12).padding(.vertical,7)
    }
    private var redactControls:some View {
        VStack(spacing:10){
            HStack{Text("Style");Spacer();Picker("Style",selection:$state.blur){Text("Solid").tag(false);Text("Blur").tag(true)}.labelsHidden().pickerStyle(.segmented).frame(width:115).onChange(of:state.blur){value in if let i=state.selectedRedaction,state.redactions.indices.contains(i){state.checkpoint();state.redactions[i].blur=value}}}
            if state.blur {HStack{Text("Blur");ImageValueSlider(value:$state.blurRadius,in:5...100);Text("\(Int(state.blurRadius)) px").frame(width:40)}}
            else{HStack{Text("Color");Spacer();ColorPicker("Color",selection:$state.color,supportsOpacity:false).labelsHidden().onChange(of:state.color){_ in if let i=state.selectedRedaction,state.redactions.indices.contains(i){state.redactions[i].color=NSColor(state.color)}}}}
            HStack{Text("Detect");Spacer();if state.busy{ProgressView().controlSize(.small)};Button("Faces"){state.detect(text:false)};Button("Text"){state.detect(text:true)}}.buttonStyle(PDFQuietButtonStyle()).disabled(state.busy)
            HStack{Text("Drag a rectangle over the area to hide.").font(.system(size:10)).foregroundColor(.secondary);Spacer();Button{state.undo()}label:{Image(systemName:"arrow.uturn.backward")}.disabled(!state.canUndo);Button{state.deleteSelection()}label:{Image(systemName:"trash")}.disabled(state.selectedRedaction==nil)}.buttonStyle(PDFQuietButtonStyle())
        }.padding(.horizontal,12).padding(.vertical,7)
    }
}
