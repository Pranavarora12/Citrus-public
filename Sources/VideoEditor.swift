import AppKit
import SwiftUI
import AVFoundation

struct VideoCut:Identifiable {var id=UUID();var time:Double}
struct VideoSnapshot:Identifiable {var id=UUID();var time:Double;var image:CGImage?}

@MainActor final class VideoEditorState:ObservableObject {
    let url:URL
    let operation:String
    let player=AVPlayer()
    @Published var info:VideoInfo?
    @Published var frame:CGImage?
    @Published var time=0.0
    @Published var playing=false
    @Published var loading=true
    @Published var busy=false
    @Published var message=""
    @Published var trim=VideoTimeRange(start:0,end:1)
    @Published var crop=CGRect.zero
    @Published var aspect="Free"
    @Published var speed=1.0
    @Published var layers:[VideoRedaction]=[]
    @Published var selectedLayer:UUID?
    @Published var blur=false
    @Published var color:Color = .black
    @Published var cuts:[VideoCut]=[]
    @Published var removed:Set<Int>=[]
    @Published var selectedClip:Int?
    @Published var merge=false
    @Published var snapshots:[VideoSnapshot]=[]
    private var observer:Any?
    private var frameGeneration=0
    private var frameRunning=false
    private var stopped=false
    private var job:VideoJobControl?
    private var proxy:URL?
    private var output:AVPlayerItemVideoOutput?
    var duration:Double {info?.duration ?? 1}
    var currentClip:Int {cuts.filter{$0.time<=time}.count}
    var ranges:[VideoTimeRange] {let p=[0]+cuts.map(\.time)+[duration];return (0..<p.count-1).map{.init(start:p[$0],end:p[$0+1])}}
    var kept:[VideoTimeRange] {ranges.enumerated().filter{!removed.contains($0.offset)}.map(\.element)}
    init(url:URL,operation:String){self.url=url;self.operation=operation;VideoTrace.event("editor init")
        DispatchQueue.global(qos:.userInitiated).async {
            VideoTrace.event("editor background")
            let result=Result{(try VideoTools.info(url),try VideoTools.frame(url,time:0,maxEdge:720))}
            DispatchQueue.main.async{[weak self] in
                VideoTrace.event("editor callback")
                guard let self,!self.stopped else{return};self.loading=false
                switch result{case .success(let (info,frame)):
                    self.info=info;self.frame=frame;self.trim = .init(start:0,end:info.duration);self.crop=CGRect(origin:.zero,size:info.size)
                    if operation=="videoSnapshots"{self.snapshots=[.init(time:0,image:frame)]}
                    self.preparePlayer(url)
                case .failure(let error):self.message=error.localizedDescription}
            }
        }
    }
    private func preparePlayer(_ url:URL){
        let item=AVPlayerItem(url:url);item.audioTimePitchAlgorithm = .spectral
        let videoOutput=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);item.add(videoOutput);output=videoOutput
        player.replaceCurrentItem(with:item)
        observer=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.04,preferredTimescale:600),queue:.main){[weak self] t in
          DispatchQueue.main.async {
            guard let self,!self.stopped else{return};let seconds=t.seconds;guard seconds.isFinite else{return};self.time=max(0,min(self.duration,seconds))
            if self.playing {
                if self.operation=="trimVideo",seconds>=self.trim.end-0.015{self.seek(self.trim.start);self.player.playImmediately(atRate:Float(self.speed))}
                else if self.operation=="splitVideo",self.removed.contains(self.currentClip){
                    if let next=self.ranges.enumerated().first(where:{$0.offset>self.currentClip && !self.removed.contains($0.offset)}){self.seek(next.element.start);self.player.playImmediately(atRate:1)}else{self.pause();self.seek(self.kept.first?.start ?? 0)}
                }else if seconds>=self.duration-0.035{self.pause()}
                if self.operation=="redactVideo",self.layers.contains(where:{$0.blur}){self.capturePlayerFrame()}
            }
          }
        }
        // AVFoundation cannot decode every container accepted by FFmpeg. Supply a
        // temporary playback proxy while keeping source coordinates and exports.
        Task {let playable=(try? await item.asset.load(.isPlayable)) ?? false
            if !playable && !self.stopped {self.makeProxy()}
        }
    }
    private func makeProxy(){
        guard proxy==nil else{message="This video cannot be played in the native preview. Frame scrubbing and export are available.";return}
        message="Preparing video preview…"
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent("citrus-preview-\(UUID()).mp4")
        let input=url
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result{try VideoTools.write(destination,args:["-i",input.path,"-vf","scale='min(iw,960)':'min(ih,960)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2","-c:v","libx264","-preset","ultrafast","-crf","25","-c:a","aac"])}
            DispatchQueue.main.async{[weak self] in guard let self,!self.stopped else{try? FileManager.default.removeItem(at:destination);return}
                switch result{case .success(let url):self.proxy=url;if let observer=self.observer{self.player.removeTimeObserver(observer);self.observer=nil};self.preparePlayer(url);self.message=""
                case .failure(let error):self.message=error.localizedDescription}
            }
        }
    }
    func pause(){let wasPlaying=playing;player.pause();playing=false;if wasPlaying{capturePlayerFrame();refreshFrame()}}
    func toggle(){guard info != nil else{return};if playing{pause()}else{
        if time>=duration-0.04{seek(operation=="trimVideo" ? trim.start:kept.first?.start ?? 0)}
        if operation=="trimVideo",time<trim.start || time>=trim.end{seek(trim.start)}
        if operation=="splitVideo",removed.contains(currentClip){seek(kept.first?.start ?? 0)}
        playing=true;player.playImmediately(atRate:Float(operation=="changeVideoSpeed" ? speed:1))
    }}
    func changeSpeed(_ value:Double){speed=value;if playing{player.playImmediately(atRate:Float(value))}}
    func seek(_ value:Double){time=max(0,min(duration-0.001,value));player.seek(to:CMTime(seconds:time,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero);refreshFrame()}
    func step(_ direction:Double){pause();seek(time+direction/(info?.frameRate ?? 30))}
    func refreshFrame(){frameGeneration+=1;nextFrame()}
    private func nextFrame(){guard !frameRunning,!stopped else{return};frameRunning=true;let revision=frameGeneration,t=time,url=url
        DispatchQueue.global(qos:.userInteractive).async{let result=try? VideoTools.frame(url,time:t,maxEdge:720);DispatchQueue.main.async{[weak self] in guard let self else{return};self.frameRunning=false;if let result{self.frame=result};if revision != self.frameGeneration{self.nextFrame()}}}
    }
    private func capturePlayerFrame(){guard !frameRunning,let output,output.hasNewPixelBuffer(forItemTime:player.currentTime()),let buffer=output.copyPixelBuffer(forItemTime:player.currentTime(),itemTimeForDisplay:nil) else{return}
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        if let base=CVPixelBufferGetBaseAddress(buffer),let context=CGContext(data:base,width:CVPixelBufferGetWidth(buffer),height:CVPixelBufferGetHeight(buffer),bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),let image=context.makeImage(){frame=ImageTools.scaled(image,maxEdge:720)}
    }
    func setAspect(_ name:String){guard let info else{return};aspect=name;let ratios:[String:Double]=["1:1":1,"16:9":16/9,"9:16":9/16,"4:3":4/3,"3:4":3/4]
        guard let ratio=ratios[name] else{return};let w=min(Double(info.width),Double(info.height)*ratio),h=w/ratio
        crop=CGRect(x:(Double(info.width)-w)/2,y:(Double(info.height)-h)/2,width:w,height:h)
    }
    func setCropDimension(_ value:Double,width:Bool){guard let info,value.isFinite else{return};aspect="Free";var r=crop;if width{r.size.width=max(2,min(Double(info.width)-r.minX,value))}else{r.size.height=max(2,min(Double(info.height)-r.minY,value))};crop=r}
    func addLayer(rect:CGRect,range:VideoTimeRange?=nil){guard rect.width>=2,rect.height>=2 else{return};let layer=VideoRedaction(rect:rect,range:range ?? .init(start:0,end:duration),blur:blur,color:NSColor(color));layers.append(layer);selectedLayer=layer.id}
    func addTimedLayer(_ range:VideoTimeRange){let size=info?.size ?? CGSize(width:100,height:100);addLayer(rect:CGRect(x:size.width*0.25,y:size.height*0.25,width:size.width*0.5,height:size.height*0.5),range:range);seek(range.start)}
    func updateStyle(){if let i=layers.firstIndex(where:{$0.id==selectedLayer}){layers[i].blur=blur;layers[i].color=NSColor(color)}}
    func selectLayer(_ id:UUID){selectedLayer=id;if let l=layers.first(where:{$0.id==id}){blur=l.blur;color=Color(nsColor:l.color)}}
    func addCut(){guard time>0.05,time<duration-0.05,!cuts.contains(where:{abs($0.time-time)<0.05}) else{message="Choose a split point at least 0.05 seconds from another point or an end.";return};let old=removed,index=currentClip;cuts.append(.init(time:time));cuts.sort{$0.time<$1.time};removed=Set(old.flatMap{$0<index ? [$0]:$0==index ? [$0,$0+1]:[$0+1]});message=""}
    func moveCut(_ id:UUID,to value:Double){guard let i=cuts.firstIndex(where:{$0.id==id}) else{return};let lo=i==0 ? 0:cuts[i-1].time,hi=i==cuts.count-1 ? duration:cuts[i+1].time;cuts[i].time=max(lo+0.05,min(hi-0.05,value));seek(cuts[i].time)}
    func deleteCut(_ id:UUID){guard let i=cuts.firstIndex(where:{$0.id==id}) else{return};let both=removed.contains(i) && removed.contains(i+1);removed=Set(removed.filter{$0 != i && $0 != i+1}.map{$0>i ? $0-1:$0});if both{removed.insert(i)};cuts.remove(at:i);selectedClip=nil}
    func removeSelected(){if operation=="redactVideo"{layers.removeAll{$0.id==selectedLayer};selectedLayer=nil}else if operation=="splitVideo",let selectedClip{if removed.contains(selectedClip){removed.remove(selectedClip)}else{removed.insert(selectedClip)}}}
    func addSnapshot(){guard !snapshots.contains(where:{abs($0.time-time)<0.001}) else{return};let snapshot=VideoSnapshot(time:time,image:frame);snapshots.append(snapshot);let url=url,t=time
        DispatchQueue.global(qos:.userInitiated).async{let image=try? VideoTools.frame(url,time:t,maxEdge:320);DispatchQueue.main.async{[weak self] in if let i=self?.snapshots.firstIndex(where:{$0.id==snapshot.id}){self?.snapshots[i].image=image}}}
    }
    func save(destination:URL,onSave:@escaping([URL])->Void){guard info != nil,!busy else{return};pause();busy=true;message="";let control=VideoJobControl();job=control
        let operation=operation,url=url,trim=trim,crop=crop,speed=speed,layers=layers,ranges=kept,merge=merge,times=snapshots.map(\.time)
        DispatchQueue.global(qos:.userInitiated).async{
            let result=Result{()->[URL] in switch operation{
            case "trimVideo":return [try VideoTools.trim(url,directory:destination,range:trim,control:control)]
            case "cropVideo":return [try VideoTools.crop(url,directory:destination,rect:crop,control:control)]
            case "changeVideoSpeed":return [try VideoTools.speed(url,directory:destination,multiplier:speed,control:control)]
            case "videoSnapshots":return try VideoTools.snapshots(url,directory:destination,times:times,control:control)
            case "splitVideo":return try VideoTools.split(url,directory:destination,ranges:ranges,merge:merge,control:control)
            default:return [try VideoTools.redact(url,directory:destination,layers:layers,control:control)]}}
            DispatchQueue.main.async{[weak self] in guard let self,!self.stopped else{return};self.busy=false;self.job=nil;switch result{case .success(let outputs):onSave(outputs);case .failure(let error):self.message=error.localizedDescription}}
        }
    }
    func stop(){stopped=true;pause();job?.cancel();if let observer{player.removeTimeObserver(observer);self.observer=nil};player.replaceCurrentItem(with:nil);if let proxy{try? FileManager.default.removeItem(at:proxy)}}
}

struct VideoStage:NSViewRepresentable {
    @ObservedObject var state:VideoEditorState
    func makeNSView(context:Context)->VideoPlayerSurface{let surface=VideoPlayerSurface();surface.overlay.state=state;surface.playerLayer.player=state.player;return surface}
    func updateNSView(_ surface:VideoPlayerSurface,context:Context){surface.overlay.state=state;surface.playerLayer.isHidden = !state.playing;surface.overlay.needsDisplay=true}
}
@MainActor final class VideoPlayerSurface:NSView {
    let playerLayer=AVPlayerLayer()
    let overlay=VideoStageView()
    override init(frame:NSRect){super.init(frame:frame);wantsLayer=true;layer?.backgroundColor=NSColor.black.cgColor;playerLayer.videoGravity = .resizeAspect;layer?.addSublayer(playerLayer);overlay.wantsLayer=true;addSubview(overlay)}
    required init?(coder:NSCoder){fatalError()}
    override func layout(){super.layout();CATransaction.begin();CATransaction.setDisableActions(true);playerLayer.frame=bounds;overlay.frame=bounds;CATransaction.commit()}
}
@MainActor final class VideoStageView:NSView {
    weak var state:VideoEditorState?
    private var anchor=CGPoint.zero,original=CGRect.zero,active:UUID?,handle = -1,drawing=false
    private var draft:CGRect?
    private var engaged=false
    override var isFlipped:Bool{true}
    override var acceptsFirstResponder:Bool{true}
    var fit:CGRect{guard let size=state?.info?.size else{return bounds};let scale=min(bounds.width/size.width,bounds.height/size.height);return CGRect(x:(bounds.width-size.width*scale)/2,y:(bounds.height-size.height*scale)/2,width:size.width*scale,height:size.height*scale)}
    func screen(_ r:CGRect)->CGRect{guard let s=state?.info?.size else{return r};let f=fit;return CGRect(x:f.minX+r.minX/s.width*f.width,y:f.minY+r.minY/s.height*f.height,width:r.width/s.width*f.width,height:r.height/s.height*f.height)}
    func source(_ p:CGPoint)->CGPoint{guard let size=state?.info?.size else{return p};let f=fit;return CGPoint(x:max(0,min(size.width,(p.x-f.minX)/max(1,f.width)*size.width)),y:max(0,min(size.height,(p.y-f.minY)/max(1,f.height)*size.height)))}
    func handles(_ r:CGRect)->[CGPoint]{[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.midX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.midY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.midX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY),CGPoint(x:r.minX,y:r.midY)]}
    override func draw(_ dirtyRect:NSRect){guard let s=state,let context=NSGraphicsContext.current?.cgContext else{return};let f=fit
        if !s.playing,let image=s.frame{ImageTools.draw(image,in:f)}
        if s.operation=="cropVideo"{let r=screen(s.crop);let shade=NSBezierPath(rect:bounds);shade.append(NSBezierPath(rect:r));shade.windingRule = .evenOdd;NSColor.black.withAlphaComponent(0.6).setFill();shade.fill();outline(r)}
        if s.operation=="redactVideo"{for layer in s.layers where s.time>=layer.range.start && s.time<=layer.range.end{
            let r=screen(layer.rect)
            if layer.blur,let frame=s.frame,let patch=frame.cropping(to:CGRect(x:layer.rect.minX/s.durationSafeWidth*Double(frame.width),y:layer.rect.minY/s.durationSafeHeight*Double(frame.height),width:layer.rect.width/s.durationSafeWidth*Double(frame.width),height:layer.rect.height/s.durationSafeHeight*Double(frame.height))),let blurred=try? ImagePixels.blurred(patch,radius:12){ImageTools.draw(blurred,in:r)}else{layer.color.setFill();context.fill(r)}
            if layer.id==s.selectedLayer{outline(r)}
        };if let draft{outline(screen(draft))}}
    }
    func outline(_ r:CGRect){NSColor.systemOrange.setStroke();let p=NSBezierPath(rect:r);p.lineWidth=1.5;p.stroke();for point in handles(r){NSColor.systemOrange.setFill();NSBezierPath(roundedRect:CGRect(x:point.x-3,y:point.y-3,width:6,height:6),xRadius:1,yRadius:1).fill()}}
    override func mouseDown(with event:NSEvent){guard let s=state,!s.busy,["cropVideo","redactVideo"].contains(s.operation) else{return};window?.makeFirstResponder(self);let p=convert(event.locationInWindow,from:nil);guard fit.insetBy(dx:-6,dy:-6).contains(p) else{return};engaged=true;anchor=source(p);s.pause();handle = -1;drawing=false;active=nil
        let candidates:[(UUID?,CGRect)]=s.operation=="cropVideo" ? [(nil,s.crop)]:s.layers.filter{s.time >= $0.range.start && s.time <= $0.range.end}.sorted{($0.id==s.selectedLayer ? 0:1)<($1.id==s.selectedLayer ? 0:1)}.map{(Optional($0.id),$0.rect)}
        for (id,r) in candidates{let sr=screen(r);if let h=handles(sr).firstIndex(where:{hypot($0.x-p.x,$0.y-p.y)<9}){handle=h;original=r;active=id;if let id{s.selectLayer(id)};return};if sr.contains(p){original=r;active=id;if let id{s.selectLayer(id)};return}}
        drawing=true;draft=CGRect(origin:anchor,size:.zero)
    }
    override func mouseDragged(with event:NSEvent){guard engaged,let s=state,let size=s.info?.size else{return};let p=source(convert(event.locationInWindow,from:nil));let r:CGRect
        if drawing{r=CGRect(x:min(anchor.x,p.x),y:min(anchor.y,p.y),width:abs(p.x-anchor.x),height:abs(p.y-anchor.y));draft=r}
        else if handle<0{r=CGRect(x:max(0,min(size.width-original.width,original.minX+p.x-anchor.x)),y:max(0,min(size.height-original.height,original.minY+p.y-anchor.y)),width:original.width,height:original.height)}
        else{var x1=original.minX,x2=original.maxX,y1=original.minY,y2=original.maxY
            if [0,6,7].contains(handle){x1=min(x2-2,p.x)};if [2,3,4].contains(handle){x2=max(x1+2,p.x)};if [0,1,2].contains(handle){y1=min(y2-2,p.y)};if [4,5,6].contains(handle){y2=max(y1+2,p.y)};r=CGRect(x:x1,y:y1,width:x2-x1,height:y2-y1)
        }
        if s.operation=="cropVideo"{s.aspect="Free";s.crop=r}else if !drawing,let i=s.layers.firstIndex(where:{$0.id==active}){s.layers[i].rect=r};needsDisplay=true
    }
    override func mouseUp(with event:NSEvent){if drawing,let draft,state?.operation=="redactVideo"{state?.addLayer(rect:draft)};drawing=false;engaged=false;draft=nil;needsDisplay=true}
    override func keyDown(with event:NSEvent){if event.keyCode==49{state?.toggle()}else if [51,117].contains(event.keyCode){state?.removeSelected()}else{super.keyDown(with:event)}}
}
extension VideoEditorState {var durationSafeWidth:Double{Double(info?.width ?? 1)};var durationSafeHeight:Double{Double(info?.height ?? 1)}}
