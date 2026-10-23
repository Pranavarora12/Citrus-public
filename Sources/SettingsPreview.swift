import SwiftUI
import AppKit

@MainActor func writeSettingsPreview(to url:URL,tab:String="General",format:String="jpg")throws {
    let renderer=ImageRenderer(content:SettingsView(model:AppModel(),preview:true,initialTab:tab,initialFormat:format))
    renderer.proposedSize=ProposedViewSize(width:456,height:592);renderer.scale=2
    guard let image=renderer.cgImage else{throw UIError.message("Could not render settings preview.")}
    let bitmap=NSBitmapImageRep(cgImage:image)
    guard let data=bitmap.representation(using:.png,properties:[:]) else{throw UIError.message("Could not encode settings preview.")}
    try data.write(to:url)
}
