import AppKit

enum AppBrand {
    static let image:NSImage = {
        let checkout=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.png")
        for url in [Bundle.main.url(forResource:"AppIcon",withExtension:"png"),checkout].compactMap({$0}) {
            if let image=NSImage(contentsOf:url) {return image}
        }
        return NSImage(named:NSImage.applicationIconName) ?? NSImage(size:NSSize(width:512,height:512))
    }()
    static var menuImage:NSImage {
        let icon=image.copy() as! NSImage
        icon.size=NSSize(width:18,height:18);icon.isTemplate=false
        icon.accessibilityDescription="Citrus"
        return icon
    }
}
