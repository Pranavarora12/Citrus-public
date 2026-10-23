import SwiftUI
import AppKit
import PDFKit

/// Deterministic layout preview only. The live panels use native glass and
/// sample the actual desktop; this blue backdrop never enters the live UI.
@MainActor
func writePDFToolPreview(to output:URL,kind:String,input:URL)throws {
    guard let document=PDFDocument(url:input),!document.isLocked,document.pageCount>0 else{
        throw NSError(domain:"PDFToolPreview",code:1,userInfo:[NSLocalizedDescriptionKey:"Choose a readable, unlocked PDF for the preview."])
    }
    let destination=input.deletingLastPathComponent()
    let content:AnyView
    let size:CGSize
    switch kind.lowercased(){
    case "organize","organizer":
        size=CGSize(width:560,height:600)
        content=AnyView(PDFEditorView(url:input,destination:destination,onSave:{_ in},onClose:{},preview:true))
    case "compress","compression":
        size=CGSize(width:376,height:376)
        content=AnyView(PDFCompressView(url:input,destination:destination,onSave:{_ in},onClose:{},preview:true))
    case "metadata":
        size=CGSize(width:464,height:540)
        content=AnyView(PDFMetadataView(url:input,destination:destination,onSave:{_ in},onClose:{},preview:true))
    default:
        throw NSError(domain:"PDFToolPreview",code:2,userInfo:[NSLocalizedDescriptionKey:"Choose organize, compress, or metadata for the PDF preview."])
    }
    let preview=ZStack{
        LinearGradient(stops:[.init(color:Color(red:0.08,green:0.40,blue:0.60),location:0),.init(color:Color(red:0.20,green:0.43,blue:0.58),location:0.62),.init(color:Color(red:0.23,green:0.34,blue:0.34),location:1)],startPoint:.top,endPoint:.bottom)
        content
    }.frame(width:size.width,height:size.height).clipShape(RoundedRectangle(cornerRadius:20,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:20,style:.continuous).strokeBorder(.white.opacity(0.25),lineWidth:0.5))
        .preferredColorScheme(.dark).transaction{$0.animation=nil}
    // AppKit controls and scroll views cannot be flattened by ImageRenderer.
    // An ordered-out window supplies their native layout/backing environment
    // without appearing on the desktop or becoming the key window.
    let host=NSHostingView(rootView:preview)
    host.frame=NSRect(origin:.zero,size:size)
    let window=NSWindow(contentRect:NSRect(x:-20000,y:-20000,width:size.width,height:size.height),styleMask:[.borderless],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear
    window.appearance=NSAppearance(named:.darkAqua);window.contentView=host
    defer{window.orderOut(nil);window.contentView=nil;window.close()}
    host.layoutSubtreeIfNeeded();window.display()
    RunLoop.main.run(until:Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded();host.displayIfNeeded()
    guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width*2),pixelsHigh:Int(size.height*2),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else{
        throw NSError(domain:"PDFToolPreview",code:3,userInfo:[NSLocalizedDescriptionKey:"Could not allocate the PDF tool preview."])
    }
    bitmap.size=size
    host.cacheDisplay(in:host.bounds,to:bitmap)
    guard let png=bitmap.representation(using:.png,properties:[:]) else{
        throw NSError(domain:"PDFToolPreview",code:3,userInfo:[NSLocalizedDescriptionKey:"Could not render the PDF tool preview."])
    }
    try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
    try png.write(to:output,options:.atomic)
}
