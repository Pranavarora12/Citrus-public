import SwiftUI

struct SettingsCompatibilityView:View {
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            Label("Format Compatibility",systemImage:"tablecells").font(.system(size:10.5,weight:.medium)).padding(.leading,9)
            ForEach(SettingsCatalog.groups){group in
                VStack(alignment:.leading,spacing:8){
                    Label(group.name,systemImage:group.icon).font(.system(size:12,weight:.semibold)).padding(.leading,5)
                    CompatibilityTable(group:group)
                }.padding(10).background(Color.white.opacity(0.015),in:RoundedRectangle(cornerRadius:10))
            }
        }
    }
}
private struct CompatibilityTable:View {
    let group:SettingsCatalog.Group
    @State private var hoveredSource:String?
    @State private var hoveredTarget:String?
    private var columns:[String]{
        switch group.name {
        case "Images":return ["jpg","png","webp","heic","tiff","avif","bmp","pdf"]
        case "Documents":return ["pdf","docx","pages","pptx","txt","md","html","epub","jpg","png","xlsx"]
        case "Spreadsheets":return ["xlsx","ods","csv","tsv","pdf"]
        case "Video":return ["mp4","mov","mkv","webm","avi","wmv","gif","mp3"]
        case "Archives":return ["zip","tar","gzip"]
        case "Subtitles":return ["srt","vtt","txt"]
        default:return group.formats
        }
    }
    var body:some View {
        VStack(spacing:0){
            HStack(spacing:0){cell("↱",header:true).frame(width:41);ForEach(columns,id:\.self){target in cell(target.uppercased(),header:true).background(hoveredTarget==target ? Color.orange.opacity(0.09):Color.clear)}}
            ForEach(Array(group.formats.filter{$0 != "html"}.enumerated()),id:\.element){index,source in
                HStack(spacing:0){cell(source=="textclipping" ? "TEXTCLIP…":source.uppercased(),header:true).frame(width:41).background(hoveredSource==source ? Color.orange.opacity(0.09):Color.clear)
                    ForEach(columns,id:\.self){target in
                        let supported=SettingsCatalog.targets(source).contains(target)
                        cell(supported ? "✓":"–",header:false).opacity(supported ? 0.85:0.2).help("\(source.uppercased()) → \(target.uppercased())")
                            .onHover{inside in hoveredSource=inside ? source:nil;hoveredTarget=inside ? target:nil}
                    }
                }.background(index%2==0 ? Color.white.opacity(0.012):Color.clear)
            }
        }.background(Color.black.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius:6))
    }
    private func cell(_ text:String,header:Bool)->some View {
        Text(text).font(.system(size:header ? 8.5:12,weight:header ? .semibold:.medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth:.infinity).frame(height:23).overlay(alignment:.trailing){Rectangle().fill(Color.white.opacity(0.035)).frame(width:0.5)}.overlay(alignment:.bottom){Rectangle().fill(Color.white.opacity(0.035)).frame(height:0.5)}
    }
}
