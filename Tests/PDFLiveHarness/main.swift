import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class PDFLiveDelegate:NSObject,NSApplicationDelegate {
    let model=AppModel()
    var window:NSWindow!
    var input:URL?
    var access:FolderAccessStore.Lease?
    let status=NSTextField(labelWithString:"Choose the PDF used in the failing wheel drop.")
    var output:URL {Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("pdf-live-results",isDirectory:true)}
    func applicationDidFinishLaunching(_ notification:Notification) {
        window=NSWindow(contentRect:NSRect(x:250,y:220,width:560,height:170),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="Citrus PDF Live Checks";window.isReleasedWhenClosed=false
        let stack=NSStackView();stack.orientation = .vertical;stack.spacing=16;stack.alignment = .leading
        let choose=NSButton(title:"Choose PDF…",target:self,action:#selector(choosePDF))
        let row=NSStackView();row.spacing=14
        for (name,id) in [("Organize","organizePDF"),("Compress","compress"),("Metadata","removeMetadata"),("Split","splitPDF")] {
            let button=NSButton(title:name,target:self,action:#selector(runTool(_:)));button.identifier=NSUserInterfaceItemIdentifier(id);row.addArrangedSubview(button)
        }
        stack.addArrangedSubview(choose);stack.addArrangedSubview(status);stack.addArrangedSubview(row)
        stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20)])
        model.onJobFinished={[weak self] result in
            switch result {case .success(let urls):self?.status.stringValue="Saved: "+urls.map(\.lastPathComponent).joined(separator:", ");case .failure(let error):self?.status.stringValue=error.localizedDescription}
        }
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func choosePDF() {
        let picker=NSOpenPanel();picker.allowedContentTypes=[.pdf];picker.canChooseDirectories=false;picker.allowsMultipleSelection=false
        guard picker.runModal() == .OK,let url=picker.url else{return}
        access=FolderAccessStore.Lease(entries:[],files:[url]);input=url
        do{let document=try PDFTools.readable(url);status.stringValue="\(url.lastPathComponent): \(document.pageCount) pages"}
        catch{status.stringValue=error.localizedDescription}
    }
    @objc func runTool(_ button:NSButton) {
        guard let input,let id=button.identifier?.rawValue,let tool=Tool.all.first(where:{$0.id==id}) else{return}
        model.submitWheelDrop(tool,urls:[input],destination:output)
    }
}
let app=NSApplication.shared
let delegate=PDFLiveDelegate();app.delegate=delegate;app.setActivationPolicy(.regular)
let menu=NSMenu(),item=NSMenuItem(),commands=NSMenu()
commands.addItem(withTitle:"Quit PDF Checks",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=commands;menu.addItem(item);app.mainMenu=menu
app.run()
