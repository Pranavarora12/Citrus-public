import SwiftUI

struct SettingsControlMenu:View {
    let title:String
    @Binding var selection:String
    let choices:[SettingsCatalog.Choice]
    var width:CGFloat?=nil
    var preview=false
    private var label:some View {
        HStack(spacing:6){Text(choices.first{$0.value==selection}?.label ?? selection).lineLimit(1).layoutPriority(1);Spacer(minLength:0);Image(systemName:"chevron.up.chevron.down").font(.system(size:10,weight:.semibold)).fixedSize()}
            .font(.system(size:13)).padding(.horizontal,9).frame(maxWidth:.infinity).frame(height:24).background(Color.white.opacity(0.075),in:RoundedRectangle(cornerRadius:6))
    }
    var body:some View {
        HStack(spacing:8){if !title.isEmpty {Text(title).font(.system(size:13)).fixedSize()}
            Group{if preview {label}else{Menu{ForEach(choices){choice in Button{selection=choice.value}label:{if choice.value==selection {Label(choice.label,systemImage:"checkmark")}else{Text(choice.label)}}}}label:{label}.menuStyle(.borderlessButton).menuIndicator(.hidden)}}.frame(width:width)
            if width != nil {Spacer(minLength:0)}
        }.frame(height:24)
    }
}

struct SettingsFormatPane:View {
    @ObservedObject var model:AppModel
    var preview=false
    var initialFormat="jpg"
    @State private var selected="jpg"
    @State private var search=""
    private let accent=Color(red:1,green:0.32,blue:0)
    init(model:AppModel,preview:Bool=false,initialFormat:String="jpg"){
        self.model=model;self.preview=preview;self.initialFormat=initialFormat;_selected=State(initialValue:initialFormat)
    }
    private var values:[String:String]{SettingsCatalog.defaults(selected).merging(model.formatDefaults[selected] ?? [:]){_,new in new}}
    private func selection(_ key:String,default fallback:String)->Binding<String>{Binding(get:{values[key] ?? fallback},set:{model.formatDefaults[selected,default:[:]][key]=$0})}
    private var filtered:[SettingsCatalog.Group]{SettingsCatalog.groups.compactMap{group in let f=group.formats.filter{search.isEmpty || $0.localizedCaseInsensitiveContains(search)};return f.isEmpty ? nil:.init(name:group.name,icon:group.icon,formats:f)}}
    var body:some View {
        HStack(spacing:0){
            VStack(spacing:6){
                HStack(spacing:5){Image(systemName:"magnifyingglass").foregroundStyle(.secondary);Group{if preview {Text("Search").foregroundStyle(.secondary);Spacer()}else{TextField("Search",text:$search).textFieldStyle(.plain)}}}.font(.system(size:13)).padding(.horizontal,7).frame(height:24).background(Color.black.opacity(0.42),in:RoundedRectangle(cornerRadius:5)).padding(.horizontal,6)
                if preview {list.fixedSize(horizontal:false,vertical:true).offset(y:-previewOffset).frame(height:470,alignment:.top).clipped()}else{ScrollView{list}}
            }.padding(.top,0).frame(width:125)
            Rectangle().fill(Color.white.opacity(0.10)).frame(width:0.5).padding(.vertical,6)
            Group{if preview {inspector.frame(maxHeight:.infinity,alignment:.top)}else{ScrollView{inspector}}}.padding(.leading,12).padding(.trailing,10).padding(.top,0)
        }.frame(height:506).background(Color.white.opacity(0.022),in:RoundedRectangle(cornerRadius:12))
    }
    private var previewOffset:CGFloat {
        var y:CGFloat=0
        for group in filtered {y+=22;for format in group.formats {if format==selected{return max(0,y-130)};y+=28}}
        return 0
    }
    private var list:some View {
        VStack(alignment:.leading,spacing:2){ForEach(filtered){group in
            Text(group.name).font(.system(size:10,weight:.medium)).foregroundColor(Color.white.opacity(0.22)).padding(.leading,8).padding(.top,5).frame(height:20,alignment:.bottomLeading)
            ForEach(group.formats,id:\.self){format in Button{selected=format}label:{Text(format.uppercased()).font(.system(size:13)).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,8).frame(height:26).background(selected==format ? accent.opacity(0.18):Color.clear,in:RoundedRectangle(cornerRadius:6))}.buttonStyle(.plain).id(format)}
        }}.padding(.horizontal,5).padding(.bottom,6)
    }
    private var inspector:some View {
        VStack(alignment:.leading,spacing:0){
            Text("\(selected.uppercased()) Settings").font(.system(size:15,weight:.bold)).frame(height:22,alignment:.leading)
            Text(SettingsCatalog.description(selected)).font(.system(size:10.5,weight:.medium)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).padding(.top,9)
            if SettingsCatalog.inputOnly.contains(selected){
                Text("Conversion defaults are configured on the output format you choose.").font(.system(size:10.5,weight:.medium)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).padding(.top,12)
            }else if SettingsCatalog.controls(selected).isEmpty && !SettingsCatalog.preservesMetadata(selected){
                Text("This output format has no adjustable conversion defaults.").font(.system(size:10.5,weight:.medium)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).padding(.top,12)
            }else{
                Text("Conversion Settings").font(.system(size:13,weight:.bold)).padding(.top,12).padding(.bottom,8)
                VStack(alignment:.leading,spacing:8){ForEach(SettingsCatalog.controls(selected)){control in
                    SettingsControlMenu(title:control.title,selection:selection(control.key,default:control.defaultValue),choices:control.choices,width:controlWidth(control.key),preview:preview)
                }
                if SettingsCatalog.preservesMetadata(selected){metadataToggle}
                }
                if let text=SettingsCatalog.explanation(selected,values){Text(text).font(.system(size:10.5,weight:.medium)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).padding(.top,8)}
                restore("Restore Defaults"){model.formatDefaults.removeValue(forKey:selected)}.padding(.top,10)
            }
            if ["jpg","png"].contains(selected){imageCompression.padding(.top,12)}
            if SettingsCatalog.groups[4].formats.contains(selected){videoCompression.padding(.top,12)}
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,12)
    }
    private func controlWidth(_ key:String)->CGFloat? {
        switch key{case "qualityPreset":return 134;case "audioBitrate":return 92;case "audioBitDepth":return 144;case "flacCompression","archiveCompression":return 124;case "gifFrameRate":return 86;case "gifMaxWidth":return 95;case "maxVideoHeight":return 94;default:return nil}
    }
    private var metadataToggle:some View {
        Button{model.formatDefaults[selected,default:[:]]["preserveMetadata"] = values["preserveMetadata"]=="false" ? "true":"false"}label:{HStack(spacing:5){
            ZStack{RoundedRectangle(cornerRadius:5).fill(values["preserveMetadata"]=="false" ? Color.white.opacity(0.12):accent).frame(width:16,height:16);if values["preserveMetadata"] != "false" {Image(systemName:"checkmark").font(.system(size:13,weight:.bold)).foregroundColor(.white)}}
            Text("Preserve metadata").font(.system(size:13));Spacer()
        }}.buttonStyle(.plain)
    }
    private func restore(_ title:String,action:@escaping()->Void)->some View {
        HStack{Spacer();Button(action:action){Text(title).font(.system(size:11,weight:.medium)).foregroundColor(accent).padding(.horizontal,6).frame(height:22).background(accent.opacity(0.025),in:RoundedRectangle(cornerRadius:4))}.buttonStyle(.plain)}
    }
    private func segment(_ title:String,selection:Binding<String>)->some View {
        HStack(spacing:8){Text(title).font(.system(size:13));HStack(spacing:0){ForEach(["balanced","strong"],id:\.self){value in Button{selection.wrappedValue=value}label:{Text(value.capitalized).font(.system(size:13,weight:.medium)).padding(.horizontal,9).frame(height:24).background(selection.wrappedValue==value ? accent:Color.clear,in:RoundedRectangle(cornerRadius:6))}.buttonStyle(.plain)}}.background(Color.white.opacity(0.065),in:RoundedRectangle(cornerRadius:6));Spacer(minLength:0)}
    }
    private var imageCompression:some View {
        VStack(alignment:.leading,spacing:8){Divider().padding(.bottom,4);Text("Image Compression").font(.system(size:13,weight:.bold))
            segment("Compression",selection:$model.imageCompressionStrength)
            SettingsControlMenu(title:"Image size",selection:$model.imageCompressionSize,choices:SettingsCatalog.choices([("0","Keep original dimensions"),("2560","2560 px longest edge"),("1920","1920 px longest edge"),("1280","1280 px longest edge")]),preview:preview)
            restore("Restore Compression Defaults"){model.imageCompressionStrength="balanced";model.imageCompressionSize="0"}
        }
    }
    private var videoCompression:some View {
        VStack(alignment:.leading,spacing:8){Divider().padding(.bottom,4);Text("Compression Settings").font(.system(size:13,weight:.bold))
            segment("Compression",selection:$model.videoCompressionStrength)
            Text(model.videoCompressionStrength=="strong" ? "Much smaller files with more visible quality loss.":"Better visual quality with moderate file-size savings.").font(.system(size:10.5,weight:.medium)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            restore("Restore Compression Defaults"){model.videoCompressionStrength="balanced"}
        }
    }
}
