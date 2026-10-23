import SwiftUI
import AppKit
import ServiceManagement

/// The application's settings window; drag wheels operate independently.
struct SettingsView:View {
    @ObservedObject var model:AppModel
    var preview=false
    @State private var selectedTab="General"
    @State private var loginEnabled=false
    @State private var loginMessage=""
    @State private var selectedFormat="jpg"
    @State private var formatSearch=""
    private let tabs=["General","Formats","Compatibility","Folders","About"]
    private let orange=Color(red:1,green:0.32,blue:0)
    private let background=Color(red:0.16,green:0.18,blue:0.192)
    private let cardColor=Color(red:0.185,green:0.205,blue:0.216)
    private let controlColor=Color(red:0.25,green:0.275,blue:0.286)
    var initialTab="General"
    var initialFormat="jpg"
    init(model:AppModel,preview:Bool=false,initialTab:String="General",initialFormat:String="jpg"){
        self.model=model;self.preview=preview;self.initialTab=initialTab;self.initialFormat=initialFormat;_selectedTab=State(initialValue:initialTab)
    }
    var body:some View {
        VStack(spacing:0){
            HStack{Text("Citrus Settings").font(.system(size:14,weight:.bold)).foregroundStyle(.secondary);Spacer()}
                .padding(.leading,84).frame(height:32).background(Color(red:0.135,green:0.155,blue:0.165))
            Rectangle().fill(Color.black.opacity(0.22)).frame(height:1)
            tabBar.padding(.top,8).padding(.bottom,5)
            if preview || selectedTab=="Formats" || selectedTab=="About" {settingsContent.fixedSize(horizontal:false,vertical:true).frame(width:456,height:522,alignment:.top).clipped()}else{ScrollView{settingsContent}.scrollIndicators(.hidden)}
        }.frame(width:456,height:592).background(background).ignoresSafeArea().environment(\.colorScheme,.dark).foregroundColor(Color.white.opacity(0.86)).tint(orange)
        .onAppear{loginEnabled=SMAppService.mainApp.status == .enabled}
    }
    private var settingsContent:some View {
        Group{
            switch selectedTab {
            case "General": general
            case "Formats": SettingsFormatPane(model:model,preview:preview,initialFormat:initialFormat)
            case "Compatibility": SettingsCompatibilityView()
            case "Folders": SettingsFoldersView(store:model.folderAccess)
            default: SettingsAboutView()
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,selectedTab=="Formats" ? 13:17).padding(.bottom,18)
    }
    private var tabBar:some View {
        HStack(spacing:0){
            ForEach(Array(tabs.enumerated()),id:\.element){index,tab in
                if index>0 {Rectangle().fill(Color.white.opacity(0.10)).frame(width:1,height:14).opacity(selectedTab==tab || selectedTab==tabs[index-1] ? 0:1)}
                Button{selectedTab=tab} label:{Text(tab).font(.system(size:13,weight:.semibold)).fixedSize().padding(.horizontal,10.2).frame(height:24).background(selectedTab==tab ? orange:Color.clear,in:RoundedRectangle(cornerRadius:6))}
                    .buttonStyle(.plain).accessibilityAddTraits(selectedTab==tab ? .isSelected:[])
            }
        }.background(Color(red:0.20,green:0.22,blue:0.23),in:RoundedRectangle(cornerRadius:6))
    }
    private func heading(_ text:String)->some View {Text(text).font(.system(size:11,weight:.medium)).padding(.leading,10).padding(.bottom,3)}
    private func checkbox(_ label:String,isOn:Binding<Bool>)->some View {
        Button{isOn.wrappedValue.toggle()} label:{
            HStack(spacing:5){
                ZStack{RoundedRectangle(cornerRadius:5).fill(isOn.wrappedValue ? orange:controlColor).frame(width:16,height:16)
                    if isOn.wrappedValue {Image(systemName:"checkmark").font(.system(size:13,weight:.bold)).foregroundColor(.white)}
                }
                Text(label).font(.system(size:13));Spacer(minLength:0)
            }
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(isOn.wrappedValue ? "On":"Off")
    }
    private func divider()->some View {Rectangle().fill(Color.white.opacity(0.12)).frame(height:1)}
    private func menuLabel(_ text:String)->some View {
        HStack{Text(text).lineLimit(1);Spacer(minLength:8);Image(systemName:"chevron.up.chevron.down").font(.system(size:10,weight:.semibold))}
            .font(.system(size:13)).padding(.horizontal,11).frame(maxWidth:.infinity).frame(height:24).background(controlColor,in:RoundedRectangle(cornerRadius:6))
    }
    @ViewBuilder private func chooser<Choices:View>(_ title:String,@ViewBuilder choices:()->Choices)->some View {
        if preview {menuLabel(title)}else{
            Menu(content:choices,label:{menuLabel(title)}).menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth:.infinity)
        }
    }
    private func modifierRow(_ title:String,_ selection:Binding<String>)->some View {
        HStack(spacing:8){Text(title).font(.system(size:13)).fixedSize()
            chooser(modifierName(selection.wrappedValue)){
                ForEach(WheelShortcut.all){shortcut in Button{selection.wrappedValue=shortcut.value}label:{if selection.wrappedValue==shortcut.value {Label(shortcut.label,systemImage:"checkmark")}else{Text(shortcut.label)}}}
            }
        }.frame(height:24)
    }
    private func modifierName(_ value:String)->String {WheelShortcut.title(value)}
    private var general:some View {
        VStack(alignment:.leading,spacing:0){
            heading("Appearance")
            HStack(spacing:8){
                Text("Style").font(.system(size:13))
                HStack(spacing:0){
                    styleButton("Glass",solid:false);styleButton("Solid",solid:true)
                }.background(controlColor,in:RoundedRectangle(cornerRadius:6))
                Spacer()
            }.padding(11).frame(height:46).background(cardColor,in:RoundedRectangle(cornerRadius:12))
            heading("General").padding(.top,12)
            VStack(alignment:.leading,spacing:0){
                checkbox("Launch at Login",isOn:Binding(get:{loginEnabled},set:{setLogin($0)}))
                divider().padding(.vertical,10)
                checkbox("Haptic feedback",isOn:$model.hapticsEnabled)
                divider().padding(.vertical,10)
                Text("Drag Modifiers").font(.system(size:11,weight:.bold)).padding(.bottom,12)
                VStack(spacing:12){
                    modifierRow("Conversion wheel",$model.conversionModifier)
                    modifierRow("Tools wheel",$model.toolsModifier)
                    modifierRow("Actions wheel",$model.actionsModifier)
                }
                Text("Tap the chosen modifier combination while dragging files.").font(.system(size:10.5,weight:.medium)).foregroundStyle(.secondary).padding(.top,12)
                divider().padding(.vertical,10)
                HStack(spacing:8){Text("Float Behaviour").fixedSize()
                    chooser(model.floatReuse ? "Add Files to an Existing Float":"Create a New Float"){
                        Button("Create a New Float"){model.floatReuse=false}
                        Button("Add Files to an Existing Float"){model.floatReuse=true}
                    }.frame(width:222)
                    Spacer(minLength:0)
                }.font(.system(size:13))
                divider().padding(.vertical,10)
                HStack(spacing:8){Text("Terminal app").font(.system(size:13))
                    chooser(model.terminalApplication=="com.googlecode.iterm2" ? "iTerm2":"Terminal"){
                        Button("Terminal"){model.terminalApplication="com.apple.Terminal"}
                        if NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.googlecode.iterm2") != nil {Button("iTerm2"){model.terminalApplication="com.googlecode.iterm2"}}
                    }.frame(width:99)
                    Spacer()
                }
            }.padding(11).background(cardColor,in:RoundedRectangle(cornerRadius:12))
            if !loginMessage.isEmpty {Text(loginMessage).font(.system(size:10)).foregroundStyle(.secondary).padding(.top,6)}
        }
    }
    private func styleButton(_ title:String,solid:Bool)->some View {
        Button{model.solid=solid}label:{Text(title).font(.system(size:13,weight:.medium)).padding(.horizontal,10).frame(height:24).background(model.solid==solid ? orange:Color.clear,in:RoundedRectangle(cornerRadius:6))}.buttonStyle(.plain)
    }
    private func setLogin(_ enabled:Bool){
        do {if enabled {try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()}
            loginEnabled=SMAppService.mainApp.status == .enabled
            loginMessage=SMAppService.mainApp.status == .requiresApproval ? "Allow Citrus in System Settings → Login Items.":""
        }catch{loginEnabled=SMAppService.mainApp.status == .enabled;loginMessage=error.localizedDescription}
    }
}
