import AppKit
import Foundation

func measureWheelHover() throws {
    let wheel=WheelDropView(group:"Conversions",inputs:[URL(fileURLWithPath:"/tmp/sample.wav")],onDrop:{_,_ in},onClose:{})
    let host=wheel.materialBackdrop(frame:wheel.frame)
    _ = host
    let pixels=Int(WheelDropView.designSize)
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context=NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    let cg=context.cgContext;cg.translateBy(x:0,y:CGFloat(pixels));cg.scaleBy(x:1,y:-1)
    NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
    wheel.draw(wheel.bounds);wheel.needsDisplay=false
    var durations:[Double]=[]
    for i in 0..<600 {
        let began=ProcessInfo.processInfo.systemUptime
        wheel.highlighted=i%wheel.current.count
        durations.append((ProcessInfo.processInfo.systemUptime-began)*1000)
    }
    NSGraphicsContext.restoreGraphicsState()
    durations.sort()
    print("Offscreen hover-update CPU benchmark (excludes screen/compositor/audio): transitions=600 median_ms=\(durations[300]) p95_ms=\(durations[570]) max_ms=\(durations.last!)")
    withExtendedLifetime(host){}
}
