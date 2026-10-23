import SwiftUI
import AppKit
import UniformTypeIdentifiers

func videoTime(_ value:Double)->String {String(format:"%02d:%05.2f",Int(max(0,value))/60,max(0,value).truncatingRemainder(dividingBy:60))}

struct VideoRangeTimeline:View {
    var range:VideoTimeRange
    var duration:Double
    var time:Double
    var onChange:(VideoTimeRange,Double)->Void
    @State private var initial:VideoTimeRange?
    var body:some View {
        GeometryReader{g in
            let w=max(1,g.size.width),start=CGFloat(range.start/duration)*w,end=CGFloat(range.end/duration)*w
            ZStack(alignment:.leading){RoundedRectangle(cornerRadius:6).fill(.black.opacity(0.7))
                RoundedRectangle(cornerRadius:3).fill(pdfToolOrange.opacity(0.28)).overlay(RoundedRectangle(cornerRadius:3).stroke(pdfToolOrange,lineWidth:2)).frame(width:max(4,end-start)).offset(x:start)
                    .gesture(DragGesture(minimumDistance:2).onChanged{e in if initial==nil{initial=range};guard let initial else{return};let s=max(0,min(duration-initial.duration,initial.start+e.translation.width/w*duration));onChange(.init(start:s,end:s+initial.duration),s)}.onEnded{_ in initial=nil})
                Rectangle().fill(.white).frame(width:1).offset(x:CGFloat(time/duration)*w).allowsHitTesting(false)
                handle(x:start,width:w,isStart:true);handle(x:end,width:w,isStart:false)
            }.contentShape(Rectangle())
        }.frame(height:34)
    }
    private func handle(x:CGFloat,width:CGFloat,isStart:Bool)->some View {
        RoundedRectangle(cornerRadius:3).fill(pdfToolOrange).frame(width:10).overlay(Capsule().fill(.white).frame(width:2,height:12)).offset(x:max(0,min(width-10,x-5)))
            .gesture(DragGesture(minimumDistance:0).onChanged{e in
                if initial==nil{initial=range};guard let initial else{return};let value=(isStart ? initial.start:initial.end)+e.translation.width/width*duration
                var next=initial;if isStart{next.start=max(0,min(initial.end-0.05,value))}else{next.end=min(duration,max(initial.start+0.05,value))};onChange(next,isStart ? next.start:next.end)
            }.onEnded{_ in initial=nil})
            .accessibilityElement().accessibilityLabel(isStart ? "Start time":"End time").accessibilityValue(videoTime(isStart ? range.start:range.end))
            .accessibilityAdjustableAction{direction in var next=range;let delta=direction == .increment ? 0.1 : -0.1;if isStart{next.start=max(0,min(next.end-0.05,next.start+delta))}else{next.end=min(duration,max(next.start+0.05,next.end+delta))};onChange(next,isStart ? next.start:next.end)}
    }
}

struct VideoPlaybackControls:View {
    @ObservedObject var state:VideoEditorState
    var scrub=true
    var body:some View {VStack(spacing:8){
        if scrub{ImageValueSlider(value:Binding(get:{state.time},set:{state.pause();state.seek($0)}),in:0...max(0.001,state.duration-0.001),step:0.001).accessibilityLabel("Video position")}
        HStack(spacing:18){Button{state.step(-1)}label:{Image(systemName:"backward.frame.fill")}.help("Previous frame")
            Button{state.toggle()}label:{Image(systemName:state.playing ? "pause.fill":"play.fill").font(.system(size:18))}.keyboardShortcut(.space,modifiers:[]).help("Play or pause")
            Button{state.step(1)}label:{Image(systemName:"forward.frame.fill")}.help("Next frame")
            Spacer();Text("\(videoTime(state.time)) / \(videoTime(state.duration))").monospacedDigit().font(.system(size:11)).foregroundColor(.white.opacity(0.65))
        }.buttonStyle(.plain).frame(height:27)
    }}
}

struct VideoEditorPanel:View {
    @StateObject var state:VideoEditorState
    let destination:URL
    let onSave:([URL])->Void
    let onClose:()->Void
    init(operation:String,url:URL,destination:URL,onSave:@escaping([URL])->Void,onClose:@escaping()->Void){_state=StateObject(wrappedValue:VideoEditorState(url:url,operation:operation));self.destination=destination;self.onSave=onSave;self.onClose=onClose}
    var title:String {["trimVideo":"Trim Video","cropVideo":"Crop Video","changeVideoSpeed":"Change Speed","redactVideo":"Redact Video","videoSnapshots":"Snapshots","splitVideo":"Split Video"][state.operation] ?? "Video"}
    var saveTitle:String {switch state.operation{case "redactVideo":return "Save Redacted Copy";case "videoSnapshots":return "Save \(state.snapshots.count) Frame\(state.snapshots.count==1 ? "":"s")";case "splitVideo":return state.merge ? "Save Video":"Create \(state.kept.count) Clip\(state.kept.count==1 ? "":"s")";default:return "Apply"}}
    var disabled:Bool{state.info==nil || (state.operation=="redactVideo" && state.layers.isEmpty) || (state.operation=="videoSnapshots" && state.snapshots.isEmpty) || (state.operation=="splitVideo" && state.kept.isEmpty)}
    var body:some View {VStack(spacing:0){
        PDFToolHeader(title:title,onClose:{state.stop();onClose()})
        ZStack{VideoStage(state:state);if state.loading{ProgressView()}}.frame(minHeight:150,maxHeight:320).clipShape(RoundedRectangle(cornerRadius:9)).padding(10).disabled(state.busy)
        ScrollView{VStack(alignment:.leading,spacing:12){
            switch state.operation {
            case "trimVideo":trimControls
            case "cropVideo":cropControls
            case "changeVideoSpeed":speedControls
            case "redactVideo":redactionControls
            case "splitVideo":splitControls
            default:snapshotControls
            }
        }.padding(.horizontal,14).padding(.bottom,14)}.frame(maxHeight:.infinity).disabled(state.busy)
        ImagePanelFooter(message:state.message,busy:state.busy,title:saveTitle,disabled:disabled,reset:state.operation=="cropVideo" ? {if let info=state.info{state.crop=CGRect(origin:.zero,size:info.size);state.aspect="Free"}}:nil,onSave:{state.save(destination:destination){urls in state.stop();onSave(urls)}})
    }.tint(pdfToolOrange).foregroundColor(.white.opacity(0.94)).preferredColorScheme(.dark).onExitCommand{state.stop();onClose()}}
    private var trimControls:some View {VStack(alignment:.leading,spacing:14){
        HStack{Text("Drag the ends to trim").font(.system(size:12));Spacer();Text(String(format:"%.2f s",state.trim.duration)).font(.system(size:11)).monospacedDigit()}
        VideoRangeTimeline(range:state.trim,duration:state.duration,time:state.time){range,t in state.trim=range;state.pause();state.seek(t)}
        HStack{timeField("Start",value:Binding(get:{state.trim.start},set:{state.trim.start=max(0,min(state.trim.end-0.05,$0));state.seek(state.trim.start)}));Spacer();timeField("End",value:Binding(get:{state.trim.end},set:{state.trim.end=min(state.duration,max(state.trim.start+0.05,$0));state.seek(state.trim.end-0.001)}))}
        VideoPlaybackControls(state:state)
    }}
    private var cropControls:some View {VStack(alignment:.leading,spacing:12){
        HStack(spacing:5){ForEach(["Free","1:1","16:9","9:16","4:3","3:4"],id:\.self){name in Button(name){state.setAspect(name)}.buttonStyle(PDFQuietButtonStyle()).tint(state.aspect==name ? pdfToolOrange:.gray)}}
        HStack{Text("W");TextField("Width",value:Binding<Double>(get:{Double(state.crop.width)},set:{state.setCropDimension($0,width:true)}),format:.number.precision(.fractionLength(0))).frame(width:75);Text("×").foregroundColor(.secondary);Text("H");TextField("Height",value:Binding<Double>(get:{Double(state.crop.height)},set:{state.setCropDimension($0,width:false)}),format:.number.precision(.fractionLength(0))).frame(width:75);Text("px").foregroundColor(.secondary)}.font(.system(size:12)).textFieldStyle(.roundedBorder)
        VideoPlaybackControls(state:state)
        Text("Drag the rectangle or its handles to crop.").font(.system(size:11)).foregroundColor(.secondary)
    }}
    private var speedControls:some View {VStack(alignment:.leading,spacing:16){
        HStack{Text("Playback speed");Spacer();Text(String(format:"%.2g×",state.speed)).monospacedDigit().foregroundColor(pdfToolOrange)}
        VStack(spacing:3){ImageValueSlider(value:Binding(get:{speedPosition(state.speed)},set:{state.changeSpeed(speedValue($0))}),in:0...5,step:0.01).accessibilityLabel("Playback speed")
            HStack{ForEach(["0.25×","0.5×","1×","1.5×","2×","4×"],id:\.self){label in Text(label).font(.system(size:9)).frame(maxWidth:.infinity)}}.foregroundColor(.secondary)}
        VideoPlaybackControls(state:state)
    }.font(.system(size:13))}
    private var snapshotControls:some View {VStack(alignment:.leading,spacing:12){
        VideoPlaybackControls(state:state)
        HStack{Text("\(state.snapshots.count) selected").font(.system(size:12));Spacer();Button("Add Frame"){state.addSnapshot()}.buttonStyle(PDFQuietButtonStyle())}
        LazyVGrid(columns:[GridItem(.adaptive(minimum:94),spacing:8)],spacing:8){ForEach(state.snapshots){snapshot in
            ZStack(alignment:.topTrailing){Button{state.pause();state.seek(snapshot.time)}label:{VStack(spacing:3){if let image=snapshot.image{Image(decorative:image,scale:1).resizable().aspectRatio(contentMode:.fit).frame(height:66).background(.black)};Text(videoTime(snapshot.time)).font(.system(size:10)).monospacedDigit()}}.buttonStyle(.plain)
                Button{state.snapshots.removeAll{$0.id==snapshot.id}}label:{Image(systemName:"xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white,.black.opacity(0.7))}.buttonStyle(.plain).help("Remove frame")}
        }}
    }}
    private var redactionControls:some View {VStack(alignment:.leading,spacing:10){
        HStack{Picker("Style",selection:$state.blur){Text("Solid").tag(false);Text("Blur").tag(true)}.pickerStyle(.segmented).labelsHidden().onChange(of:state.blur){_ in state.updateStyle()};ColorPicker("Color",selection:$state.color,supportsOpacity:false).labelsHidden().frame(width:35).onChange(of:state.color){_ in state.updateStyle()}}
        HStack{Text("Redactions").font(.system(size:12,weight:.semibold));Spacer();Button{state.removeSelected()}label:{Image(systemName:"trash")}.buttonStyle(.plain).disabled(state.selectedLayer==nil)}
        ForEach(state.layers){layer in HStack(spacing:8){Button{state.selectLayer(layer.id);state.seek(layer.range.start)}label:{Text("\((state.layers.firstIndex(where:{$0.id==layer.id}) ?? 0)+1)").frame(width:18)}.buttonStyle(.plain)
            VideoRangeTimeline(range:layer.range,duration:state.duration,time:state.time){range,t in if let i=state.layers.firstIndex(where:{$0.id==layer.id}){state.layers[i].range=range;state.selectLayer(layer.id);state.pause();state.seek(min(t,state.duration-0.001))}}
        }.padding(4).background(RoundedRectangle(cornerRadius:6).fill(layer.id==state.selectedLayer ? .white.opacity(0.1):.clear))}
        VideoNewLayerTimeline(duration:state.duration){state.addTimedLayer($0)}
        Text("Draw a rectangle on the video. Drag its timeline ends to set when it appears.").font(.system(size:10)).foregroundColor(.secondary)
        if let id=state.selectedLayer,let layer=state.layers.first(where:{$0.id==id}){HStack{Text("\(videoTime(layer.range.start)) – \(videoTime(layer.range.end))").font(.system(size:10)).monospacedDigit();Spacer();Button("Whole Video"){if let i=state.layers.firstIndex(where:{$0.id==id}){state.layers[i].range = .init(start:0,end:state.duration)}}.buttonStyle(PDFQuietButtonStyle())}}
        VideoPlaybackControls(state:state)
    }}
    private var splitControls:some View {VStack(alignment:.leading,spacing:10){
        HStack{Text("\(state.cuts.count) split point\(state.cuts.count==1 ? "":"s")").font(.system(size:12));Spacer();Button("Add Split"){state.addCut()}.buttonStyle(PDFQuietButtonStyle())}
        VideoSplitTimeline(state:state)
        VideoPlaybackControls(state:state,scrub:true)
        Text("Select a clip, then press Delete to remove or restore it. Space plays the kept clips.").font(.system(size:10)).foregroundColor(.secondary)
        ForEach(state.cuts){cut in HStack{Text("Split \((state.cuts.firstIndex(where:{$0.id==cut.id}) ?? 0)+1)");Spacer();TextField("Seconds",value:Binding(get:{state.cuts.first(where:{$0.id==cut.id})?.time ?? 0},set:{state.moveCut(cut.id,to:$0)}),format:.number.precision(.fractionLength(2))).frame(width:64).textFieldStyle(.roundedBorder);Text("s").foregroundColor(.secondary);Button{state.seek(cut.time)}label:{Image(systemName:"eye")}.help("Preview split");Button{state.deleteCut(cut.id)}label:{Image(systemName:"trash")}.help("Delete split")}.font(.system(size:11)).buttonStyle(.plain)}
        if let selected=state.selectedClip{Button(state.removed.contains(selected) ? "Restore Selected Clip":"Remove Selected Clip"){state.removeSelected()}.buttonStyle(PDFQuietButtonStyle()).keyboardShortcut(.delete,modifiers:[])}
        Picker("Export",selection:$state.merge){Text("Separate Clips").tag(false);Text("One Video").tag(true)}.pickerStyle(.segmented).labelsHidden()
    }}
    private func timeField(_ title:String,value:Binding<Double>)->some View {HStack(spacing:5){Text(title).foregroundColor(.secondary);TextField(title,value:value,format:.number.precision(.fractionLength(2))).frame(width:66).textFieldStyle(.roundedBorder);Text("s").foregroundColor(.secondary)}.font(.system(size:11))}
    private func speedValue(_ p:Double)->Double{let values=[0.25,0.5,1,1.5,2,4],i=min(4,max(0,Int(p)));return values[i]+(values[i+1]-values[i])*(p-Double(i))}
    private func speedPosition(_ v:Double)->Double{let values=[0.25,0.5,1,1.5,2,4];for i in 0..<5 where v<=values[i+1]{return Double(i)+(v-values[i])/(values[i+1]-values[i])};return 5}
}

struct VideoNewLayerTimeline:View {
    let duration:Double
    var onAdd:(VideoTimeRange)->Void
    @State private var start:Double?
    var body:some View {GeometryReader{g in ZStack{RoundedRectangle(cornerRadius:5).fill(.black.opacity(0.45));Text("Drag to add").font(.system(size:10)).foregroundColor(.secondary)}.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:3).onChanged{e in if start==nil{start=max(0,min(duration,e.startLocation.x/g.size.width*duration))}}.onEnded{e in if let start{let end=max(0,min(duration,e.location.x/g.size.width*duration));if abs(start-end)>=0.05{onAdd(.init(start:min(start,end),end:max(start,end)))}};start=nil})}.frame(height:30)}
}
struct VideoSplitTimeline:View {
    @ObservedObject var state:VideoEditorState
    @State private var initial:Double?
    var body:some View {GeometryReader{g in ZStack(alignment:.leading){RoundedRectangle(cornerRadius:5).fill(.black.opacity(0.7))
        ForEach(Array(state.ranges.enumerated()),id:\.offset){index,range in Rectangle().fill(state.removed.contains(index) ? .white.opacity(0.07):state.selectedClip==index ? pdfToolOrange.opacity(0.5):pdfToolOrange.opacity(0.22)).overlay(Rectangle().stroke(.white.opacity(0.15),lineWidth:1)).frame(width:max(1,range.duration/state.duration*g.size.width)).offset(x:range.start/state.duration*g.size.width).onTapGesture{state.selectedClip=index;state.pause();state.seek(range.start)}}
        ForEach(state.cuts){cut in RoundedRectangle(cornerRadius:2).fill(pdfToolOrange).frame(width:7).offset(x:cut.time/state.duration*g.size.width-3.5).gesture(DragGesture(minimumDistance:0).onChanged{e in if initial==nil{initial=cut.time};state.moveCut(cut.id,to:(initial ?? cut.time)+e.translation.width/g.size.width*state.duration)}.onEnded{_ in initial=nil})}
        Rectangle().fill(.white).frame(width:1).offset(x:state.time/state.duration*g.size.width).allowsHitTesting(false)
    }}.frame(height:40).onDeleteCommand{state.removeSelected()}}
}

@MainActor final class VideoUtilityState:ObservableObject {
    @Published var inputs:[URL]
    @Published var info:VideoInfo?
    @Published var fields:[VideoMetadataField]=[]
    @Published var message=""
    @Published var busy=false
    @Published var loading=true
    @Published var mode="preset"
    @Published var preset="balanced"
    @Published var reduction=50.0
    @Published var targetSize=1.0
    @Published var unit="MB"
    @Published var search=""
    @Published var removeAll=false
    private var stopped=false
    private var control:VideoJobControl?
    private var addedAccess:[FolderAccessStore.Lease]=[]
    init(inputs:[URL]){self.inputs=inputs;guard let first=inputs.first else{loading=false;return};DispatchQueue.global(qos:.userInitiated).async{let result=Result{try VideoTools.info(first)};DispatchQueue.main.async{[weak self] in guard let self,!self.stopped else{return};self.loading=false;switch result{case .success(let info):self.info=info;self.fields=info.tags;self.targetSize=max(0.001,Double(info.bytes)/2_000_000);case .failure(let error):self.message=error.localizedDescription}}}}
    func stop(){stopped=true;control?.cancel();addedAccess.forEach{$0.close()};addedAccess=[]}
    func addFiles(){let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=true;panel.allowedContentTypes=VideoTools.extensions.compactMap{UTType(filenameExtension:$0)};guard panel.runModal() == .OK else{return};let urls=panel.urls;addedAccess.append(FolderAccessStore.Lease(entries:[],files:urls));inputs += urls}
    func move(_ index:Int,by delta:Int){let next=index+delta;guard inputs.indices.contains(next) else{return};inputs.swapAt(index,next)}
    func save(operation:String,destination:URL,onSave:@escaping([URL])->Void){guard !busy,!inputs.isEmpty else{return};busy=true;message="";let control=VideoJobControl();self.control=control
        let inputs=inputs,fields=fields,removeAll=removeAll,mode=mode,preset=preset,reduction=reduction,targetSize=targetSize,unit=unit
        DispatchQueue.global(qos:.userInitiated).async{let result=Result{()->[URL] in switch operation{case "joinVideos":return [try VideoTools.join(inputs,directory:destination,control:control)];case "removeMetadata":return [try VideoTools.metadata(inputs[0],directory:destination,fields:fields,removeAll:removeAll,control:control)];default:return [try VideoTools.compress(inputs[0],directory:destination,mode:mode,preset:preset,reduction:reduction,targetSize:targetSize,unit:unit,control:control)]}}
            DispatchQueue.main.async{[weak self] in guard let self,!self.stopped else{return};self.busy=false;self.control=nil;switch result{case .success(let urls):onSave(urls);case .failure(let error):self.message=error.localizedDescription}}
        }
    }
}
struct VideoUtilityPanel:View {
    @StateObject var state:VideoUtilityState
    let operation:String
    let destination:URL
    let onSave:([URL])->Void
    let onClose:()->Void
    init(operation:String,inputs:[URL],destination:URL,onSave:@escaping([URL])->Void,onClose:@escaping()->Void){_state=StateObject(wrappedValue:VideoUtilityState(inputs:inputs));self.operation=operation;self.destination=destination;self.onSave=onSave;self.onClose=onClose}
    var title:String {operation=="removeMetadata" ? "Metadata":operation=="joinVideos" ? "Join Videos":"Compress"}
    var body:some View {VStack(spacing:0){
        PDFToolHeader(title:title,onClose:{state.stop();onClose()})
        if operation != "joinVideos"{VStack(spacing:5){Text(state.inputs.first?.lastPathComponent ?? "").font(.system(size:12,weight:.semibold)).lineLimit(1).truncationMode(.middle);if let info=state.info{Text("Original: \(ByteCountFormatter.string(fromByteCount:Int64(info.bytes),countStyle:.file))").font(.system(size:11)).foregroundColor(.secondary)}}.padding(14)}
        if state.loading{ProgressView().padding()}
        ScrollView{Group{if operation=="removeMetadata"{metadataControls}else if operation=="joinVideos"{joinControls}else{compressControls}}.padding(.horizontal,14).padding(.bottom,12)}.frame(maxHeight:.infinity).disabled(state.busy)
        ImagePanelFooter(message:state.message,busy:state.busy,title:operation=="removeMetadata" ? "Save":operation=="joinVideos" ? "Join Videos":"Compress",disabled:state.info==nil || (operation=="joinVideos" && state.inputs.count<2),onSave:{state.save(operation:operation,destination:destination){urls in state.stop();onSave(urls)}})
    }.tint(pdfToolOrange).foregroundColor(.white.opacity(0.94)).preferredColorScheme(.dark).onExitCommand{state.stop();onClose()}}
    private var compressControls:some View {VStack(alignment:.leading,spacing:17){
        Picker("Compression mode",selection:$state.mode){Text("Preset").tag("preset");Text("File Size").tag("fileSize");Text("Percentage").tag("percentage")}.pickerStyle(.segmented).labelsHidden()
        if state.mode=="preset"{Picker("Strength",selection:$state.preset){Text("Balanced").tag("balanced");Text("Strong").tag("strong")}.pickerStyle(.segmented).labelsHidden();Text(state.preset=="strong" ? "Smaller files with more quality loss.":"A balance of file size and quality.").font(.system(size:11)).foregroundColor(.secondary)}
        else if state.mode=="fileSize"{HStack{TextField("Target size",value:$state.targetSize,format:.number).textFieldStyle(.roundedBorder);Picker("Unit",selection:$state.unit){ForEach(["KB","MB","GB"],id:\.self){Text($0).tag($0)}}.labelsHidden().frame(width:75)};Text("Choose the maximum size for the compressed copy.").font(.system(size:11)).foregroundColor(.secondary)}
        else{HStack{Text("Reduce by");Spacer();Text("\(Int(state.reduction))%").monospacedDigit()};ImageValueSlider(value:$state.reduction,in:1...99,step:1).accessibilityLabel("Reduce file size by percent");if let info=state.info{Text("Maximum: \(ByteCountFormatter.string(fromByteCount:Int64(Double(info.bytes)*(1-state.reduction/100)),countStyle:.file))").font(.system(size:11)).foregroundColor(.secondary)}}
    }.font(.system(size:12))}
    private var metadataControls:some View {VStack(alignment:.leading,spacing:10){
        HStack{Image(systemName:"magnifyingglass").foregroundColor(.secondary);TextField("Search metadata",text:$state.search).textFieldStyle(.plain)}.padding(8).background(RoundedRectangle(cornerRadius:6).fill(.black.opacity(0.2)))
        HStack{Text("\(state.fields.filter{!$0.removed}.count) fields").font(.system(size:11)).foregroundColor(.secondary);Spacer();Button("Remove All"){state.removeAll=true;for i in state.fields.indices{state.fields[i].removed=true}}.buttonStyle(PDFQuietButtonStyle());Button("Reset"){state.fields=state.info?.tags ?? [];state.removeAll=false}.buttonStyle(PDFQuietButtonStyle())}
        ForEach(Array(Set(state.fields.map(\.group))).sorted(),id:\.self){group in
            Text(group).font(.system(size:11,weight:.semibold)).foregroundColor(.secondary).padding(.top,6)
            ForEach(state.fields.indices.filter{state.fields[$0].group==group && !state.fields[$0].removed && (state.search.isEmpty || "\(state.fields[$0].key) \(state.fields[$0].value)".localizedCaseInsensitiveContains(state.search))},id:\.self){i in
                HStack(alignment:.top,spacing:8){Text(state.fields[i].label).font(.system(size:10)).foregroundColor(.secondary).frame(width:100,alignment:.leading).padding(.top,5)
                    TextField("Value",text:Binding(get:{state.fields[i].value},set:{state.fields[i].value=$0;state.fields[i].edited=true;state.removeAll=false})).font(.system(size:11)).textFieldStyle(.roundedBorder)
                    Button{state.fields[i].removed=true}label:{Image(systemName:"minus.circle.fill").foregroundColor(.secondary)}.buttonStyle(.plain).padding(.top,5)
                }
            }
        }
        if state.removeAll{Text("Personal tags and timecode will be removed. The container may generate technical fields such as codec and handler names.").font(.system(size:10)).foregroundColor(.secondary)}
    }}
    private var joinControls:some View {VStack(alignment:.leading,spacing:12){Text("Videos play in this order.").font(.system(size:12)).foregroundColor(.secondary)
        ForEach(Array(state.inputs.enumerated()),id:\.offset){i,url in HStack{Text("\(i+1)").foregroundColor(.secondary);Text(url.lastPathComponent).font(.system(size:11)).lineLimit(1).truncationMode(.middle);Spacer();Button{state.move(i,by:-1)}label:{Image(systemName:"arrow.up")}.disabled(i==0);Button{state.move(i,by:1)}label:{Image(systemName:"arrow.down")}.disabled(i==state.inputs.count-1);Button{state.inputs.remove(at:i)}label:{Image(systemName:"trash")}}.buttonStyle(.plain).padding(8).background(RoundedRectangle(cornerRadius:6).fill(.black.opacity(0.15)))}
        Button("Add Videos"){state.addFiles()}.buttonStyle(PDFQuietButtonStyle())
    }}
}

@MainActor func videoToolContent(operation:String,inputs:[URL],destination:URL,onSave:@escaping([URL])->Void,onClose:@escaping()->Void)->(AnyView,NSSize){
    let requested:NSSize
    let content:AnyView
    if ["compress","removeMetadata","joinVideos"].contains(operation){requested=NSSize(width:operation=="removeMetadata" ? 480:operation=="joinVideos" ? 460:376,height:operation=="compress" ? 376:540);content=AnyView(VideoUtilityPanel(operation:operation,inputs:inputs,destination:destination,onSave:onSave,onClose:onClose))}
    else{requested=NSSize(width:400,height:["splitVideo","redactVideo"].contains(operation) ? 800:680);content=AnyView(VideoEditorPanel(operation:operation,url:inputs[0],destination:destination,onSave:onSave,onClose:onClose))}
    let size=imageToolPanelSize(requested,visibleFrame:NSScreen.main?.visibleFrame)
    return (AnyView(content.frame(width:size.width,height:size.height)),size)
}
