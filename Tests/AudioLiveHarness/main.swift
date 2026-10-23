import AppKit
final class AudioLiveDelegate:NSObject,NSApplicationDelegate {
    let model=AppModel()
    var window:NSWindow!
    var base:URL{Bundle.main.bundleURL.deletingLastPathComponent()}
    let status=NSTextField(labelWithString:"Audio Command wheel: Trim only. Exports use a separate test folder.")
    func applicationDidFinishLaunching(_ notification:Notification){
        window=NSWindow(contentRect:NSRect(x:200,y:200,width:620,height:140),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="Citrus Audio Trim Checks";window.isReleasedWhenClosed=false
        let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=15;stack.addArrangedSubview(status);stack.addArrangedSubview(NSButton(title:"Trim Audio",target:self,action:#selector(openTrim)));stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:18),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:18)])
        model.onJobFinished={[weak self] result in switch result{case .success(let urls):self?.status.stringValue="Saved: "+urls.map(\.lastPathComponent).joined(separator:", ");case .failure(let error):self?.status.stringValue=error.localizedDescription}}
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func openTrim(){model.submitWheelDrop(Tool.all.first{$0.id=="trimAudio"}!,urls:[base.appendingPathComponent("audio-trim-audit/Audio Fixture.wav")],destination:base.appendingPathComponent("audio-live-results"))}
}
let app=NSApplication.shared,delegate=AudioLiveDelegate();app.delegate=delegate;app.setActivationPolicy(.regular)
let menu=NSMenu(),item=NSMenuItem(),commands=NSMenu();commands.addItem(withTitle:"Quit Audio Checks",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=commands;menu.addItem(item);app.mainMenu=menu;app.run()
