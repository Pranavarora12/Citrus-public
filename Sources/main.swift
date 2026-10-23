import Foundation
import AppKit

if let option=CommandLine.arguments.firstIndex(of:"--audio-trim-audit"),CommandLine.arguments.count>option+1 {
    Task { @MainActor in
        do{try await AudioTrimTests.run(in:URL(fileURLWithPath:CommandLine.arguments[option+1]));exit(0)}catch{fputs("AUDIO TRIM AUDIT FAILED: \(error)\n",stderr);exit(1)}
    }
    RunLoop.main.run();exit(1)
}
if let option=CommandLine.arguments.firstIndex(of:"--video-tools-audit"),CommandLine.arguments.count>option+1 {
    Task { @MainActor in
        do{try await VideoToolTests.run(in:URL(fileURLWithPath:CommandLine.arguments[option+1]));exit(0)}catch{fputs("VIDEO TOOL AUDIT FAILED: \(error)\n",stderr);exit(1)}
    }
    RunLoop.main.run();exit(1)
}
if let option=CommandLine.arguments.firstIndex(of:"--image-tools-audit"),CommandLine.arguments.count>option+1 {
    Task { @MainActor in
        do{try await ImageToolTests.run(in:URL(fileURLWithPath:CommandLine.arguments[option+1]));exit(0)}catch{fputs("IMAGE TOOL AUDIT FAILED: \(error)\n",stderr);exit(1)}
    }
    RunLoop.main.run();exit(1)
}
if let option=CommandLine.arguments.firstIndex(of:"--render-image-tool-preview"),CommandLine.arguments.count>option+3 {
    Task { @MainActor in
        do{try writeImageToolPreview(to:URL(fileURLWithPath:CommandLine.arguments[option+1]),operation:CommandLine.arguments[option+2],input:URL(fileURLWithPath:CommandLine.arguments[option+3]));exit(0)}catch{fputs("Image preview failed: \(error)\n",stderr);exit(1)}
    }
    RunLoop.main.run();exit(1)
}
if let option=CommandLine.arguments.firstIndex(of:"--render-pdf-tool-preview"),CommandLine.arguments.count>option+3 {
    let output=URL(fileURLWithPath:CommandLine.arguments[option+1])
    let kind=CommandLine.arguments[option+2],input=URL(fileURLWithPath:CommandLine.arguments[option+3])
    Task { @MainActor in
        do{try writePDFToolPreview(to:output,kind:kind,input:input);exit(0)}catch{fputs("PDF preview failed: \(error)\n",stderr);exit(1)}
    }
    RunLoop.main.run();exit(1)
}
if let option=CommandLine.arguments.firstIndex(of:"--pdf-tools-audit"),CommandLine.arguments.count>option+1 {
    let output=URL(fileURLWithPath:CommandLine.arguments[option+1],isDirectory:true)
    let reference=CommandLine.arguments.firstIndex(of:"--reference").flatMap{$0+1<CommandLine.arguments.count ? URL(fileURLWithPath:CommandLine.arguments[$0+1]):nil}
    do{try PDFToolTests.run(in:output,reference:reference);exit(0)}catch{fputs("PDF TOOL AUDIT FAILED: \(error)\n",stderr);exit(1)}
}
if let option=CommandLine.arguments.firstIndex(of:"--render-settings-preview"),CommandLine.arguments.count>option+1 {
    let path=CommandLine.arguments[option+1]
    func argument(_ key:String,_ fallback:String)->String {if let i=CommandLine.arguments.firstIndex(of:key),i+1<CommandLine.arguments.count{return CommandLine.arguments[i+1]};return fallback}
    let tab=argument("--tab","General"),format=argument("--format","jpg")
    Task { @MainActor in
        do{try writeSettingsPreview(to:URL(fileURLWithPath:path),tab:tab,format:format);exit(0)}catch{fputs("Settings preview failed: \(error)\n",stderr);exit(1)}
    }
    RunLoop.main.run();exit(1)
}
if CommandLine.arguments.contains("--wheel-benchmark") {try measureWheelHover();exit(0)}
if let option=CommandLine.arguments.firstIndex(of:"--render-wheel-preview"),CommandLine.arguments.count>option+1 {
    let tools=CommandLine.arguments.contains("--tools")
    let inputIndex=CommandLine.arguments.firstIndex(of:"--input")
    let input=inputIndex.flatMap{$0+1<CommandLine.arguments.count ? CommandLine.arguments[$0+1]:nil} ?? (tools ? "/tmp/sample.png":"/tmp/sample.wav")
    let wheel=WheelDropView(group:tools ? "Tools":"Conversions",inputs:[URL(fileURLWithPath:input)],onDrop:{_,_ in},onClose:{})
    if let selected=CommandLine.arguments.firstIndex(of:"--selected"),CommandLine.arguments.count>selected+1,let index=Int(CommandLine.arguments[selected+1]),wheel.current.indices.contains(index) {wheel.highlighted=index}
    try wheel.writePreview(to:URL(fileURLWithPath:CommandLine.arguments[option+1]))
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    do {try SelfTests.run();exit(0)} catch {fputs("SELF-TEST FAILED: \(error)\n",stderr);exit(1)}
}

let application = NSApplication.shared
application.applicationIconImage=AppBrand.image
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
let appMenu = NSMenu()
let rootItem = NSMenuItem()
let commands = NSMenu()
let settingsCommand=NSMenuItem(title:"Settings…",action:#selector(MenuBridge.settings),keyEquivalent:",")
settingsCommand.target=MenuBridge.shared;commands.addItem(settingsCommand);commands.addItem(.separator())
commands.addItem(withTitle:"Quit Citrus",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
rootItem.submenu = commands
appMenu.addItem(rootItem)
application.mainMenu = appMenu
application.run()
