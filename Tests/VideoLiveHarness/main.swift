import AppKit
import SwiftUI
final class VideoLiveDelegate:NSObject,NSApplicationDelegate {
    let model=AppModel()
    var window:NSWindow!
    var base:URL {Bundle.main.bundleURL.deletingLastPathComponent()}
    var input:URL {base.appendingPathComponent("video-tool-audit/Video Fixture.mov")}
    let status=NSTextField(labelWithString:"Video wheel checks — all buttons use the actual drop dispatch.")
    func applicationDidFinishLaunching(_ notification:Notification){
        window=NSWindow(contentRect:NSRect(x:200,y:200,width:930,height:190),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="Citrus Video Live Checks";window.isReleasedWhenClosed=false
        let stack=NSStackView();stack.orientation = .vertical;stack.spacing=15;stack.alignment = .leading
        stack.addArrangedSubview(status)
        let row=NSStackView();row.spacing=8
        for id in VideoTools.singleToolIDs+["joinVideos"]{let button=NSButton(title:id=="removeMetadata" ? "Metadata":id=="changeVideoSpeed" ? "Speed":id=="videoSnapshots" ? "Snapshots":Tool.all.first{$0.id==id}!.name,target:self,action:#selector(runTool(_:)));button.identifier=NSUserInterfaceItemIdentifier(id);row.addArrangedSubview(button)}
        stack.addArrangedSubview(row)
        let ref=NSButton(title:"Choose Reference Video…",target:self,action:#selector(useReference));stack.addArrangedSubview(ref)
        let wheel=WheelDropView(group:"Tools",inputs:[input],onDrop:{[weak self] tool,urls in self?.model.submitWheelDrop(tool,urls:urls,destination:self?.base.appendingPathComponent("video-live-results"))},onClose:{})
        wheel.setFrameSize(NSSize(width:262,height:262));let panel=NSPanel(contentRect:NSRect(x:60,y:300,width:262,height:262),styleMask:.borderless,backing:.buffered,defer:false);panel.contentView=wheel;panel.isOpaque=false;panel.backgroundColor = .clear;panel.makeKeyAndOrderFront(nil);model.shelves.append(panel)
        stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20)])
        model.onJobFinished={[weak self] result in switch result{case .success(let urls):self?.status.stringValue="Saved: "+urls.map(\.lastPathComponent).joined(separator:", ");case .failure(let error):self?.status.stringValue=error.localizedDescription}}
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    var reference:URL?
    @objc func useReference(){let picker=NSOpenPanel();picker.canChooseDirectories=false;picker.allowsMultipleSelection=false;guard picker.runModal() == .OK,let url=picker.url else{return};reference=url;status.stringValue="Using reference: "+url.lastPathComponent}
    @objc func runTool(_ button:NSButton){guard let id=button.identifier?.rawValue,let tool=Tool.all.first(where:{$0.id==id}) else{return};let url=reference ?? input;model.submitWheelDrop(tool,urls:id=="joinVideos" ? [url,base.appendingPathComponent("video-tool-audit/Silent.mp4")]:[url],destination:base.appendingPathComponent("video-live-results"))}
}
let app=NSApplication.shared,delegate=VideoLiveDelegate();app.delegate=delegate;app.setActivationPolicy(.regular)
let menu=NSMenu(),item=NSMenuItem(),commands=NSMenu();commands.addItem(withTitle:"Quit Video Checks",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=commands;menu.addItem(item);app.mainMenu=menu
app.run()
