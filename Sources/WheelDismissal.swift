import AppKit

/// Scoped to one wheel. Finder does not always send a destination draggingEnded
/// callback when the user drops elsewhere, so also observe the drag's release.
final class WheelDismissal {
    private let startedDragging:Bool
    private let onDismiss:()->Void
    private var active=true
    private var releaseWork:DispatchWorkItem?
    private var timer:Timer?
    private var globalMonitor:Any?
    private var localMonitor:Any?

    init(startedDragging:Bool,window:NSWindow?=nil,installMonitors:Bool=true,onDismiss:@escaping()->Void) {
        self.startedDragging=startedDragging;self.onDismiss=onDismiss
        guard installMonitors else{return}
        let events:NSEvent.EventTypeMask=[.leftMouseUp,.rightMouseUp,.otherMouseUp,.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown]
        globalMonitor=NSEvent.addGlobalMonitorForEvents(matching:events){[weak self] event in
            if event.type == .keyDown {if event.keyCode==53 {self?.dismiss()}}
            else if [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(event.type) {self?.dismiss()}
            else {self?.dragReleased()}
        }
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:events){[weak self,weak window] event in
            if event.type == .keyDown,event.keyCode==53 {self?.dismiss();return nil}
            if [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(event.type),event.window !== window {self?.dismiss()}
            if [.leftMouseUp,.rightMouseUp,.otherMouseUp].contains(event.type) {self?.dragReleased()}
            return event
        }
        if startedDragging {
            let polling=Timer(timeInterval:0.05,repeats:true){[weak self,weak window] _ in
                guard window?.isVisible == true else{self?.invalidate();return}
                self?.samplePressedButtons(NSEvent.pressedMouseButtons)
            }
            timer=polling;RunLoop.main.add(polling,forMode:.common)
        }
    }
    func samplePressedButtons(_ buttons:Int){if startedDragging && buttons==0 {dragReleased()}}
    func dragReleased(){
        guard active,startedDragging,releaseWork==nil else{return}
        // Let AppKit deliver a valid performDragOperation before hiding the panel.
        let work=DispatchWorkItem{[weak self] in self?.dismiss()}
        releaseWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
    }
    func dismiss(){guard active else{return};invalidate();onDismiss()}
    func invalidate(){
        active=false;releaseWork?.cancel();releaseWork=nil;timer?.invalidate();timer=nil
        if let monitor=globalMonitor {NSEvent.removeMonitor(monitor)};globalMonitor=nil
        if let monitor=localMonitor {NSEvent.removeMonitor(monitor)};localMonitor=nil
    }
    deinit{invalidate()}
}
