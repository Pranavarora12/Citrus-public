import SwiftUI
import AppKit

@MainActor
final class ImagePreviewState:ObservableObject {
    let url:URL
    @Published var source:CGImage?
    @Published var display:CGImage?
    @Published var loading=true
    @Published var busy=false
    @Published var message=""
    @Published var values:[String:Double]=[:]
    @Published var background=ImageBackground()
    @Published var zoom=1.0
    @Published var original=false
    private let previewQueue=DispatchQueue(label:"local.citrus.image-preview",qos:.userInteractive)
    private var previewSource:CGImage?
    private var previewRunning=false
    private var backgroundPreview=false
    private(set) var generation=0
    private var started=false
    init(url:URL,preview:Bool=false,renderBackground:Bool=false){
        self.url=url;backgroundPreview=renderBackground
        if preview{
            do{let image=try ImageTools.load(url);source=image;previewSource=ImageTools.scaled(image,maxEdge:720);display=previewSource;loading=false}
            catch{message=error.localizedDescription;loading=false}
        }else{load(background:renderBackground)}
    }
    func load(background:Bool=false){
        guard loading,!started else{return};started=true;backgroundPreview=background
        DispatchQueue.global(qos:.userInitiated).async{
            let result=Result{let image=try ImageTools.load(self.url);return (image,ImageTools.scaled(image,maxEdge:720))}
            DispatchQueue.main.async{
                self.loading=false
                switch result{
                case .success(let (image,thumbnail)):self.source=image;self.previewSource=thumbnail;self.display=thumbnail;self.refresh(background:background)
                case .failure(let error):self.message=error.localizedDescription
                }
            }
        }
    }
    /// Render immediately, then coalesce new slider values into the next frame.
    /// Continuous dragging must not keep cancelling every frame until mouse-up.
    func refresh(background:Bool=false){
        generation+=1;backgroundPreview=background
        if !background{original=false}
        renderNextPreview()
    }
    private func renderNextPreview(){
        guard !previewRunning,let source,let thumbnail=previewSource else{return}
        previewRunning=true
        let revision=generation,values=values,renderBackground=backgroundPreview
        var settings=background
        let scale=Double(thumbnail.width)/Double(source.width)
        settings.padding *= scale;settings.corners *= scale;settings.shadow *= scale
        if let custom=settings.image{settings.image=ImageTools.scaled(custom,maxEdge:1000)}
        previewQueue.async{
            let result=Result{renderBackground ? try ImageTools.background(thumbnail,settings:settings):try ImageTools.adjusted(thumbnail,values:values)}
            DispatchQueue.main.async{
                self.previewRunning=false
                switch result{case .success(let image):self.display=image;self.message="";case .failure(let error):self.message=error.localizedDescription}
                if revision != self.generation{self.renderNextPreview()}
            }
        }
    }
    func save(background:Bool,destination:URL,onSave:@escaping(URL)->Void){
        guard let source else{return};busy=true;message="";let settings=self.background,values=values
        DispatchQueue.global(qos:.userInitiated).async{let result=Result{let image=background ? try ImageTools.background(source,settings:settings):try ImageTools.adjusted(source,values:values);return try ImageTools.save(image,input:self.url,directory:destination,suffix:background ? "Background":"Edited")};DispatchQueue.main.async{self.busy=false;switch result{case .success(let output):onSave(output);case .failure(let error):self.message=error.localizedDescription}}}
    }
}

struct ImageAdjustPanel:View {
    @StateObject var state:ImagePreviewState
    let destination:URL
    let onSave:(URL)->Void
    let onClose:()->Void
    init(url:URL,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void,preview:Bool=false){_state=StateObject(wrappedValue:ImagePreviewState(url:url,preview:preview));self.destination=destination;self.onSave=onSave;self.onClose=onClose}
    var body:some View {
        VStack(spacing:0){
            PDFToolHeader(title:"Edit Photo",onClose:onClose)
            ZStack(alignment:.top){
                ImagePreviewImage(image:state.original ? state.source:state.display,zoom:state.zoom).frame(height:282)
                HStack(spacing:6){Button{state.zoom=max(0.25,state.zoom/1.25)}label:{Image(systemName:"minus.magnifyingglass")};Text("\(Int(state.zoom*100))%").monospacedDigit();Button{state.zoom=min(8,state.zoom*1.25)}label:{Image(systemName:"plus.magnifyingglass")};Spacer();Button("Reset"){state.values=[:];state.refresh()};Button(state.original ? "Edited":"Original"){state.original.toggle()}}.buttonStyle(PDFQuietButtonStyle()).padding(7)
                if state.loading{ProgressView().frame(maxHeight:.infinity)}
            }.clipShape(RoundedRectangle(cornerRadius:9)).padding(10)
            ScrollView{
                VStack(alignment:.leading,spacing:5){ForEach(["Light","Color","Detail","Effects"],id:\.self){section in
                    Text(section).font(.system(size:11,weight:.semibold)).foregroundColor(.white.opacity(0.65)).padding(.top,8)
                    ForEach(ImageAdjustment.all.filter{$0.section==section}){adjustment in
                        HStack(spacing:7){
                            Text(adjustment.label).frame(width:94,alignment:.leading)
                            ImageValueSlider(value:Binding(get:{state.values[adjustment.id] ?? 0},set:{state.values[adjustment.id]=$0;state.refresh()}),in:adjustment.range)
                            Text(valueLabel(adjustment)).monospacedDigit().foregroundColor(.white.opacity(0.65)).frame(width:48,alignment:.trailing)
                            Button{state.values[adjustment.id]=0;state.refresh()}label:{Image(systemName:"arrow.counterclockwise").foregroundColor(.white.opacity(0.5))}.buttonStyle(.plain).help("Reset \(adjustment.label)").frame(width:16)
                        }.font(.system(size:10)).frame(height:19)
                    }
                }}.padding(.horizontal,12).padding(.bottom,12)
            }
            ImagePanelFooter(message:state.message,busy:state.busy,title:"Save Edited Copy",disabled:state.source==nil,onSave:{state.save(background:false,destination:destination,onSave:onSave)})
        }.tint(pdfToolOrange).foregroundColor(.white.opacity(0.94)).preferredColorScheme(.dark).disabled(state.busy).onAppear{state.load()}.onExitCommand(perform:onClose)
    }
    private func valueLabel(_ adjustment:ImageAdjustment)->String{let value=state.values[adjustment.id] ?? 0;if adjustment.id=="exposure"{return String(format:"%.2f EV",value)};return String(format:"%+.0f%@",value,adjustment.id=="hue" ? "°":"")}
}

struct ImagePreviewImage:View {
    let image:CGImage?
    var zoom=1.0
    var body:some View {
        GeometryReader{g in
            ZStack{Color.black.opacity(0.9);if let image {
                let size=CGSize(width:image.width,height:image.height),scale=min(g.size.width/size.width,g.size.height/size.height)
                ScrollView([.horizontal,.vertical]){Image(decorative:image,scale:1).resizable().interpolation(.high).frame(width:size.width*scale*zoom,height:size.height*scale*zoom).frame(minWidth:g.size.width,minHeight:g.size.height)}
            }}.clipped()
        }
    }
}
struct ImagePanelFooter:View {
    var message:String
    var busy:Bool
    var title:String
    var disabled=false
    var reset:(()->Void)?=nil
    var onSave:()->Void
    var body:some View {
        VStack(spacing:0){
            if !message.isEmpty{Text(message).font(.system(size:10)).foregroundColor(.orange).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.bottom,6).fixedSize(horizontal:false,vertical:true)}
            PDFToolDivider()
            HStack{if let reset{Button("Reset",action:reset).buttonStyle(PDFQuietButtonStyle())};Spacer();if busy{ProgressView().controlSize(.small)};Button(title,action:onSave).buttonStyle(PDFOrangeButtonStyle()).disabled(disabled || busy)}.padding(.horizontal,12).frame(height:50)
        }.fixedSize(horizontal:false,vertical:true).layoutPriority(1)
    }
}

struct ImageBackgroundPanel:View {
    @StateObject var state:ImagePreviewState
    let destination:URL
    let onSave:(URL)->Void
    let onClose:()->Void
    @State private var color:Color = .blue
    init(url:URL,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void,preview:Bool=false){let value=ImagePreviewState(url:url,preview:preview,renderBackground:true);if preview,let source=value.source{
            let thumbnail=ImageTools.scaled(source,maxEdge:1200),scale=Double(min(source.width,1200))/Double(source.width)
            var settings=value.background;settings.padding *= scale;settings.corners *= scale;settings.shadow *= scale
            value.display=(try? ImageTools.background(thumbnail,settings:settings)) ?? thumbnail
        };_state=StateObject(wrappedValue:value);self.destination=destination;self.onSave=onSave;self.onClose=onClose}
    var body:some View {
        VStack(spacing:0){
            PDFToolHeader(title:"Add BG",onClose:onClose)
            ImagePreviewImage(image:state.display).clipShape(RoundedRectangle(cornerRadius:9)).padding(10).frame(maxHeight:.infinity)
            VStack(alignment:.leading,spacing:10){
                HStack(alignment:.top,spacing:9){Text("Background").font(.system(size:10)).frame(width:69,alignment:.leading).padding(.top,6)
                    VStack(spacing:6){
                        HStack(spacing:5){ForEach(0..<ImageBackground.gradients.count,id:\.self){index in swatch(index:index){LinearGradient(colors:ImageBackground.gradients[index].map{Color(nsColor:$0)},startPoint:.topLeading,endPoint:.bottomTrailing)}};Button(action:chooseBackground){Image(systemName:"photo.badge.plus").frame(width:24,height:24).background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:5))}.buttonStyle(.plain).help("Choose background image")}
                        HStack(spacing:5){ForEach(Array(ImageBackground.solids.enumerated()),id:\.offset){index,solid in swatch(index:100+index){Color(nsColor:solid)}};ColorPicker("Custom background",selection:$color,supportsOpacity:false).labelsHidden().frame(width:28).onChange(of:color){value in state.background.color=NSColor(value);state.background.preset = -1;state.refresh(background:true)}}
                    }
                }
                backgroundSlider("Padding",keyPath:\.padding,range:0...1000)
                backgroundSlider("Corners",keyPath:\.corners,range:0...300)
                backgroundSlider("Shadow",keyPath:\.shadow,range:0...150)
                HStack{Text("Ratio").font(.system(size:10));Spacer();Picker("Ratio",selection:$state.background.ratio){ForEach(["Auto","1:1","16:9","4:5"],id:\.self){Text($0).tag($0)}}.labelsHidden().pickerStyle(.segmented).frame(width:205).onChange(of:state.background.ratio){_ in state.refresh(background:true)}}
            }.padding(12)
            ImagePanelFooter(message:state.message,busy:state.busy,title:"Save with Background",disabled:state.source==nil,reset:{state.background=ImageBackground();state.refresh(background:true)},onSave:{state.save(background:true,destination:destination,onSave:onSave)})
        }.tint(pdfToolOrange).foregroundColor(.white.opacity(0.94)).preferredColorScheme(.dark).disabled(state.busy).onAppear{state.load(background:true)}.onExitCommand(perform:onClose)
    }
    private func swatch<Content:View>(index:Int,@ViewBuilder content:()->Content)->some View {
        Button{if index>=100{state.background.preset = -1;state.background.color=ImageBackground.solids[index-100]}else{state.background.preset=index};state.refresh(background:true)}label:{content().frame(maxWidth:.infinity).frame(height:24).clipShape(RoundedRectangle(cornerRadius:5)).overlay(RoundedRectangle(cornerRadius:5).strokeBorder(state.background.preset==index ? pdfToolOrange:.white.opacity(0.14),lineWidth:state.background.preset==index ? 2:0.5))}.buttonStyle(.plain).help(index>=100 ? "Solid background \(index-99)":"Gradient \(index+1)")
    }
    private func backgroundSlider(_ label:String,keyPath:WritableKeyPath<ImageBackground,Double>,range:ClosedRange<Double>)->some View {HStack{Text(label).font(.system(size:10)).frame(width:69,alignment:.leading);ImageValueSlider(value:Binding(get:{state.background[keyPath:keyPath]},set:{state.background[keyPath:keyPath]=$0;state.refresh(background:true)}),in:range);Text("\(Int(state.background[keyPath:keyPath])) px").font(.system(size:10)).monospacedDigit().frame(width:48,alignment:.trailing)}}
    private func chooseBackground(){let panel=NSOpenPanel();panel.allowedContentTypes=[.image];guard panel.runModal() == .OK,let url=panel.url else{return};do{state.background.image=try ImageTools.load(url);state.background.preset = -2;state.refresh(background:true)}catch{state.message=error.localizedDescription}}
}

struct ImageCompressPanel:View {
    let url:URL
    let destination:URL
    let onSave:(URL)->Void
    let onClose:()->Void
    @State private var mode="percentage"
    @State private var preset="balanced"
    @State private var percentage=50.0
    @State private var target="1"
    @State private var unit="MB"
    @State private var bytes=0
    @State private var busy=false
    @State private var message=""
    init(url:URL,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void,preview:Bool=false){self.url=url;self.destination=destination;self.onSave=onSave;self.onClose=onClose;_bytes=State(initialValue:(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
    private var targetBytes:Int?{if mode=="percentage"{return Int(Double(bytes)*(1-percentage/100))};if mode=="fileSize",let size=Double(target),size.isFinite,size>0,size<=1000{return Int(size*(unit=="MB" ? 1_000_000:1000))};return nil}
    var body:some View {
        VStack(spacing:0){
            PDFToolHeader(title:"Compress",onClose:onClose)
            VStack(alignment:.leading,spacing:0){
                Text(url.lastPathComponent).font(.system(size:10)).foregroundColor(.white.opacity(0.65)).lineLimit(1).padding(.top,10)
                Text("Original size: \(ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file))").font(.system(size:12,weight:.semibold)).padding(.vertical,18)
                PDFToolDivider()
                HStack{Text("Mode").font(.system(size:10));Spacer();Picker("Mode",selection:$mode){Text("Preset").tag("preset");Text("File Size").tag("fileSize");Text("Percentage").tag("percentage")}.labelsHidden().frame(width:125)}.frame(height:52)
                PDFToolDivider()
                if mode=="percentage" {HStack{Text("Reduce by").font(.system(size:11,weight:.semibold));ImageValueSlider(value:$percentage,in:1...99,step:1);Text("\(Int(percentage))%").font(.system(size:11)).monospacedDigit().frame(width:34)}.padding(.top,18)}
                else if mode=="fileSize" {HStack{Text("Maximum size").font(.system(size:11));Spacer();TextField("Size",text:$target).textFieldStyle(.roundedBorder).frame(width:70);Picker("Unit",selection:$unit){Text("KB").tag("KB");Text("MB").tag("MB")}.labelsHidden().frame(width:65)}.padding(.top,18)}
                else{Picker("Quality",selection:$preset){Text("Small").tag("small");Text("Balanced").tag("balanced");Text("High Quality").tag("high")}.labelsHidden().pickerStyle(.segmented).padding(.top,18)}
                if let targetBytes{Text("Output will be at most \(ByteCountFormatter.string(fromByteCount:Int64(targetBytes),countStyle:.file)).").font(.system(size:10)).foregroundColor(.white.opacity(0.65)).padding(.top,8)}
                Text("Saves JPEG, or PNG for transparency. Small targets may reduce image dimensions.").font(.system(size:9)).foregroundColor(.white.opacity(0.5)).padding(.top,12).fixedSize(horizontal:false,vertical:true)
                Spacer()
            }.padding(.horizontal,12).disabled(busy)
            ImagePanelFooter(message:message,busy:busy,title:"Compress",disabled:bytes==0,onSave:compress)
        }.tint(pdfToolOrange).foregroundColor(.white.opacity(0.94)).preferredColorScheme(.dark).onAppear{bytes=(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0}.onExitCommand(perform:onClose)
    }
    private func compress(){busy=true;message="";let mode=mode,preset=preset,reduction=percentage,size=Double(target) ?? 0,unit=unit;DispatchQueue.global(qos:.userInitiated).async{let result=Result{try ImageTools.compress(url,directory:destination,mode:mode,preset:preset,reduction:reduction,size:size,unit:unit)};DispatchQueue.main.async{busy=false;switch result{case .success(let output):onSave(output);case .failure(let error):message=error.localizedDescription}}}}
}

struct ImageMetadataPanel:View {
    let url:URL
    let destination:URL
    let onSave:(URL)->Void
    let onClose:()->Void
    @State private var fields:[ImageMetadataField]=[]
    @State private var search=""
    @State private var loading=true
    @State private var busy=false
    @State private var removeAll=false
    @State private var message=""
    init(url:URL,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void,preview:Bool=false){self.url=url;self.destination=destination;self.onSave=onSave;self.onClose=onClose;_loading=State(initialValue:false);do{_fields=State(initialValue:try ImageTools.metadata(url))}catch{_message=State(initialValue:error.localizedDescription)}}
    private var indices:[Int]{fields.indices.filter{!fields[$0].removed && (search.isEmpty || fields[$0].label.localizedCaseInsensitiveContains(search) || fields[$0].group.localizedCaseInsensitiveContains(search) || fields[$0].value.localizedCaseInsensitiveContains(search))}}
    var body:some View {
        VStack(spacing:0){
            PDFToolHeader(title:"Metadata",onClose:onClose)
            HStack{Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundColor(.secondary);Spacer();TextField("Search metadata",text:$search).textFieldStyle(.roundedBorder).frame(width:165)}.font(.system(size:10)).padding(12)
            ScrollView{
                LazyVStack(alignment:.leading,spacing:9){
                    if removeAll{Text("All removable metadata will be cleared.").foregroundColor(.secondary).padding(.top,20)}
                    else if !loading && indices.isEmpty{Text("No matching metadata.").foregroundColor(.secondary).padding(.top,20)}
                    else{ForEach(Array(indices.enumerated()),id:\.element){position,index in
                        if position==0 || fields[indices[position-1]].group != fields[index].group {Text(fields[index].group).font(.system(size:10,weight:.semibold)).foregroundColor(.secondary).padding(.top,10);PDFToolDivider()}
                        HStack(spacing:8){Text(fields[index].label).font(.system(size:11)).frame(width:138,alignment:.trailing);TextField("Value",text:Binding(get:{fields[index].value},set:{fields[index].value=$0;fields[index].edited=true})).font(.system(size:11)).textFieldStyle(.roundedBorder).disabled(!fields[index].editable);Button{fields[index].removed=true}label:{Image(systemName:"minus.circle").foregroundColor(.white.opacity(0.6))}.buttonStyle(.plain).help(fields[index].editable ? "Remove \(fields[index].label)":"This property is inherent to the image").disabled(!fields[index].editable)}
                    }}
                }.padding(.horizontal,12).padding(.bottom,12)
            }.overlay{if loading{ProgressView()}}.disabled(busy)
            PDFToolDivider()
            Text("Remove All also clears hidden camera and processing data. Image format and dimensions remain inherent to the file.").font(.system(size:10)).foregroundColor(.white.opacity(0.6)).fixedSize(horizontal:false,vertical:true).padding(12)
            HStack{Text(message).font(.system(size:10)).foregroundColor(.orange).lineLimit(2);Spacer();if busy{ProgressView().controlSize(.small)};Button(removeAll ? "Restore":"Remove All"){removeAll.toggle()}.buttonStyle(PDFQuietButtonStyle());Button("Save",action:save).buttonStyle(PDFOrangeButtonStyle()).disabled(loading || busy)}.padding(.horizontal,12).frame(height:43).fixedSize(horizontal:false,vertical:true).layoutPriority(1)
        }.foregroundColor(.white.opacity(0.94)).preferredColorScheme(.dark).onAppear(perform:load).onExitCommand(perform:onClose)
    }
    private func load(){guard loading else{return};DispatchQueue.global(qos:.userInitiated).async{let result=Result{try ImageTools.metadata(url)};DispatchQueue.main.async{loading=false;switch result{case .success(let values):fields=values;case .failure(let error):message=error.localizedDescription}}}}
    private func save(){busy=true;message="";let values=fields,remove=removeAll;DispatchQueue.global(qos:.userInitiated).async{let result=Result{try ImageTools.saveMetadata(url,directory:destination,fields:values,removeAll:remove)};DispatchQueue.main.async{busy=false;switch result{case .success(let output):onSave(output);case .failure(let error):message=error.localizedDescription}}}}
}

@MainActor
func imageToolContent(operation:String,url:URL,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void,preview:Bool=false)->(AnyView,NSSize) {
    let (view,requested)=imageToolBody(operation:operation,url:url,destination:destination,onSave:onSave,onClose:onClose,preview:preview)
    let screen=NSScreen.screens.first{$0.frame.contains(NSEvent.mouseLocation)} ?? NSScreen.main
    let size=imageToolPanelSize(requested,visibleFrame:screen?.visibleFrame)
    return (AnyView(view.frame(width:size.width,height:size.height)),size)
}

func imageToolPanelSize(_ requested:NSSize,visibleFrame:NSRect?)->NSSize {
    guard let visibleFrame else{return requested}
    return NSSize(width:min(requested.width,max(320,visibleFrame.width-24)),height:min(requested.height,max(320,visibleFrame.height-24)))
}

@MainActor
private func imageToolBody(operation:String,url:URL,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void,preview:Bool)->(AnyView,NSSize) {
    switch operation {
    case "compress":return (AnyView(ImageCompressPanel(url:url,destination:destination,onSave:onSave,onClose:onClose,preview:preview)),NSSize(width:376,height:376))
    case "removeMetadata":return (AnyView(ImageMetadataPanel(url:url,destination:destination,onSave:onSave,onClose:onClose,preview:preview)),NSSize(width:520,height:560))
    case "editImage":return (AnyView(ImageAdjustPanel(url:url,destination:destination,onSave:onSave,onClose:onClose,preview:preview)),NSSize(width:500,height:820))
    case "frameImage":return (AnyView(ImageBackgroundPanel(url:url,destination:destination,onSave:onSave,onClose:onClose,preview:preview)),NSSize(width:470,height:660))
    default:
        let mode:ImageCanvasMode=operation=="cropImage" ? .crop:operation=="redactImage" ? .redact:.annotate
        return (AnyView(ImageCanvasPanel(url:url,mode:mode,destination:destination,onSave:onSave,onClose:onClose,preview:preview)),NSSize(width:mode == .annotate ? 470:400,height:mode == .crop ? 600:720))
    }
}
