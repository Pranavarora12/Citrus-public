import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

@MainActor
final class PDFOrganizerState:ObservableObject {
    @Published var pages:[Int]=[]
    @Published var thumbnails:[Int:NSImage]=[:]
    @Published var rotations:[Int:Int]=[:]
    @Published var loading=true
    @Published var saving=false
    @Published var message=""
    private(set) var originalCount=0
    private var generation=UUID()
    private var task:Task<Void,Never>?
    private var previewSeeded=false
    init(previewURL:URL?=nil){
        guard let previewURL else{return}
        previewSeeded=true;loading=false
        guard let document=PDFDocument(url:previewURL),!document.isLocked,document.pageCount>0 else{message="This PDF could not be opened.";return}
        originalCount=document.pageCount;pages=Array(0..<originalCount)
        // Only visible preview rows need eager thumbnails. Production loading
        // remains asynchronous and fills the complete cache.
        for index in 0..<min(originalCount,32){
            if let page=document.page(at:index){thumbnails[index]=page.thumbnail(of:NSSize(width:250,height:170),for:.mediaBox)}
        }
    }
    func load(_ url:URL) {
        guard task == nil,!previewSeeded else{return}
        let token=UUID();generation=token
        task=Task.detached(priority:.userInitiated){[weak self] in
            guard let owner=self else{return}
            let document:PDFDocument
            do {document=try PDFTools.readable(url)}
            catch {await MainActor.run{guard owner.generation==token else{return};owner.loading=false;owner.message=error.localizedDescription};return}
            let count=document.pageCount
            await MainActor.run{guard owner.generation==token else{return};owner.originalCount=count;owner.pages=Array(0..<count);owner.loading=false}
            for index in 0..<count {
                guard !Task.isCancelled else{return}
                guard let page=document.page(at:index) else{continue}
                let image=page.thumbnail(of:NSSize(width:250,height:170),for:.mediaBox)
                await MainActor.run{guard owner.generation==token else{return};owner.thumbnails[index]=image}
            }
        }
    }
    func cancel(){task?.cancel();generation=UUID()}
    func reset(){pages=Array(0..<originalCount);rotations=[:]}
    var changed:Bool {pages != Array(0..<originalCount) || !rotations.isEmpty}
}

struct PDFEditorView:View {
    let url:URL
    let destination:URL
    let onSave:(URL)->Void
    let onClose:()->Void
    @StateObject private var state:PDFOrganizerState
    @State private var dragged:Int?
    @State private var equalWidths=false
    private let columns=Array(repeating:GridItem(.flexible(),spacing:12),count:4)
    init(url:URL,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void,preview:Bool=false){
        self.url=url;self.destination=destination;self.onSave=onSave;self.onClose=onClose
        _state=StateObject(wrappedValue:PDFOrganizerState(previewURL:preview ? url:nil))
    }
    var body:some View {
        VStack(spacing:0){
            PDFToolHeader(title:"Organize PDF",onClose:onClose)
            HStack{
                Text("\(state.pages.count) pages").font(.system(size:11,weight:.semibold)).foregroundColor(.white.opacity(0.65))
                Spacer()
                Button("Reset Order"){withAnimation(.easeInOut(duration:0.15)){state.reset()}}.buttonStyle(PDFQuietButtonStyle()).disabled(!state.changed || state.saving)
            }.padding(.horizontal,10).frame(height:40)
            ScrollView{
                LazyVGrid(columns:columns,spacing:34){
                    ForEach(state.pages,id:\.self){page in
                        pageCard(page)
                            .onDrag{dragged=page;return NSItemProvider(object:String(page) as NSString)}
                            .onDrop(of:[UTType.text],delegate:PDFPageDropDelegate(page:page,pages:$state.pages,dragged:$dragged))
                    }
                }.padding(.horizontal,14).padding(.top,8).padding(.bottom,16)
            }.overlay{if state.loading{ProgressView().controlSize(.small)}}
            PDFToolDivider().padding(.horizontal,10)
            VStack(alignment:.leading,spacing:9){
                Toggle("Make all pages the same width",isOn:$equalWidths).toggleStyle(.checkbox).font(.system(size:11,weight:.semibold))
                Text("Pages are scaled proportionally to match the narrowest page; their heights may still differ.").font(.system(size:10)).foregroundColor(.white.opacity(0.65)).fixedSize(horizontal:false,vertical:true)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,10).padding(.vertical,10)
            PDFToolDivider()
            HStack(spacing:10){
                Text(state.message).font(.system(size:10)).foregroundColor(.red.opacity(0.9)).lineLimit(2)
                Spacer(minLength:0)
                if state.saving{ProgressView().controlSize(.small)}
                Button("Save Organized PDF",action:save).buttonStyle(PDFOrangeButtonStyle()).disabled(state.saving || state.pages.isEmpty)
            }.padding(.horizontal,16).frame(height:52)
        }.frame(width:560,height:600).foregroundColor(.white.opacity(0.95)).preferredColorScheme(.dark)
            .onAppear{state.load(url)}.onDisappear{state.cancel()}.onExitCommand(perform:onClose)
    }
    private func pageCard(_ page:Int)->some View {
        let rotation=state.rotations[page] ?? 0
        let sideways=rotation%180 != 0
        return ZStack(alignment:.topLeading){
            RoundedRectangle(cornerRadius:9,style:.continuous).fill(.white).shadow(color:.black.opacity(0.13),radius:3,y:2)
            Group{
                if let thumbnail=state.thumbnails[page] {
                    Image(nsImage:thumbnail).resizable().scaledToFit()
                        .frame(width:sideways ? 64:110,height:sideways ? 110:64)
                        .rotationEffect(.degrees(Double(rotation)))
                }else{ProgressView().controlSize(.mini).tint(.gray)}
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            Text("\(page+1)").font(.system(size:11,weight:.bold)).foregroundColor(.white)
                .frame(width:22,height:22).background(pdfToolOrange,in:Circle()).padding(7)
            HStack{Spacer();Button{
                withAnimation(.easeInOut(duration:0.15)){let angle=(rotation+90)%360;if angle==0{state.rotations.removeValue(forKey:page)}else{state.rotations[page]=angle}}
            }label:{Image(systemName:"rotate.right").font(.system(size:12,weight:.medium)).foregroundColor(.white).frame(width:22,height:22).background(.black.opacity(0.65),in:Circle())}
                .buttonStyle(.plain).help("Rotate page \(page+1) clockwise").accessibilityLabel("Rotate page \(page+1)")}.padding(7)
        }.frame(height:78).clipShape(RoundedRectangle(cornerRadius:9,style:.continuous)).opacity(dragged==page ? 0.65:1)
            .accessibilityElement(children:.contain).accessibilityLabel("Page \(page+1)")
    }
    private func save(){
        state.saving=true;state.message=""
        let options=["order":state.pages.map{String($0+1)}.joined(separator:","),"rotations":state.pages.map{String(state.rotations[$0] ?? 0)}.joined(separator:","),"equalWidths":equalWidths ? "true":"false"]
        DispatchQueue.global(qos:.userInitiated).async{
            do{
                let results=try DocumentEngine.run("organizePDF",inputs:[url],outputDirectory:destination,options:options)
                guard let output=results.first else{throw NSError(domain:"PDFOrganizer",code:1,userInfo:[NSLocalizedDescriptionKey:"No organized PDF was created."])}
                DispatchQueue.main.async{state.saving=false;onSave(output);onClose()}
            }catch{DispatchQueue.main.async{state.saving=false;state.message=error.localizedDescription}}
        }
    }
}

private struct PDFPageDropDelegate:DropDelegate {
    let page:Int
    @Binding var pages:[Int]
    @Binding var dragged:Int?
    func validateDrop(info:DropInfo)->Bool {dragged != nil}
    func dropEntered(info:DropInfo){
        guard let dragged,dragged != page,let from=pages.firstIndex(of:dragged),let to=pages.firstIndex(of:page) else{return}
        withAnimation(.easeInOut(duration:0.15)){pages.move(fromOffsets:IndexSet(integer:from),toOffset:to>from ? to+1:to)}
    }
    func dropUpdated(info:DropInfo)->DropProposal? {DropProposal(operation:.move)}
    func performDrop(info:DropInfo)->Bool {dragged=nil;return true}
}
