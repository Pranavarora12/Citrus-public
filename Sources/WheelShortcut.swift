import AppKit

struct WheelShortcut:Identifiable {
    let value:String
    let label:String
    var id:String{value}
    static let modifiers:[(String,String,String,NSEvent.ModifierFlags)]=[("control","⌃","Control",.control),("option","⌥","Option",.option),("shift","⇧","Shift",.shift),("command","⌘","Command",.command)]
    static let all:[WheelShortcut]=["command","control","control+command","control+option","control+shift","control+option+command","control+option+shift","control+shift+command","control+option+shift+command","option","option+command","option+shift","option+shift+command","shift","shift+command"].map{WheelShortcut(value:$0,label:title($0))}
    static func mask(_ value:String)->NSEvent.ModifierFlags {value.split(separator:"+").reduce(NSEvent.ModifierFlags()){result,item in result.union(modifiers.first{$0.0==item}?.3 ?? [])}}
    static func title(_ value:String)->String {let selected=value.split(separator:"+").compactMap{part in modifiers.first{$0.0==part}};return selected.map{$0.1}.joined(separator:" ")+"  "+selected.map{$0.2}.joined(separator:" + ")}
    static func matches(_ event:NSEvent.ModifierFlags,_ value:String)->Bool {let chosen=mask(value);return !chosen.isEmpty && event.intersection([.control,.option,.shift,.command])==chosen}
}
