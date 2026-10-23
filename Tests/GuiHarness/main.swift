import AppKit
import Foundation

final class WheelTestDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    var label:NSTextField!
    var previewModel:AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
    func applicationDidFinishLaunching(_ note:Notification) {
        window=NSWindow(contentRect:NSRect(x:260,y:280,width:600,height:180),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="Citrus Wheel Verification"
        label=NSTextField(wrappingLabelWithString:"Running file-drop and background-processing checks…")
        label.frame=NSRect(x:20,y:30,width:560,height:120);window.contentView?.addSubview(label);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        Timer.scheduledTimer(withTimeInterval:0.1,repeats:false) {_ in
            let log=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wheel-tests.log")
            FileManager.default.createFile(atPath:log.path,contents:nil)
            let handle=try! FileHandle(forWritingTo:log)
            dup2(handle.fileDescriptor,STDOUT_FILENO);dup2(handle.fileDescriptor,STDERR_FILENO);setbuf(stdout,nil);setbuf(stderr,nil)
            do {try SelfTests.run(requirePasteboard:true);self.label.stringValue="PASS — Native file drops and background export verified.\nSee build/wheel-tests.log."
                let preview=AppModel();preview.hapticsEnabled=false
                if let sample=Bundle.main.url(forResource:"sample",withExtension:"png") {preview.files=[sample]}
                self.previewModel=preview;self.window.orderOut(nil);preview.showWheel("Tools")}
            catch {print("GUI TEST FAILED: \(error)");self.label.stringValue="FAILED — \(error.localizedDescription)"}
            fflush(stdout);fflush(stderr)
        }
    }
}
let app=NSApplication.shared
let delegate=WheelTestDelegate()
app.delegate=delegate
app.setActivationPolicy(.regular)
let menu=NSMenu();let item=NSMenuItem();let commands=NSMenu();commands.addItem(withTitle:"Quit Verification",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=commands;menu.addItem(item);app.mainMenu=menu
app.run()
