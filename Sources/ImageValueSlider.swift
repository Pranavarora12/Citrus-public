import SwiftUI

/// Native panel slider with the orange track used by the recorded editors.
struct ImageValueSlider:View {
    @Binding var value:Double
    var range:ClosedRange<Double>
    var step:Double
    @Environment(\.isEnabled) private var enabled
    init(value:Binding<Double>,in range:ClosedRange<Double>,step:Double=0.01){_value=value;self.range=range;self.step=step}
    var body:some View {
        GeometryReader{geometry in
            let width=max(1,geometry.size.width-12),fraction=max(0,min(1,(value-range.lowerBound)/(range.upperBound-range.lowerBound))),progress=CGFloat(fraction)*width
            ZStack(alignment:.leading){
                Capsule().fill(.white.opacity(0.22)).frame(height:4)
                Capsule().fill(pdfToolOrange).frame(width:progress+6,height:4)
                Capsule().fill(.white.opacity(0.9)).frame(width:12,height:14).offset(x:progress)
            }.frame(height:20).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{event in
                let fraction=Double(max(0,min(width,event.location.x-6))/width)
                let raw=range.lowerBound+fraction*(range.upperBound-range.lowerBound)
                value=max(range.lowerBound,min(range.upperBound,(raw/step).rounded()*step))
            })
        }.frame(height:20).opacity(enabled ? 1:0.4)
            .accessibilityRepresentation{Slider(value:$value,in:range,step:step)}
    }
}
