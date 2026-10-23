import AppKit
import SwiftUI

final class ImageLiveDelegate:NSObject,NSApplicationDelegate {
    let model=AppModel()
    var window:NSWindow!
    var input:URL {Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("image-tool-audit/Image Fixture.png")}
    var output:URL {Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("image-live-results",isDirectory:true)}
    let status=NSTextField(labelWithString:"Use these buttons to exercise the actual Command-wheel dispatch path.")
    func applicationDidFinishLaunching(_ notification:Notification){
        window=NSWindow(contentRect:NSRect(x:250,y:220,width:800,height:150),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="Citrus Image Live Checks";window.isReleasedWhenClosed=false
        let stack=NSStackView();stack.orientation = .vertical;stack.spacing=14;stack.alignment = .leading
        let row=NSStackView();row.spacing=8
        for (name,id) in [("Compress","compress"),("Metadata","removeMetadata"),("Edit","editImage"),("Annotate","annotateImage"),("Add BG","frameImage"),("Crop","cropImage"),("Redact","redactImage")] {
            let button=NSButton(title:name,target:self,action:#selector(runTool(_:)));button.identifier=NSUserInterfaceItemIdentifier(id);row.addArrangedSubview(button)
        }
        let audit=NSButton(title:"Run Image Audit",target:self,action:#selector(runAudit));row.addArrangedSubview(audit)
        stack.addArrangedSubview(status);stack.addArrangedSubview(row);stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20)])
        model.onJobFinished={[weak self] result in switch result{case .success(let urls):self?.status.stringValue="Saved: "+urls.map(\.lastPathComponent).joined(separator:", ");case .failure(let error):self?.status.stringValue=error.localizedDescription}}
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @MainActor @objc func runAudit(){
        status.stringValue="Running image audit…"
        Task { @MainActor in
            do{try await ImageToolTests.run(in:Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("image-live-audit"));status.stringValue="Image audit passed, including live Vision OCR."}
            catch{status.stringValue="Audit failed: \(error)"}
        }
    }
    @objc func runTool(_ button:NSButton){guard let id=button.identifier?.rawValue,let tool=Tool.all.first(where:{$0.id==id}) else{return};model.submitWheelDrop(tool,urls:[input],destination:output)}
}
let app=NSApplication.shared,delegate=ImageLiveDelegate();app.delegate=delegate;app.setActivationPolicy(.regular)
let menu=NSMenu(),item=NSMenuItem(),commands=NSMenu();commands.addItem(withTitle:"Quit Image Checks",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=commands;menu.addItem(item);app.mainMenu=menu
app.run()
