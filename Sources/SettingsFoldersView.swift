import SwiftUI
import AppKit

struct SettingsFoldersView:View {
    @ObservedObject var store:FolderAccessStore
    @State private var message=""
    var body:some View {
        VStack(alignment:.leading,spacing:3){
            Text("Folder Access").font(.system(size:11,weight:.medium)).padding(.leading,10)
            VStack(alignment:.leading,spacing:10){
                Text("Citrus saves results to Desktop. macOS asks you to allow each output folder once. Allowing a parent folder, such as your home folder, also covers every folder inside it.").font(.system(size:13,weight:.medium)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if store.entries.isEmpty {Text("No folders allowed yet.").font(.system(size:12)).foregroundStyle(.secondary).padding(.vertical,5)}
                ForEach(store.entries){entry in
                    HStack(spacing:8){Image(nsImage:NSWorkspace.shared.icon(forFile:entry.path)).resizable().frame(width:20,height:20)
                        VStack(alignment:.leading,spacing:1){Text(URL(fileURLWithPath:entry.path).lastPathComponent).font(.system(size:13));Text(entry.path).font(.system(size:10.5,weight:.medium)).foregroundStyle(.secondary).lineLimit(1)}
                        Spacer();Button{store.remove(entry)}label:{Image(systemName:"minus.circle").font(.system(size:13)).foregroundStyle(.secondary)}.buttonStyle(.plain).help("Remove folder access")
                    }.padding(8).background(Color.white.opacity(0.025),in:RoundedRectangle(cornerRadius:6))
                }
                HStack{Spacer();Button("Add Folder…"){choose()}.buttonStyle(.plain).foregroundColor(Color(red:1,green:0.32,blue:0)).font(.system(size:13)).padding(.horizontal,7).frame(height:24)}
            }.padding(11).background(Color.white.opacity(0.022),in:RoundedRectangle(cornerRadius:12))
            if !message.isEmpty {Text(message).font(.system(size:11)).foregroundStyle(.secondary).padding(.top,6)}
        }
    }
    private func choose(){
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.prompt="Allow Access"
        if panel.runModal() == .OK,let url=panel.url {do{try store.add(url);message=""}catch{message=error.localizedDescription}}
    }
}
