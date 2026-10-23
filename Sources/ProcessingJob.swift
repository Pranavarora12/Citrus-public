import Foundation

struct ProcessingJob {
    static func run(_ operation:String,inputs:[URL],outputDirectory:URL,options:[String:String]) throws -> [URL] {
        guard let first=inputs.first else {throw UIError.message("Choose at least one file.")}
        if inputs.allSatisfy({VideoTools.extensions.contains($0.pathExtension.lowercased())}), (VideoTools.singleToolIDs+["joinVideos"]).contains(operation) {
            return try VideoTools.run(operation,inputs:inputs,directory:outputDirectory,options:options)
        }
        let docs:Set<String>=["createPDF","mergePDF","splitPDF","organizePDF","extractArchive","createArchive","convertArchive","removeMetadata","extractText"]
        let documentFormats:Set<String>=["pdf","txt","md","html","rtf","rtfd","docx","csv","tsv","json","srt","vtt","ass","epub","xlsx","xls","ods","pages","pptx","ppt","textclipping","doc","odt"]
        let source=first.pathExtension.lowercased()
        let documentConversion=operation == "convert" && (documentFormats.contains(source) || documentFormats.contains(options["format"] ?? ""))
        if docs.contains(operation) || (operation == "compress" && source == "pdf") || documentConversion {
            return try DocumentEngine.run(operation,inputs:inputs,outputDirectory:outputDirectory,options:options)
        }
        return try MediaEngine.run(operation,inputs:inputs,outputDirectory:outputDirectory,options:options)
    }
}
