import Foundation

struct SettingsCatalog {
    struct Group:Identifiable {let name:String;let icon:String;let formats:[String];var id:String{name}}
    struct Choice:Identifiable {let value:String;let label:String;var id:String{value}}
    struct Control:Identifiable {let key:String;let title:String;let choices:[Choice];let defaultValue:String;var id:String{key}}
    static let groups:[Group]=[
        .init(name:"Images",icon:"photo",formats:["jpg","png","webp","heic","tiff","svg","avif","bmp"]),
        .init(name:"Documents",icon:"doc.text",formats:["pdf","docx","pages","ppt","pptx","txt","md","rtf","rtfd","textclipping","html","epub"]),
        .init(name:"Spreadsheets",icon:"tablecells",formats:["xlsx","xls","ods","csv","tsv"]),
        .init(name:"Audio",icon:"waveform",formats:["mp3","m4a","wav","flac","ogg","opus","aiff","wma"]),
        .init(name:"Video",icon:"film",formats:["mp4","mov","mkv","webm","avi","wmv","gif"]),
        .init(name:"Archives",icon:"archivebox",formats:["zip","tar","gzip","rar"]),
        .init(name:"Subtitles",icon:"captions.bubble",formats:["srt","vtt"])
    ]
    static let all=groups.flatMap(\.formats)
    static let inputOnly:Set<String>=["svg","ppt","rtf","rtfd","textclipping","xls","rar"]
    static let quality=[Choice(value:"smaller",label:"Smaller File"),Choice(value:"balanced",label:"Balanced"),Choice(value:"higher",label:"Higher Quality")]
    static let compression=[Choice(value:"faster",label:"Faster"),Choice(value:"balanced",label:"Balanced"),Choice(value:"smallest",label:"Smallest File")]
    static func choices(_ pairs:[(String,String)])->[Choice]{pairs.map{Choice(value:$0.0,label:$0.1)}}
    static func controls(_ format:String)->[Control] {
        let q=Control(key:"qualityPreset",title:"Quality",choices:quality,defaultValue:"balanced")
        if ["jpg","webp","heic","avif"].contains(format){return [q]}
        if ["docx","pages"].contains(format){return [.init(key:"pdfLayout",title:"PDF layout",choices:choices([("editable","Editable paragraphs"),("pages","Preserve original pages")]),defaultValue:"editable")]}
        if format=="epub"{return [.init(key:"epubLayout",title:"EPUB layout",choices:choices([("reflow","Reflow text"),("pages","Preserve original pages")]),defaultValue:"reflow")]}
        if ["mp3","m4a","ogg","opus","wma"].contains(format){return [.init(key:"audioBitrate",title:"Audio bitrate",choices:[128,192,256,320].map{Choice(value:String($0),label:"\($0) kbps")},defaultValue:"256")]}
        if ["wav","aiff"].contains(format){return [.init(key:"audioBitDepth",title:"Audio bit depth",choices:choices([("source","Match source"),("16","16-bit integer"),("24","24-bit integer"),("32","32-bit integer"),("float32","32-bit float")]),defaultValue:"source")]}
        if format=="flac"{return [.init(key:"flacCompression",title:"Compression",choices:compression,defaultValue:"balanced")]}
        if ["zip","gzip"].contains(format){return [.init(key:"archiveCompression",title:"Compression",choices:compression,defaultValue:"balanced")]}
        if format=="gif"{return [.init(key:"gifFrameRate",title:"Frame rate",choices:[10,15,24].map{Choice(value:String($0),label:"\($0) fps")},defaultValue:"15"),.init(key:"gifMaxWidth",title:"Maximum width",choices:[480,960,1280].map{Choice(value:String($0),label:"\($0) px")},defaultValue:"960")]}
        if groups[4].formats.contains(format){return [q,.init(key:"maxVideoHeight",title:"Maximum video height",choices:choices([("0","Original"),("2160","2160p"),("1080","1080p"),("720","720p"),("480","480p")]),defaultValue:"0")]}
        return []
    }
    static func preservesMetadata(_ format:String)->Bool{["jpg","png","webp","heic","tiff","avif"].contains(format)}
    static func defaults(_ format:String)->[String:String]{
        var result=Dictionary(uniqueKeysWithValues:controls(format).map{($0.key,$0.defaultValue)})
        if preservesMetadata(format){result["preserveMetadata"]="true"};return result
    }
    static func targets(_ f:String)->[String]{
        if groups[0].formats.contains(f){return ["jpg","png","webp","heic","tiff","avif","bmp","pdf"].filter{$0 != f}}
        if groups[3].formats.contains(f){return groups[3].formats.filter{$0 != f}}
        if groups[4].formats.contains(f){return (f=="gif" ? ["mp4","mov","mkv","webm","avi","wmv"]:["mp4","mov","mkv","webm","avi","wmv","gif","mp3"]).filter{$0 != f}}
        if groups[2].formats.contains(f){return ["xlsx","ods","csv","tsv","pdf"].filter{$0 != f}}
        if groups[5].formats.contains(f){return ["zip","tar","gzip"].filter{$0 != f}}
        switch f {
        case "pdf":return ["docx","pages","pptx","txt","md","html","epub","jpg","png","xlsx"]
        case "docx","pages":return ["docx","pages","pdf","txt","md","html","epub","png","jpg"].filter{$0 != f}
        case "ppt","pptx":return ["pdf","jpg","png"]
        case "txt","md":return ["pdf","docx","pages","txt","md","html","epub","png","jpg"].filter{$0 != f}
        case "rtf","rtfd","textclipping":return ["docx","pages","pdf","txt","md","html","epub","png","jpg"]
        case "epub":return ["pdf","docx","pages","txt","md","html"]
        case "srt":return ["vtt","txt"]
        case "vtt":return ["srt","txt"]
        default:return []
        }
    }
    static func description(_ f:String)->String{
        if f=="html"{return "Output-only format."}
        let t=targets(f).map{$0.uppercased()};let list=t.count>1 ? t.dropLast().joined(separator:", ")+", and "+t.last!:(t.first ?? "")
        return (inputOnly.contains(f) ? "Input-only format.":"Input and output format.")+(list.isEmpty ? "":" Converts to \(list).")
    }
    static func explanation(_ format:String,_ values:[String:String])->String?{
        if ["docx","pages"].contains(format){return values["pdfLayout"]=="pages" ? "Keep every page as a sharp image, including tables, equations, and scanned content. Text cannot be edited.":"Create normal paragraphs, headings, and tables that reflow when edited. Recognize scanned text with OCR. Keep illustrations as inline images."}
        if format=="epub"{return values["epubLayout"]=="pages" ? "Create a fixed layout book of page images. Text resizing, selection, and search are unavailable.":"Create adjustable, selectable text with parsed headings and tables. Keep illustrations and complex equations as separate artwork."}
        return nil
    }
    static func resolved(_ format:String,overrides:[String:String])->[String:String]{
        var result=defaults(format);result.merge(overrides){_,new in new}
        switch result["qualityPreset"] {case "smaller":result["quality"]="60";case "higher":result["quality"]="95";case "balanced":result["quality"]="80";default:break}
        return result
    }
}
