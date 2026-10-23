import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

struct Tool: Identifiable {
    let id: String
    let name: String
    let icon: String
    let group: String
    static let all: [Tool] = [
        Tool(id:"convert",name:"Convert",icon:"arrow.triangle.2.circlepath",group:"Conversions"),
        Tool(id:"compress",name:"Compress",icon:"arrow.down.right.and.arrow.up.left",group:"Tools"),
        Tool(id:"removeMetadata",name:"Remove Metadata",icon:"tag",group:"Tools"),
        Tool(id:"editImage",name:"Adjust Image",icon:"slider.horizontal.3",group:"Images"),
        Tool(id:"annotateImage",name:"Annotate Image",icon:"pencil.and.outline",group:"Images"),
        Tool(id:"frameImage",name:"Add Background",icon:"photo.artframe",group:"Images"),
        Tool(id:"cropImage",name:"Crop Image",icon:"crop",group:"Images"),
        Tool(id:"resizeImage",name:"Resize Image",icon:"arrow.up.left.and.arrow.down.right",group:"Images"),
        Tool(id:"rotateImage",name:"Rotate Image",icon:"rotate.right",group:"Images"),
        Tool(id:"createCollage",name:"Create Collage",icon:"square.grid.2x2",group:"Images"),
        Tool(id:"readQRCode",name:"Read QR Code",icon:"qrcode.viewfinder",group:"Images"),
        Tool(id:"redactImage",name:"Redact Image",icon:"eye.slash",group:"Images"),
        Tool(id:"normalizeAudio",name:"Normalize Volume",icon:"waveform",group:"Audio"),
        Tool(id:"trimAudio",name:"Trim Audio",icon:"scissors",group:"Audio"),
        Tool(id:"audioChannels",name:"Audio Channels",icon:"speaker.wave.2",group:"Audio"),
        Tool(id:"redactAudio",name:"Bleep Audio",icon:"speaker.slash",group:"Audio"),
        Tool(id:"audioToVideo",name:"Audio Visualizer",icon:"waveform.path",group:"Audio"),
        Tool(id:"muteVideo",name:"Mute Video",icon:"speaker.slash.fill",group:"Video"),
        Tool(id:"trimVideo",name:"Trim Video",icon:"scissors",group:"Video"),
        Tool(id:"cropVideo",name:"Crop Video",icon:"crop",group:"Video"),
        Tool(id:"changeVideoSpeed",name:"Change Speed",icon:"speedometer",group:"Video"),
        Tool(id:"joinVideos",name:"Join Videos",icon:"link",group:"Video"),
        Tool(id:"splitVideo",name:"Split Video",icon:"film",group:"Video"),
        Tool(id:"videoSnapshots",name:"Export Frames",icon:"camera",group:"Video"),
        Tool(id:"redactVideo",name:"Redact Video",icon:"eye.slash",group:"Video"),
        Tool(id:"createPDF",name:"Create PDF",icon:"doc.richtext",group:"Documents"),
        Tool(id:"mergePDF",name:"Merge PDFs",icon:"doc.on.doc",group:"Documents"),
        Tool(id:"splitPDF",name:"Split PDF",icon:"doc.on.doc.fill",group:"Documents"),
        Tool(id:"organizePDF",name:"Organize PDF",icon:"square.grid.2x2",group:"Documents"),
        Tool(id:"extractText",name:"Extract Text / OCR",icon:"text.viewfinder",group:"Documents"),
        Tool(id:"extractArchive",name:"Extract Archive",icon:"shippingbox",group:"Archives"),
        Tool(id:"createArchive",name:"Create ZIP",icon:"archivebox",group:"Archives"),
        Tool(id:"float",name:"Float Files",icon:"square.on.square",group:"Actions"),
        Tool(id:"copy",name:"Copy Files",icon:"doc.on.clipboard",group:"Actions"),
        Tool(id:"copyPath",name:"Copy Paths",icon:"link",group:"Actions"),
        Tool(id:"move",name:"Move to Folder",icon:"folder",group:"Actions"),
        Tool(id:"openTerminal",name:"Open Terminal",icon:"terminal",group:"Actions"),
        Tool(id:"airDrop",name:"AirDrop",icon:"airplayaudio",group:"Actions")
    ]
}

final class AppModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var selected = "convert"
    @Published var options: [String:String] = ["format":"png","quality":"80","width":"1280","height":"720","x":"0","y":"0","start":"0","duration":"5","end":"1","speed":"1.5","channels":"1","loudness":"-16","padding":"60","text":"Annotation","brightness":"0","contrast":"1","saturation":"1","times":"0,1","order":"1,2","rotations":"0,0","angle":"90","color":"#FF8A3D"] {didSet {UserDefaults.standard.set(options,forKey:"processingOptions")}}
    @Published var results: [URL] = []
    @Published var log = "Ready. Add files to begin."
    @Published var busy = false
    @AppStorage("wheelSoundsEnabled") var hapticsEnabled = true {willSet{objectWillChange.send()}}
    @Published var formatDefaults:[String:[String:String]] = UserDefaults.standard.dictionary(forKey:"formatDefaults") as? [String:[String:String]] ?? [:] {didSet{UserDefaults.standard.set(formatDefaults,forKey:"formatDefaults")}}
    let folderAccess=FolderAccessStore()
    @AppStorage("imageCompressionStrength") var imageCompressionStrength="balanced" {willSet{objectWillChange.send()}}
    @AppStorage("imageCompressionSize") var imageCompressionSize="0" {willSet{objectWillChange.send()}}
    @AppStorage("videoCompressionStrength") var videoCompressionStrength="balanced" {willSet{objectWillChange.send()}}
    @AppStorage("terminalApplication") var terminalApplication="com.apple.Terminal" {willSet{objectWillChange.send()}}
    @AppStorage("solid") var solid = false {willSet{objectWillChange.send()}}
    @AppStorage("floatReuse") var floatReuse = false {willSet{objectWillChange.send()}}
    @AppStorage("conversionModifier") var conversionModifier = "shift" {willSet{objectWillChange.send()}}
    @AppStorage("toolsModifier") var toolsModifier = "command" {willSet{objectWillChange.send()}}
    @AppStorage("actionsModifier") var actionsModifier = "control" {willSet{objectWillChange.send()}}
    var shelves: [NSPanel] = []
    var shelfModels: [ShelfModel] = []
    var wheel: NSPanel?
    var wheelDismissal:WheelDismissal?
    var observer: Any?
    var localObserver: Any?
    var status: NSStatusItem?
    var mainWindow: NSWindow?
    init() {if let saved=UserDefaults.standard.dictionary(forKey:"processingOptions") as? [String:String] {options.merge(saved){_,new in new}}}
    func add(_ urls: [URL]) {
        for u in urls where u.isFileURL && !files.contains(u) { files.append(u) }
    }
    static var desktopDirectory:URL {FileManager.default.urls(for:.desktopDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop",isDirectory:true)}
    let processingQueue=DispatchQueue(label:"local.citrus.processing",qos:.userInitiated)
    var pendingJobs=0
    var feedbackPanel:NSPanel?
    var feedbackGeneration=0
    var feedbackEnabled=true
    var onJobFinished:((Result<[URL],Error>)->Void)?
    var pdfToolWindows:[UUID:NSPanel]=[:]
    var pdfToolAccess:[UUID:FolderAccessStore.Lease]=[:]
    var pdfToolPresenter:((String,[URL],URL)->Void)?
    var audioToolPresenter:(([URL],URL)->Void)?
    var videoToolPresenter:((String,[URL],URL)->Void)?
    var imageToolPresenter:((String,[URL],URL)->Void)?
    var openQRURL:(URL)->Bool = {NSWorkspace.shared.open($0)}
    var showQRText:((String)->Void)?

    func submitWheelDrop(_ target:Tool, urls:[URL], destination:URL?=nil) {
        guard !urls.isEmpty else {notify("No local files were received.",failed:true);return}
        let output=destination ?? Self.desktopDirectory
        let access=FolderAccessStore.Lease(entries:folderAccess.entries,files:urls+[output])
        defer{withExtendedLifetime(access){}}
        let sourceIsArchive=["zip","tar","gz","gzip","tgz","rar"].contains(urls.first?.pathExtension.lowercased() ?? "")
        let archiveTarget=["zip","tar","gzip"].contains(target.id)
        let operation=target.group == "Format" ? (archiveTarget ? (sourceIsArchive ? "convertArchive":"createArchive") : "convert") : target.id
        var opts=options
        if target.group == "Format" {opts.merge(SettingsCatalog.resolved(target.id,overrides:formatDefaults[target.id] ?? [:])){_,new in new};opts["format"]=target.id}
        if operation=="compress" {
            let ext=urls.first?.pathExtension.lowercased() ?? ""
            if SettingsCatalog.groups[0].formats.contains(ext) {opts["quality"]=imageCompressionStrength=="strong" ? "45":"75";opts["maxImageEdge"]=imageCompressionSize;opts["width"]=""}
            else if SettingsCatalog.groups[4].formats.contains(ext) {opts["crf"]=videoCompressionStrength=="strong" ? "35":"28";opts["width"]=""}
        }
        files=urls;selected=operation
        dismissWheel()
        // Tools that need choices open their own compact panel; the settings
        // window stays hidden. Conversions and Split remain background jobs.
        mainWindow?.orderOut(nil)
        if urls.allSatisfy({$0.pathExtension.lowercased()=="pdf"}) {
            if ["compress","removeMetadata","organizePDF"].contains(operation) {
                if let presenter=pdfToolPresenter {presenter(operation,urls,output)}
                else {DispatchQueue.main.async {withExtendedLifetime(access){self.presentPDFTool(operation,inputs:urls,destination:output)}}}
                return
            }
            if operation=="readQRCode" {readPDFQRCodes(urls);return}
            // Split means all pages; stale options from another operation must
            // not silently restrict this wheel action.
            if operation=="splitPDF" {opts.removeValue(forKey:"pages")}
        }
        if (VideoTools.singleToolIDs+["joinVideos"]).contains(operation),urls.allSatisfy({VideoTools.extensions.contains($0.pathExtension.lowercased())}) {
            if operation=="muteVideo" {execute(operation,inputs:urls,options:[:],destination:output,background:true)}
            else if let presenter=videoToolPresenter {presenter(operation,urls,output)}
            else {DispatchQueue.main.async {withExtendedLifetime(access){self.presentVideoTool(operation,inputs:urls,destination:output)}}}
            return
        }
        if operation=="trimAudio",urls.allSatisfy({AudioTrim.extensions.contains($0.pathExtension.lowercased())}) {
            if let presenter=audioToolPresenter {presenter(urls,output)}
            else {DispatchQueue.main.async {withExtendedLifetime(access){self.presentAudioTrim(inputs:urls,destination:output)}}}
            return
        }
        let imageOperations:Set<String>=["compress","removeMetadata","editImage","annotateImage","frameImage","cropImage","redactImage"]
        if imageOperations.contains(operation),urls.allSatisfy({SettingsCatalog.groups[0].formats.contains($0.pathExtension.lowercased()) || ["jpeg","tif","heif"].contains($0.pathExtension.lowercased())}) {
            if let presenter=imageToolPresenter {presenter(operation,urls,output)}
            else {DispatchQueue.main.async {withExtendedLifetime(access){self.presentImageTool(operation,inputs:urls,destination:output)}}}
            return
        }
        execute(operation,inputs:urls,options:opts,destination:output,background:true)
    }

    @MainActor func presentPDFTool(_ operation:String,inputs:[URL],destination:URL) {
        for input in inputs {
            let id=UUID()
            pdfToolAccess[id]=FolderAccessStore.Lease(entries:folderAccess.entries,files:[input,destination])
            let close:()->Void = {[weak self] in
                self?.pdfToolWindows.removeValue(forKey:id)?.close()
                self?.pdfToolAccess.removeValue(forKey:id)?.close()
            }
            let save:(URL)->Void = {[weak self] output in
                self?.results=[output];self?.log="Saved \(output.lastPathComponent) to \(output.deletingLastPathComponent().path)."
                self?.onJobFinished?(.success([output]));close()
            }
            let content:AnyView
            let size:NSSize
            switch operation {
            case "organizePDF":content=AnyView(PDFEditorView(url:input,destination:destination,onSave:save,onClose:close));size=NSSize(width:560,height:600)
            case "removeMetadata":content=AnyView(PDFMetadataView(url:input,destination:destination,onSave:save,onClose:close));size=NSSize(width:464,height:540)
            default:content=AnyView(PDFCompressView(url:input,destination:destination,onSave:save,onClose:close));size=NSSize(width:376,height:376)
            }
            let panel=PDFToolWindow.make(view:content,size:size,solid:solid)
            panel.title=operation=="organizePDF" ? "Organize PDF":operation=="removeMetadata" ? "Metadata":"Compress"
            pdfToolWindows[id]=panel
            panel.center();panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps:true)
        }
    }

    @MainActor func presentImageTool(_ operation:String,inputs:[URL],destination:URL) {
        for (index,input) in inputs.enumerated() {
            let id=UUID()
            pdfToolAccess[id]=FolderAccessStore.Lease(entries:folderAccess.entries,files:[input,destination])
            let close:()->Void = {[weak self] in
                self?.pdfToolWindows.removeValue(forKey:id)?.close()
                self?.pdfToolAccess.removeValue(forKey:id)?.close()
            }
            let save:(URL)->Void = {[weak self] output in
                self?.results=[output];self?.log="Saved \(output.lastPathComponent) to \(output.deletingLastPathComponent().path)."
                self?.onJobFinished?(.success([output]));close()
            }
            let (content,size)=imageToolContent(operation:operation,url:input,destination:destination,onSave:save,onClose:close)
            let panel=PDFToolWindow.make(view:content,size:size,solid:solid)
            panel.title=Tool.all.first(where:{$0.id==operation})?.name ?? "Image"
            pdfToolWindows[id]=panel
            panel.center()
            let visible=(NSScreen.screens.first{$0.frame.contains(NSEvent.mouseLocation)} ?? NSScreen.main)?.visibleFrame ?? panel.frame
            let offset=CGFloat(index%5)*18
            panel.setFrameOrigin(NSPoint(x:max(visible.minX+12,min(panel.frame.minX+offset,visible.maxX-panel.frame.width-12)),y:max(visible.minY+12,min(panel.frame.minY-offset,visible.maxY-panel.frame.height-12))))
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps:true)
        }
    }

    @MainActor func presentVideoTool(_ operation:String,inputs:[URL],destination:URL) {
        let groups=operation=="joinVideos" ? [inputs]:inputs.map{[$0]}
        for (index,group) in groups.enumerated() {
            let id=UUID()
            pdfToolAccess[id]=FolderAccessStore.Lease(entries:folderAccess.entries,files:group+[destination])
            let close:()->Void = {[weak self] in self?.pdfToolWindows.removeValue(forKey:id)?.close();self?.pdfToolAccess.removeValue(forKey:id)?.close()}
            let save:([URL])->Void = {[weak self] outputs in self?.results=outputs;self?.log="Saved \(outputs.count) file(s) to \(destination.path).";self?.onJobFinished?(.success(outputs));close()}
            let (content,size)=videoToolContent(operation:operation,inputs:group,destination:destination,onSave:save,onClose:close)
            let panel=PDFToolWindow.make(view:content,size:size,solid:solid);panel.title=Tool.all.first{$0.id==operation}?.name ?? "Video"
            pdfToolWindows[id]=panel;panel.center()
            let visible=NSScreen.main?.visibleFrame ?? panel.frame,offset=CGFloat(index%5)*18
            panel.setFrameOrigin(NSPoint(x:max(visible.minX+12,min(panel.frame.minX+offset,visible.maxX-panel.frame.width-12)),y:max(visible.minY+12,min(panel.frame.minY-offset,visible.maxY-panel.frame.height-12))))
            panel.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        }
    }

    @MainActor func presentAudioTrim(inputs:[URL],destination:URL) {
        for input in inputs {
            let id=UUID()
            pdfToolAccess[id]=FolderAccessStore.Lease(entries:folderAccess.entries,files:[input,destination])
            let close:()->Void = {[weak self] in self?.pdfToolWindows.removeValue(forKey:id)?.close();self?.pdfToolAccess.removeValue(forKey:id)?.close()}
            let save:(URL)->Void = {[weak self] output in self?.results=[output];self?.log="Saved \(output.lastPathComponent) to \(destination.path).";self?.onJobFinished?(.success([output]));close()}
            let size=imageToolPanelSize(NSSize(width:400,height:336),visibleFrame:NSScreen.main?.visibleFrame)
            let panel=PDFToolWindow.make(view:AnyView(AudioTrimPanel(url:input,destination:destination,onSave:save,onClose:close).frame(width:size.width,height:size.height)),size:size,solid:solid)
            panel.title="Trim Audio";pdfToolWindows[id]=panel;panel.center();panel.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        }
    }

    func readPDFQRCodes(_ inputs:[URL]) {
        pendingJobs+=1;busy=true;log="Reading QR codes…"
        let grants=folderAccess.entries
        let access=FolderAccessStore.Lease(entries:grants,files:inputs)
        processingQueue.async {
            let outcome=Result {try withExtendedLifetime(access) {try inputs.flatMap{try PDFTools.qrPayloads($0)}}}
            DispatchQueue.main.async {
                self.pendingJobs-=1;self.busy=self.pendingJobs>0
                do {
                    let payloads=Array(NSOrderedSet(array:try outcome.get())) as? [String] ?? []
                    var opened:[URL]=[],text:[String]=[]
                    for payload in payloads {
                        if let url=PDFTools.webURL(payload) {
                            guard self.openQRURL(url) else{throw UIError.message("Could not open QR link: \(url.absoluteString)")}
                            opened.append(url)
                        } else {text.append(payload)}
                    }
                    if !text.isEmpty {
                        let contents=text.joined(separator:"\n\n")
                        if let show=self.showQRText {show(contents)}
                        else {let alert=NSAlert();alert.messageText="QR Code";alert.informativeText=contents;alert.addButton(withTitle:"Done");alert.runModal()}
                    }
                    self.results=[];self.log=opened.isEmpty ? "QR code read.":"Opened \(opened.count) QR link\(opened.count==1 ? "":"s")."
                    self.onJobFinished?(.success(opened))
                } catch {self.log=error.localizedDescription;self.notify(error.localizedDescription,failed:true);self.onJobFinished?(.failure(error))}
                self.status?.button?.toolTip=self.log
            }
        }
    }
    func execute(_ operation:String,inputs:[URL],options:[String:String],destination:URL,background:Bool) {
        guard !inputs.isEmpty else {return}
        if Tool.all.first(where:{$0.id==operation})?.group == "Actions" {
            action(operation,inputs)
            return
        }
        var opts=options
        if operation == "createArchive",opts["format"]==nil {opts["format"]="zip"}
        let snapshot=opts
        let folderGrants=folderAccess.entries
        let access=FolderAccessStore.Lease(entries:folderGrants,files:inputs+[destination])
        pendingJobs+=1;busy=true;results=[]
        let title=Tool.all.first(where:{$0.id==operation})?.name ?? operation
        log="\(title)…";status?.button?.toolTip=log
        processingQueue.async {
            let outcome=Result {try withExtendedLifetime(access) {try ProcessingJob.run(operation,inputs:inputs,outputDirectory:destination,options:snapshot)}}
            DispatchQueue.main.async {
                self.pendingJobs-=1;self.busy=self.pendingJobs>0
                switch outcome {
                case .success(let output):
                    self.results=output;self.log="Saved \(output.count) item\(output.count == 1 ? "" : "s") to \(destination.path)."
                case .failure(let error):
                    self.log=error.localizedDescription
                    if background {self.notify(error.localizedDescription,failed:true)}
                }
                self.status?.button?.toolTip=self.log
                self.onJobFinished?(outcome)
            }
        }
    }
    func notify(_ text:String,failed:Bool=false) {
        guard feedbackEnabled && failed else {return}
        feedbackPanel?.orderOut(nil);feedbackGeneration+=1
        let generation=feedbackGeneration
        let visible=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1280,height:800)
        let p=NSPanel(contentRect:NSRect(x:visible.maxX-370,y:visible.maxY-105,width:350,height:84),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque=false;p.backgroundColor = .clear;p.level = .floating;p.ignoresMouseEvents=true;p.isReleasedWhenClosed=false;p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        p.contentView=NSHostingView(rootView:HStack(spacing:12){if failed {Image(systemName:"exclamationmark.triangle.fill").foregroundColor(.red)} else {Image(nsImage:AppBrand.image).resizable().scaledToFit().frame(width:24,height:24)};Text(text).font(.callout).lineLimit(3);Spacer()}.padding(16).frame(width:350,height:84).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14)))
        feedbackPanel=p;p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline:.now()+(failed ? 8:4)){[weak self,weak p] in if self?.feedbackGeneration==generation{p?.orderOut(nil)}}
    }
    func action(_ id:String,_ inputs:[URL]) {
        do {
            switch id {
            case "copy": NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(inputs as [NSURL]); log="Files copied to clipboard."
            case "copyPath": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(inputs.map(\.path).joined(separator:"\n"),forType:.string); log="Paths copied."
            case "float": floatFiles(inputs); log="Files added to Float."
            case "move":
                let p=NSOpenPanel();p.canChooseFiles=false;p.canChooseDirectories=true;p.prompt="Move Here"
                guard p.runModal() == .OK, let folder=p.url else {return}
                var moved:[URL]=[]
                for u in inputs {
                    let dest=folder.appendingPathComponent(u.lastPathComponent)
                    guard dest.standardizedFileURL != u.standardizedFileURL, !folder.standardizedFileURL.path.hasPrefix(u.standardizedFileURL.path+"/") else {throw UIError.message("Choose a destination outside the selected folder.")}
                    guard !FileManager.default.fileExists(atPath:dest.path) else {throw UIError.message("\(dest.lastPathComponent) already exists. No replacement was made.")}
                }
                for u in inputs {let d=folder.appendingPathComponent(u.lastPathComponent);try FileManager.default.moveItem(at:u,to:d);moved.append(d)}
                files=moved;results=moved;log="Moved \(moved.count) items."
            case "openTerminal":
                let dirs=Set(inputs.map {u in (try? u.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true ? u : u.deletingLastPathComponent()})
                guard let term=NSWorkspace.shared.urlForApplication(withBundleIdentifier:terminalApplication) else {throw UIError.message("Terminal is unavailable.")}
                for d in dirs {NSWorkspace.shared.open([d],withApplicationAt:term,configuration:NSWorkspace.OpenConfiguration())}
                log="Opened Terminal."
            case "airDrop":
                guard let service=NSSharingService(named:.sendViaAirDrop) else {throw UIError.message("AirDrop is unavailable on this Mac.")}
                service.perform(withItems:inputs); log="AirDrop opened."
            default: break
            }
        } catch {log=error.localizedDescription}
    }
    func floatFiles(_ urls:[URL]) {
        if floatReuse, let m=shelfModels.last, let p=shelves.last {m.add(urls);p.orderFrontRegardless();return}
        let m=ShelfModel(urls)
        let p=NSPanel(contentRect:NSRect(x:240+shelves.count*28,y:240+shelves.count*28,width:310,height:340),styleMask:[.titled,.closable,.resizable,.utilityWindow,.nonactivatingPanel],backing:.buffered,defer:false)
        p.title="Citrus Float";p.level = .floating;p.isReleasedWhenClosed=false;p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        p.contentView=NSHostingView(rootView:ShelfView(model:m)); shelves.append(p);shelfModels.append(m);p.orderFrontRegardless()
    }
    func present() {mainWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    func installMenu() {
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        status?.button?.image=AppBrand.menuImage
        let menu=NSMenu()
        for (title,selector) in [("Settings…",#selector(MenuBridge.settings)),("Quit Citrus",#selector(MenuBridge.quit))] {let i=NSMenuItem(title:title,action:selector,keyEquivalent:"");i.target=MenuBridge.shared;menu.addItem(i)}
        status?.menu=menu;MenuBridge.shared.model=self
        observer=NSEvent.addGlobalMonitorForEvents(matching:[.flagsChanged]) {[weak self] e in DispatchQueue.main.async {self?.dragModifiers(e)}}
        localObserver=NSEvent.addLocalMonitorForEvents(matching:[.flagsChanged]) {[weak self] e in self?.dragModifiers(e);return e}
    }
    func dragModifiers(_ e:NSEvent) {
        guard NSEvent.pressedMouseButtons != 0 else {return}
        let f=e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let group:String
        if WheelShortcut.matches(f,actionsModifier) {group="Actions"} else if WheelShortcut.matches(f,toolsModifier) {group="Tools"} else if WheelShortcut.matches(f,conversionModifier) {group="Conversions"} else {return}
        showWheel(group)
    }
    func dismissWheel(){wheelDismissal?.invalidate();wheelDismissal=nil;wheel?.orderOut(nil);wheel=nil}
    func showWheel(_ group:String) {
        let dragged=NSEvent.pressedMouseButtons != 0 ? WheelDropView.fileURLs(from:NSPasteboard(name:.drag)) : files
        if let existing=wheel,existing.isVisible,let view=existing.contentView?.subviews.compactMap({$0 as? WheelDropView}).first,view.group==group,view.inputs==dragged {return}
        mainWindow?.orderOut(nil)
        dismissWheel()
        let mouse=NSEvent.mouseLocation
        let visible=NSScreen.screens.first(where:{$0.frame.contains(mouse)})?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1280,height:800)
        let diameter=WheelDropView.panelSize
        let origin=NSPoint(x:min(max(mouse.x-diameter/2,visible.minX),visible.maxX-diameter),y:min(max(mouse.y-diameter/2,visible.minY),visible.maxY-diameter))
        let p=NSPanel(contentRect:NSRect(origin:origin,size:NSSize(width:diameter,height:diameter)),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque=false;p.backgroundColor = .clear;p.level = .floating;p.hasShadow=true;p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];p.isReleasedWhenClosed=false;p.acceptsMouseMovedEvents=true;p.hidesOnDeactivate=false
        let nativeWheel=WheelDropView(group:group,inputs:dragged,onHighlight:{[weak self] in if self?.hapticsEnabled == true {NSHapticFeedbackManager.defaultPerformer.perform(.alignment,performanceTime:.now)}},onDrop:{[weak self] target,urls in self?.submitWheelDrop(target,urls:urls)},onClose:{[weak self] in self?.dismissWheel()})
        if group=="Conversions" && nativeWheel.tools.isEmpty {return}
        let container=NSView(frame:NSRect(x:0,y:0,width:diameter,height:diameter))
        nativeWheel.usesMaterial = !solid
        container.addSubview(nativeWheel.materialBackdrop(frame:container.bounds))
        container.addSubview(nativeWheel);p.appearance=NSAppearance(named:.darkAqua);p.contentView=container;wheel=p;p.alphaValue=0;p.orderFrontRegardless()
        wheelDismissal=WheelDismissal(startedDragging:NSEvent.pressedMouseButtons != 0,window:p){[weak self,weak p] in
            guard let self=self,let p=p,self.wheel === p else{return};self.dismissWheel()
        }
        NSAnimationContext.runAnimationGroup {context in context.duration=0.14;p.animator().alphaValue=1}
    }

}
enum UIError:LocalizedError {case message(String);var errorDescription:String?{if case .message(let s)=self{return s};return nil}}
final class MenuBridge:NSObject {
    static let shared=MenuBridge();weak var model:AppModel?
    @objc func open(){model?.present()}
    @objc func settings(){model?.present()}
    @objc func quit(){NSApp.terminate(nil)}
}
final class ShelfModel:ObservableObject {
    @Published var files:[URL]
    init(_ urls:[URL]){files=urls}
    func add(_ urls:[URL]){for u in urls where !files.contains(u){files.append(u)}}
}
struct ShelfView:View {
    @ObservedObject var model:ShelfModel
    var body:some View {
        VStack(alignment:.leading){
            Label("Float",systemImage:"square.on.square").font(.title2.bold()).padding(.horizontal)
            Text("Drop files here · Drag them anywhere").font(.caption).foregroundColor(.secondary).padding(.horizontal)
            List {ForEach(model.files,id:\.self){u in
                HStack{Image(nsImage:NSWorkspace.shared.icon(forFile:u.path)).resizable().frame(width:28,height:28);Text(u.lastPathComponent).lineLimit(2);Spacer()}
                    .onDrag{NSItemProvider(object:u as NSURL)}.onTapGesture(count:2){NSWorkspace.shared.open(u)}
                    .contextMenu{Button("Open"){NSWorkspace.shared.open(u)};Button("Show in Finder"){NSWorkspace.shared.activateFileViewerSelecting([u])};Button("Remove from Float"){model.files.removeAll{$0==u}}}
            }}
            Button("Copy All Files"){NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects(model.files as [NSURL])}.padding(.horizontal)
        }.padding(.vertical).frame(minWidth:250,minHeight:200).onDrop(of:[UTType.fileURL.identifier],isTargeted:nil){providers in acceptFiles(providers){model.add($0)}}
    }
}
@discardableResult func acceptFiles(_ providers:[NSItemProvider],_ callback:@escaping([URL])->Void)->Bool {
    let group=DispatchGroup();let lock=NSLock();var values:[(Int,URL)]=[]
    for (index,p) in providers.enumerated(){group.enter();p.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil){item,_ in
        var u:URL?;if let data=item as? Data{u=URL(dataRepresentation:data,relativeTo:nil)}else if let url=item as? URL{u=url}else if let str=item as? String{u=URL(string:str)}
        if let u=u,u.isFileURL{lock.lock();values.append((index,u));lock.unlock()};group.leave()
    }}
    group.notify(queue:.main){callback(values.sorted{$0.0<$1.0}.map{$0.1})};return !providers.isEmpty
}


final class AppDelegate:NSObject,NSApplicationDelegate {
    let model=AppModel()
    func applicationDidFinishLaunching(_ note:Notification){
        let w=NSWindow(contentRect:NSRect(x:160,y:140,width:456,height:560),styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        w.setFrame(NSRect(x:160,y:140,width:456,height:592),display:false);w.isMovableByWindowBackground=true
        w.title="Citrus Settings";w.titleVisibility = .hidden;w.titlebarAppearsTransparent=true
        w.appearance=NSAppearance(named:.darkAqua);w.backgroundColor=NSColor(srgbRed:0.16,green:0.18,blue:0.19,alpha:1)
        w.standardWindowButton(.miniaturizeButton)?.isEnabled=false;w.standardWindowButton(.zoomButton)?.isEnabled=false
        w.contentView=NSHostingView(rootView:SettingsView(model:model));w.isReleasedWhenClosed=false
        w.center();model.mainWindow=w;model.installMenu()
        if let option=CommandLine.arguments.firstIndex(of:"--show-image-tool"),CommandLine.arguments.count>option+2 {
            let operation=CommandLine.arguments[option+1],url=URL(fileURLWithPath:CommandLine.arguments[option+2])
            let destination=CommandLine.arguments.count>option+3 ? URL(fileURLWithPath:CommandLine.arguments[option+3]):AppModel.desktopDirectory
            if let tool=Tool.all.first(where:{$0.id==operation}){model.submitWheelDrop(tool,urls:[url],destination:destination)}
        }else if !CommandLine.arguments.contains("--background"){model.present()}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication, hasVisibleWindows flag:Bool)->Bool {model.present();return true}
}
