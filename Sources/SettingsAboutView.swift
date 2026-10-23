import SwiftUI
import AppKit

struct SettingsAboutView:View {
    var body:some View {
        VStack(spacing:0){
            Spacer()
            Image(nsImage:AppBrand.image).resizable().interpolation(.high).scaledToFit().frame(width:58,height:58).accessibilityLabel("Citrus app icon").shadow(color:.black.opacity(0.15),radius:2,y:1)
            Text("Citrus").font(.system(size:18,weight:.bold)).padding(.top,18)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.2.0")").font(.system(size:13,weight:.medium)).foregroundStyle(.secondary).padding(.top,12)
            Label("Local processing",systemImage:"checkmark.seal.fill").font(.system(size:13,weight:.medium)).foregroundStyle(.secondary).padding(.top,20)
            Text("No account required").font(.system(size:11)).foregroundStyle(.secondary).padding(.top,6)
            Button("Support"){let alert=NSAlert();alert.messageText="Using Citrus";alert.informativeText="Drag a file and tap Shift for conversions, Command for tools, or Control for actions. Drop on an option to apply it. Results are saved to Desktop. Use General to customize the modifiers and feedback.";alert.addButton(withTitle:"OK");alert.runModal()}.buttonStyle(.plain).font(.system(size:13)).foregroundColor(.blue).padding(.top,24)
            Spacer()
        }.frame(maxWidth:.infinity).frame(height:506)
    }
}
