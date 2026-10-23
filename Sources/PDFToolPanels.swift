import SwiftUI
import AppKit

let pdfToolOrange=Color(red:1,green:80.0/255,blue:0)

struct PDFToolDivider:View {
    var body:some View {Rectangle().fill(.white.opacity(0.16)).frame(height:0.5)}
}
struct PDFToolHeader:View {
    let title:String
    let onClose:()->Void
    var body:some View {
        ZStack{
            PDFHeaderDragArea().padding(.leading,38)
            Text(title).font(.system(size:16,weight:.semibold)).allowsHitTesting(false)
            HStack{Button(action:onClose){Image(systemName:"xmark").font(.system(size:13,weight:.medium)).frame(width:24,height:24).background(.white.opacity(0.08),in:Circle())}.buttonStyle(.plain).help("Close").accessibilityLabel("Close");Spacer()}.padding(.horizontal,10)
        }.frame(height:42).foregroundColor(.white.opacity(0.94)).overlay(alignment:.bottom){PDFToolDivider()}
    }
}

private struct PDFHeaderDragArea:NSViewRepresentable {
    final class DragView:NSView {
        override var mouseDownCanMoveWindow:Bool {false}
        override func mouseDown(with event:NSEvent){window?.performDrag(with:event)}
    }
    func makeNSView(context:Context)->DragView{DragView()}
    func updateNSView(_ view:DragView,context:Context){}
}

/// SwiftUI's custom drag gestures must not be interpreted as window drags.
private final class PDFContentHost<Content:View>:NSHostingView<Content> {
    override var mouseDownCanMoveWindow:Bool {false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
}
struct PDFOrangeButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:12,weight:.semibold)).foregroundColor(.white)
            .padding(.horizontal,11).frame(height:21)
            .background(pdfToolOrange.opacity(configuration.isPressed ? 0.8:1),in:RoundedRectangle(cornerRadius:6,style:.continuous)).opacity(enabled ? 1:0.4)
    }
}
struct PDFQuietButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:10,weight:.semibold)).foregroundColor(.white.opacity(0.85))
            .padding(.horizontal,8).frame(height:18).background(.white.opacity(configuration.isPressed ? 0.18:0.1),in:RoundedRectangle(cornerRadius:5)).opacity(enabled ? 1:0.35)
    }
}

private struct PDFReductionSlider:View {
    @Binding var value:Double
    var body:some View {
        GeometryReader { geometry in
            let width=max(1,geometry.size.width-10)
            let progress=CGFloat((value-1)/98)*width
            ZStack(alignment:.leading){
                Capsule().fill(.white.opacity(0.22)).frame(height:4)
                Capsule().fill(pdfToolOrange).frame(width:progress+5,height:4)
                RoundedRectangle(cornerRadius:5).fill(.white.opacity(0.88)).frame(width:10,height:18).offset(x:progress)
            }.frame(height:18).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged{event in value=(1+Double(max(0,min(width,event.location.x-5))/width)*98).rounded()})
        }.frame(height:18).accessibilityElement().accessibilityLabel("Reduce by").accessibilityValue("\(Int(value)) percent")
            .accessibilityAdjustableAction{direction in value=max(1,min(99,value+(direction == .increment ? 1:-1)))}
    }
}

@MainActor
private final class PDFNativePanel:NSPanel {
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {true}
}
@MainActor
enum PDFToolWindow {
    static func make(view:AnyView,size:NSSize,solid:Bool=false)->NSPanel {
        let panel=PDFNativePanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true
        panel.isFloatingPanel=true;panel.level = .floating;panel.hidesOnDeactivate=false;panel.becomesKeyOnlyIfNeeded=false
        panel.isMovableByWindowBackground=false;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.animationBehavior = .utilityWindow
        panel.appearance=NSAppearance(named:.darkAqua)
        let host=PDFContentHost(rootView:view.frame(width:size.width,height:size.height).preferredColorScheme(.dark));host.sizingOptions=[];host.frame=NSRect(origin:.zero,size:size);host.autoresizingMask=[.width,.height]
        let content:NSView
        if solid {
            let background=NSView(frame:host.frame);background.wantsLayer=true;background.layer?.backgroundColor=NSColor(calibratedWhite:0.14,alpha:1).cgColor;background.addSubview(host);content=background
        }else if #available(macOS 26.0,*) {
            let glass=NSGlassEffectView(frame:host.frame);glass.style = .regular;glass.cornerRadius=20;glass.tintColor=nil;glass.contentView=host;content=glass
        }else{
            let glass=NSVisualEffectView(frame:host.frame);glass.material = .hudWindow;glass.blendingMode = .behindWindow;glass.state = .active;glass.addSubview(host);content=glass
        }
        content.wantsLayer=true;content.layer?.cornerRadius=20;content.layer?.masksToBounds=true;content.layer?.borderWidth=0.5;content.layer?.borderColor=NSColor.white.withAlphaComponent(0.2).cgColor
        panel.contentView=content;panel.setContentSize(size);panel.center();return panel
    }
}

struct PDFCompressView:View {
    let url:URL
    let destination:URL
    let onSave:(URL)->Void
    let onClose:()->Void
    @State private var mode="percentage"
    @State private var preset="balanced"
    @State private var percentage=50.0
    @State private var targetSize="1"
    @State private var targetUnit="MB"
    @State private var originalBytes=0
    @State private var busy=false
    @State private var message=""
    init(url:URL,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void,preview:Bool=false){
        self.url=url;self.destination=destination;self.onSave=onSave;self.onClose=onClose
        if preview{_originalBytes=State(initialValue:(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
    }
    private var options:[String:String] {[
        "pdfCompressionMode":mode,"pdfCompressionPreset":preset,"pdfReduction":String(Int(percentage)),"pdfTargetSize":targetSize,"pdfTargetUnit":targetUnit
    ]}
    private var targetBytes:Int? {try? PDFCompression.targetBytes(original:originalBytes,options:options)}
    var body:some View {
        VStack(spacing:0){
            PDFToolHeader(title:"Compress",onClose:onClose)
            VStack(alignment:.leading,spacing:0){
                Text(url.lastPathComponent).font(.system(size:10,weight:.medium)).foregroundColor(.white.opacity(0.65)).lineLimit(1).truncationMode(.middle).padding(.top,10)
                Text("Original size: \(size(originalBytes))").font(.system(size:12,weight:.semibold)).padding(.top,17).padding(.bottom,16)
                PDFToolDivider()
                HStack{
                    Text("Mode").font(.system(size:10,weight:.medium)).foregroundColor(.white.opacity(0.65));Spacer()
                    Picker("Mode",selection:$mode){Text("Preset").tag("preset");Text("File Size").tag("fileSize");Text("Percentage").tag("percentage")}.labelsHidden().pickerStyle(.menu).frame(width:120)
                }.frame(height:52)
                PDFToolDivider()
                Group{
                    if mode=="percentage" {
                        HStack(spacing:8){Text("Reduce by").font(.system(size:11,weight:.semibold));PDFReductionSlider(value:$percentage);Text("\(Int(percentage))%").font(.system(size:11,weight:.semibold)).monospacedDigit().frame(width:32,alignment:.trailing)}.padding(.top,16)
                    }else if mode=="fileSize" {
                        HStack(spacing:10){Text("Maximum size").font(.system(size:11,weight:.semibold));Spacer();TextField("1",text:$targetSize).textFieldStyle(.roundedBorder).frame(width:70);Picker("Unit",selection:$targetUnit){Text("KB").tag("KB");Text("MB").tag("MB")}.labelsHidden().frame(width:60)}.padding(.top,16)
                    }else{
                        Picker("Quality",selection:$preset){Text("Small").tag("small");Text("Balanced").tag("balanced");Text("High Quality").tag("high")}.labelsHidden().pickerStyle(.segmented).padding(.top,16)
                    }
                }
                if mode != "preset" {
                    if let targetBytes {Text("Output will be at most \(size(targetBytes)).").font(.system(size:10,weight:.medium)).foregroundColor(.white.opacity(0.65)).padding(.top,8)}
                }
                Text("Compression may flatten pages and reduce detail or color accuracy. Text may no longer be selectable.").font(.system(size:9)).foregroundColor(.white.opacity(0.55)).fixedSize(horizontal:false,vertical:true).padding(.top,8)
                Spacer(minLength:0)
            }.padding(.horizontal,10).disabled(busy)
            PDFToolDivider()
            HStack(spacing:8){Text(message).font(.system(size:9)).foregroundColor(.red.opacity(0.9)).lineLimit(2);Spacer(minLength:0);if busy{ProgressView().controlSize(.small)};Button("Compress",action:compress).buttonStyle(PDFOrangeButtonStyle()).disabled(busy || originalBytes==0)}.padding(.horizontal,10).frame(height:52)
        }.frame(width:376,height:376).foregroundColor(.white.opacity(0.94)).preferredColorScheme(.dark).onAppear{originalBytes=(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0}.onExitCommand(perform:onClose)
    }
    private func size(_ bytes:Int)->String {ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file)}
    private func compress(){
        busy=true;message="";let selected=options
        DispatchQueue.global(qos:.userInitiated).async{
            do{let output=try PDFCompression.run(input:url,outputDirectory:destination,options:selected);DispatchQueue.main.async{busy=false;onSave(output);onClose()}}
            catch{DispatchQueue.main.async{busy=false;message=error.localizedDescription}}
        }
    }
}

struct PDFMetadataView:View {
    let url:URL
    let destination:URL
    let onSave:(URL)->Void
    let onClose:()->Void
    @State private var fields:[PDFMetadataField]=[]
    @State private var search=""
    @State private var busy=false
    @State private var loading=true
    @State private var message=""
    init(url:URL,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void,preview:Bool=false){
        self.url=url;self.destination=destination;self.onSave=onSave;self.onClose=onClose
        if preview{
            _loading=State(initialValue:false)
            do{_fields=State(initialValue:try PDFTools.readMetadata(url))}
            catch{_message=State(initialValue:error.localizedDescription)}
        }
    }
    private var filtered:[PDFMetadataField] {fields.filter{search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search)}}
    var body:some View {
        VStack(spacing:0){
            PDFToolHeader(title:"Metadata",onClose:onClose)
            HStack(spacing:10){
                Text(url.lastPathComponent).font(.system(size:10,weight:.medium)).foregroundColor(.white.opacity(0.65)).lineLimit(1).truncationMode(.middle);Spacer(minLength:0)
                TextField("Search metadata",text:$search).font(.system(size:12,weight:.medium)).textFieldStyle(.plain).padding(.horizontal,8).frame(width:160,height:22).background(.black.opacity(0.5),in:RoundedRectangle(cornerRadius:6)).accessibilityLabel("Search metadata")
            }.padding(.horizontal,4).frame(height:44)
            ScrollView{
                VStack(alignment:.leading,spacing:10){
                    Text("Document").font(.system(size:10,weight:.semibold)).foregroundColor(.white.opacity(0.65)).padding(.bottom,1)
                    ForEach(filtered){field in
                        HStack(spacing:9){
                            Text(field.label+":").font(.system(size:12,weight:.medium)).frame(width:130,alignment:.trailing)
                            TextField(field.label,text:binding(field.id)).textFieldStyle(.plain).font(.system(size:12)).padding(.horizontal,7).frame(height:26).background(.white.opacity(0.07),in:RoundedRectangle(cornerRadius:6)).accessibilityLabel(field.label)
                            Button{fields.removeAll{$0.id==field.id}}label:{Image(systemName:"minus.circle").font(.system(size:13)).foregroundColor(.white.opacity(0.85)).frame(width:26,height:26)}.buttonStyle(.plain).help("Remove \(field.label)")
                        }
                    }
                    if loading{ProgressView().controlSize(.small).frame(maxWidth:.infinity)}
                    else if filtered.isEmpty{Text(fields.isEmpty ? "No document metadata.":"No matching metadata.").font(.system(size:11)).foregroundColor(.white.opacity(0.5)).padding(.vertical,4)}
                    PDFToolDivider()
                }.padding(.horizontal,4).padding(.top,4)
            }.disabled(busy)
            PDFToolDivider()
            VStack(alignment:.leading,spacing:10){
                Text("For photos, Remove All also clears hidden camera and processing data. HDR and portrait effects may change.").font(.system(size:10,weight:.medium)).foregroundColor(.white.opacity(0.65)).fixedSize(horizontal:false,vertical:true)
                HStack(spacing:8){
                    Text(message).font(.system(size:9)).foregroundColor(.red.opacity(0.9)).lineLimit(2);Spacer(minLength:0)
                    if busy{ProgressView().controlSize(.small)}
                    Button("Remove All"){fields=[]}.buttonStyle(PDFMetadataSecondaryStyle()).disabled(busy || fields.isEmpty)
                    Button("Save",action:save).buttonStyle(PDFOrangeButtonStyle()).disabled(busy || loading)
                }
            }.padding(.horizontal,8).padding(.top,16).padding(.bottom,14)
        }.frame(width:464,height:540).foregroundColor(.white.opacity(0.94)).preferredColorScheme(.dark).onAppear(perform:load).onExitCommand(perform:onClose)
    }
    private func binding(_ id:String)->Binding<String> {Binding(get:{fields.first{$0.id==id}?.value ?? ""},set:{value in if let index=fields.firstIndex(where:{$0.id==id}){fields[index].value=value}})}
    private func load(){
        guard loading else{return}
        DispatchQueue.global(qos:.userInitiated).async{
            do{let loaded=try PDFTools.readMetadata(url);DispatchQueue.main.async{fields=loaded;loading=false}}
            catch{DispatchQueue.main.async{message=error.localizedDescription;loading=false}}
        }
    }
    private func save(){
        busy=true;message="";let selected=fields
        DispatchQueue.global(qos:.userInitiated).async{
            do{let output=try PDFTools.saveMetadata(url,fields:selected,outputDirectory:destination);DispatchQueue.main.async{busy=false;onSave(output);onClose()}}
            catch{DispatchQueue.main.async{busy=false;message=error.localizedDescription}}
        }
    }
}
private struct PDFMetadataSecondaryStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {configuration.label.font(.system(size:12,weight:.semibold)).foregroundColor(.white.opacity(0.9)).padding(.horizontal,10).frame(height:21).background(.white.opacity(configuration.isPressed ? 0.24:0.16),in:RoundedRectangle(cornerRadius:6)).opacity(enabled ? 1:0.4)}
}
