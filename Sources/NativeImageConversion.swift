import Foundation
import AppKit
import ImageIO

/// CPU image conversion. HEIF uses an independently encoded HEVC image item.
struct NativeImageConversion {
    private static var runtime:URL {
        var candidates:[URL]=[]
        if let resources=Bundle.main.resourceURL {candidates.append(resources.appendingPathComponent("ConversionRuntime/dependencies"))}
        candidates.append(URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/ConversionRuntime/dependencies"))
        candidates.append(URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/ConversionRuntime/dependencies"))
        let cache=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/codex-runtimes/codex-primary-runtime/dependencies")
        candidates.append(cache)
        return candidates.first {FileManager.default.fileExists(atPath:$0.appendingPathComponent("native/libheif/libheif/bin/heif-dec").path)} ?? cache
    }
    private static let imageExtensions: Set<String> = ["jpg","jpeg","png","webp","bmp","tif","tiff","heic","heif","avif","svg","gif"]
    static func write(_ input: URL, to output: URL, format: String, options: [String:String]) throws -> Bool {
        let types = ["jpg":"public.jpeg","jpeg":"public.jpeg","png":"public.png","tiff":"public.tiff","bmp":"com.microsoft.bmp","gif":"com.compuserve.gif"]
        guard imageExtensions.contains(input.pathExtension.lowercased()), types[format] != nil || ["webp","heic","avif"].contains(format) else { return false }
        let quality = try qualityValue(options)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("citrus-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let normalized = directory.appendingPathComponent("decoded.png")
        try normalizedPNG(input,to:normalized)
        guard let source = CGImageSourceCreateWithURL(normalized as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw MediaEngine.Failure.message("Cannot read decoded image.") }
        do {
            if format == "heic" { try softwareHEIC(normalized,to:output,width:image.width,height:image.height,quality:quality,temporaryDirectory:directory); return true }
            if format == "webp" {
                var args = ["-quiet","-q","\(quality)"]
                if let edge = Int(options["maxImageEdge"] ?? "0"),edge > 0,max(image.width,image.height)>edge {
                    let scale = Double(edge)/Double(max(image.width,image.height))
                    args += ["-resize","\(max(1,Int(Double(image.width)*scale)))","\(max(1,Int(Double(image.height)*scale)))"]
                }
                try process("/opt/homebrew/bin/cwebp",args+[normalized.path,"-o",output.path]); return true
            }
            if format == "avif" {
                try process("/opt/homebrew/bin/ffmpeg",["-hide_banner","-loglevel","error","-nostdin","-n","-i",normalized.path,"-frames:v","1","-c:v","libsvtav1","-crf","\(Int(63-quality*0.6))","-pix_fmt","yuv420p",output.path]); return true
            }
            guard let type=types[format],let destination=CGImageDestinationCreateWithURL(output as CFURL,type as CFString,1,nil) else { throw MediaEngine.Failure.message("The \(format.uppercased()) encoder is unavailable.") }
            var properties:[CFString:Any]=[:]
            if options["preserveMetadata"] != "false",let original=CGImageSourceCreateWithURL(input as CFURL,nil) { properties=(CGImageSourceCopyPropertiesAtIndex(original,0,nil) as? [CFString:Any]) ?? [:] }
            properties.removeValue(forKey:kCGImagePropertyOrientation)
            properties.removeValue(forKey:kCGImagePropertyPixelWidth); properties.removeValue(forKey:kCGImagePropertyPixelHeight)
            if var tiff=properties[kCGImagePropertyTIFFDictionary] as? [CFString:Any] { tiff.removeValue(forKey:kCGImagePropertyTIFFOrientation);properties[kCGImagePropertyTIFFDictionary]=tiff }
            if var exif=properties[kCGImagePropertyExifDictionary] as? [CFString:Any] { exif.removeValue(forKey:kCGImagePropertyExifPixelXDimension);exif.removeValue(forKey:kCGImagePropertyExifPixelYDimension);properties[kCGImagePropertyExifDictionary]=exif }
            if ["jpg","jpeg"].contains(format) { properties[kCGImageDestinationLossyCompressionQuality]=quality/100 }
            CGImageDestinationAddImage(destination,image,properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw MediaEngine.Failure.message("\(format.uppercased()) encoding failed.") }
            return true
        } catch { try? FileManager.default.removeItem(at:output);throw error }
    }
    static func normalizedPNG(_ input:URL,to output:URL)throws {
        let ext=input.pathExtension.lowercased()
        if ["heic","heif"].contains(ext) {
            let decoder=runtime.appendingPathComponent("native/libheif/libheif/bin/heif-dec")
            if FileManager.default.isExecutableFile(atPath:decoder.path) { try process(decoder.path,["--quiet","--codec-threads","2",input.path,output.path]);return }
        }
        if ["svg","avif","heic","heif"].contains(ext) {
            let helper=runtime.appendingPathComponent("native/libvips/bin/image-decoder")
            if FileManager.default.isExecutableFile(atPath:helper.path) {try process(helper.path,[input.path,output.path]);return}
            let sharp=runtime.appendingPathComponent("node/node_modules/sharp").path
            let node=runtime.appendingPathComponent("node/bin/node").path
            guard FileManager.default.isExecutableFile(atPath:node),FileManager.default.fileExists(atPath:sharp) else { throw MediaEngine.Failure.message("Local software \(ext.uppercased()) decoder is missing.") }
            let script="const sharp=require(process.argv[1]);sharp(process.argv[2],{limitInputPixels:150000000}).rotate().png().toFile(process.argv[3]).catch(e=>{console.error(e.message);process.exit(1)});"
            try process(node,["-e",script,sharp,input.path,output.path]);return
        }
        guard let source=CGImageSourceCreateWithURL(input as CFURL,nil),let raw=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw MediaEngine.Failure.message("Cannot decode image: \(input.lastPathComponent)") }
        let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(raw.width,raw.height)] as CFDictionary) ?? raw
        guard let destination=CGImageDestinationCreateWithURL(output as CFURL,"public.png" as CFString,1,nil) else { throw MediaEngine.Failure.message("Cannot create PNG intermediate.") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaEngine.Failure.message("Cannot decode image pixels into PNG.") }
    }
    private static func qualityValue(_ options:[String:String])throws->Double {
        guard let q=Double(options["quality"] ?? "80"),q.isFinite,(1...100).contains(q) else { throw MediaEngine.Failure.message("Choose image quality between 1 and 100.") };return q
    }
    /// ISO/IEC 23008-12 image-item container around x265 output. MP4 supplies
    /// the exact hvcC configuration and length-prefixed HEVC access unit.
    private static func softwareHEIC(_ png:URL,to output:URL,width:Int,height:Int,quality:Double,temporaryDirectory:URL)throws {
        let movie=temporaryDirectory.appendingPathComponent("still.mp4")
        let codedWidth=max(16,(width+1)/2*2),codedHeight=max(16,(height+1)/2*2)
        try process("/opt/homebrew/bin/ffmpeg",["-hide_banner","-loglevel","error","-nostdin","-n","-i",png.path,"-vf","pad=\(codedWidth):\(codedHeight):0:0","-frames:v","1","-an","-c:v","libx265","-x265-params","pools=none:frame-threads=1:log-level=error","-crf","\(Int(45-quality*0.4))","-pix_fmt","yuv420p","-tag:v","hvc1",movie.path])
        let bytes=try Data(contentsOf:movie)
        guard let configuration=findBox("hvcC",in:bytes),let media=topLevelBox("mdat",in:bytes),media.count>8 else { throw MediaEngine.Failure.message("Invalid software HEVC stream.") }
        let codedImage=media.subdata(in:8..<media.count)
        let ftyp=box("ftyp",ascii("heic")+integer(0,4)+ascii("mif1heic"))
        let hdlr=fullBox("hdlr",integer(0,4)+ascii("pict")+Data(repeating:0,count:12)+ascii("Citrus Image\0"))
        let pitm=fullBox("pitm",integer(1,2))
        let infe=fullBox("infe",integer(1,2)+integer(0,2)+ascii("hvc1Image\0"),version:2)
        let iinf=fullBox("iinf",integer(1,2)+infe)
        let ispe=fullBox("ispe",integer(codedWidth,4)+integer(codedHeight,4))
        let pixi=fullBox("pixi",Data([3,8,8,8]))
        let cropped=width != codedWidth || height != codedHeight
        let clap=box("clap",integer(width,4)+integer(1,4)+integer(height,4)+integer(1,4)+integer(width-codedWidth,4)+integer(2,4)+integer(height-codedHeight,4)+integer(2,4))
        let ipco=box("ipco",configuration+ispe+pixi+(cropped ? clap:Data()))
        let associations:Data=cropped ? Data([4,0x81,0x82,0x03,0x84]):Data([3,0x81,0x82,0x03])
        let ipma=fullBox("ipma",integer(1,4)+integer(1,2)+associations)
        let iprp=box("iprp",ipco+ipma)
        func location(_ offset:Int)->Data {
            fullBox("iloc",Data([0x44,0x00])+integer(1,2)+integer(1,2)+integer(0,2)+integer(1,2)+integer(offset,4)+integer(codedImage.count,4))
        }
        let initial=fullBox("meta",hdlr+pitm+location(0)+iinf+iprp)
        let meta=fullBox("meta",hdlr+pitm+location(ftyp.count+initial.count+8)+iinf+iprp)
        try (ftyp+meta+box("mdat",codedImage)).write(to:output,options:.atomic)
    }
    private static func ascii(_ text:String)->Data { Data(text.utf8) }
    private static func integer(_ value:Int,_ count:Int)->Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded:value >> ($0*8)) }) }
    private static func box(_ type:String,_ payload:Data)->Data { integer(payload.count+8,4)+ascii(type)+payload }
    private static func fullBox(_ type:String,_ payload:Data,version:UInt8=0)->Data { box(type,Data([version,0,0,0])+payload) }
    private static func readSize(_ bytes:Data,_ offset:Int)->Int { bytes[offset..<(offset+4)].reduce(0) { ($0 << 8)|Int($1) } }
    private static func topLevelBox(_ type:String,in bytes:Data)->Data? {
        var offset=0
        while offset+8<=bytes.count { let size=readSize(bytes,offset);guard size>=8,offset+size<=bytes.count else{return nil};if bytes.subdata(in:(offset+4)..<(offset+8))==ascii(type){return bytes.subdata(in:offset..<(offset+size))};offset+=size };return nil
    }
    private static func findBox(_ type:String,in bytes:Data)->Data? {
        guard let range=bytes.range(of:ascii(type)),range.lowerBound>=4 else{return nil}
        let start=range.lowerBound-4,size=readSize(bytes,start)
        guard size>=8,start+size<=bytes.count else{return nil};return bytes.subdata(in:start..<(start+size))
    }
    @discardableResult private static func process(_ path:String,_ arguments:[String])throws->String {
        guard FileManager.default.isExecutableFile(atPath:path) else { throw MediaEngine.Failure.message("Required local image tool is missing: \(path)") }
        let process=Process();process.executableURL=URL(fileURLWithPath:path);process.arguments=arguments
        let pipe=Pipe();process.standardOutput=pipe;process.standardError=pipe
        try process.run();let bytes=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        let message=String(data:bytes,encoding:.utf8) ?? ""
        guard process.terminationStatus==0 else { throw MediaEngine.Failure.message("Image conversion failed: \(message.suffix(1800))") };return message
    }
}
