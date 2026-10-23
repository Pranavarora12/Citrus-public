import Foundation
import AppKit
let args=CommandLine.arguments
func emit(_ value:Any){let data=try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]);print(String(data:data,encoding:.utf8)!)}
do {
    switch args[1] {
    case "inventory":emit(ConversionAudit.inventory())
    case "rtfd":try ConversionAudit.rtfdFixture(URL(fileURLWithPath:args[2],isDirectory:true))
    case "fixtures":try ConversionAudit.fixtures(URL(fileURLWithPath:args[2],isDirectory:true))
    case "pair":
        do{emit(try ConversionAudit.run(URL(fileURLWithPath:args[2]),target:args[3],output:URL(fileURLWithPath:args[4],isDirectory:true)))}catch{emit(["status":"FAIL","detail":error.localizedDescription])}
    default:exit(2)
    }
}catch{fputs("\(error)\n",stderr);exit(1)}
