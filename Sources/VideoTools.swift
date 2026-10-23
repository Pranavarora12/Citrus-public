import Foundation
import AppKit
import ImageIO

struct VideoInfo {
    let duration:Double
    let width:Int
    let height:Int
    let frameRate:Double
    let hasAudio:Bool
    let bytes:Int
    let tags:[VideoMetadataField]
    var size:CGSize {CGSize(width:width,height:height)}
}
struct VideoMetadataField:Identifiable {
    var id:String {"\(stream.map(String.init) ?? "file")/\(key)"}
    var stream:Int?
    var key:String
    var value:String
    var removed=false
    var edited=false
    var group:String {stream.map{"Track \($0+1)"} ?? "File"}
    var label:String {key.replacingOccurrences(of:"_",with:" ").capitalized}
}
struct VideoTimeRange:Equatable,Codable {
    var start:Double
    var end:Double
    var duration:Double {end-start}
}
struct VideoRedaction:Identifiable {
    var id=UUID()
    var rect:CGRect
    var range:VideoTimeRange
    var blur=false
    var color:NSColor = .black
    var radius:Double=18
}

final class VideoJobControl: @unchecked Sendable {
    private let lock=NSLock()
    private var process:Process?
    private var cancelled=false
    func cancel(){lock.lock();cancelled=true;let process=process;lock.unlock();if process?.isRunning==true{process?.terminate()}}
    func attach(_ value:Process)throws {lock.lock();defer{lock.unlock()};if cancelled{throw UIError.message("Cancelled.")};try value.run();process=value}
    func detach(){lock.lock();process=nil;lock.unlock()}
    func check()throws{lock.lock();let stopped=cancelled;lock.unlock();if stopped{throw UIError.message("Cancelled.")}}
}

enum VideoTrace {
    static func event(_ value:String){
        #if DEBUG
        let url=URL(fileURLWithPath:"/tmp/citrus-video-trace.log")
        let data=Data("\(Date()) \(value)\n".utf8)
        if let file=try? FileHandle(forWritingTo:url){_ = try? file.seekToEnd();try? file.write(contentsOf:data);try? file.close()}else{try? data.write(to:url)}
        #endif
    }
}

enum VideoTools {
    static let extensions:Set<String>=["mp4","mov","m4v","mkv","webm","avi","wmv","mpg","mpeg","ts","m2ts","mts","mxf"]
    static let singleToolIDs=["compress","removeMetadata","muteVideo","trimVideo","cropVideo","changeVideoSpeed","videoSnapshots","splitVideo","redactVideo"]
    static let encoding=["-c:v","libx264","-preset","veryfast","-crf","20","-pix_fmt","yuv420p","-c:a","aac","-b:a","160k","-movflags","+faststart"]
    @discardableResult static func process(_ executable:String,_ arguments:[String],control:VideoJobControl?=nil)throws->Data {
        VideoTrace.event("process start \(executable) \(arguments)")
        try control?.check()
        guard FileManager.default.isExecutableFile(atPath:executable) else{throw UIError.message("Required video tool is missing: \(executable)")}
        let task=Process();task.executableURL=URL(fileURLWithPath:executable);task.arguments=arguments
        let pipe=Pipe();task.standardOutput=pipe;task.standardError=pipe
        try control?.attach(task);defer{control?.detach()}
        if control==nil{try task.run()};VideoTrace.event("process launched \(task.processIdentifier)");let data=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit();VideoTrace.event("process done \(task.terminationStatus)");try control?.check()
        guard task.terminationStatus==0 else{throw UIError.message("Video processing failed: \(String(data:data,encoding:.utf8)?.suffix(1400) ?? "Unknown media error")")};return data
    }
    static func ffmpeg(_ arguments:[String],control:VideoJobControl?=nil)throws {try process("/opt/homebrew/bin/ffmpeg",["-hide_banner","-loglevel","error","-nostdin","-n"]+arguments,control:control)}
    static func info(_ input:URL)throws->VideoInfo {
        let data=try process("/opt/homebrew/bin/ffprobe",["-v","error","-show_format","-show_streams","-of","json",input.path])
        guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],let streams=json["streams"] as? [[String:Any]],let video=streams.first(where:{$0["codec_type"] as? String=="video"}) else{throw UIError.message("This file has no readable video track: \(input.lastPathComponent)")}
        let format=json["format"] as? [String:Any] ?? [:]
        func number(_ value:Any?)->Double {if let number=value as? NSNumber{return number.doubleValue};return Double(value as? String ?? "") ?? 0}
        let duration=number(format["duration"])>0 ? number(format["duration"]):number(video["duration"])
        guard duration.isFinite,duration>0 else{throw UIError.message("Cannot determine video duration.")}
        var width=Int(number(video["width"])),height=Int(number(video["height"]))
        let side=(video["side_data_list"] as? [[String:Any]])?.first(where:{$0["rotation"] != nil})
        let tags=video["tags"] as? [String:Any] ?? [:]
        let rotation=number(side?["rotation"] ?? tags["rotate"])
        if Int(abs(rotation).rounded())%180==90{swap(&width,&height)}
        guard width>0,height>0 else{throw UIError.message("This video has invalid dimensions.")}
        let parts=(video["avg_frame_rate"] as? String ?? "30/1").split(separator:"/").compactMap{Double($0)}
        let rate=parts.count==2 && parts[1]>0 ? parts[0]/parts[1]:30
        var fields:[VideoMetadataField]=[]
        func append(_ dictionary:[String:Any],stream:Int?){for key in dictionary.keys.sorted(){fields.append(.init(stream:stream,key:key,value:String(describing:dictionary[key]!)))}}
        append(format["tags"] as? [String:Any] ?? [:],stream:nil)
        for (index,track) in streams.enumerated(){append(track["tags"] as? [String:Any] ?? [:],stream:(track["index"] as? Int) ?? index)}
        return VideoInfo(duration:duration,width:width,height:height,frameRate:rate.isFinite && rate>0 ? rate:30,hasAudio:streams.contains{$0["codec_type"] as? String=="audio"},bytes:Int(number(format["size"])),tags:fields)
    }
    static func output(_ input:URL,_ directory:URL,_ suffix:String,ext:String="mp4")throws->URL {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        return ImageTools.unique(input,directory:directory,suffix:suffix,ext:ext)
    }
    @discardableResult static func write(_ output:URL,args:[String],control:VideoJobControl?=nil)throws->URL {
        do{try ffmpeg(args+[output.path],control:control);guard ((try? output.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>0 else{throw UIError.message("The video export is empty.")};return output}
        catch{try? FileManager.default.removeItem(at:output);throw error}
    }
    static func trim(_ input:URL,directory:URL,range:VideoTimeRange,control:VideoJobControl?=nil)throws->URL {
        let source=try info(input);try validate(range,duration:source.duration)
        let output=try output(input,directory,"Trimmed")
        return try write(output,args:["-i",input.path,"-ss",decimal(range.start),"-t",decimal(range.duration),"-map","0:v:0","-map","0:a?","-vf","scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"]+encoding,control:control)
    }
    static func crop(_ input:URL,directory:URL,rect:CGRect,control:VideoJobControl?=nil)throws->URL {
        let source=try info(input)
        guard [rect.minX,rect.minY,rect.width,rect.height].allSatisfy({$0.isFinite}) else{throw UIError.message("Enter finite crop dimensions.")}
        let r=rect.integral
        guard r.minX>=0,r.minY>=0,r.maxX<=CGFloat(source.width),r.maxY<=CGFloat(source.height),r.width>=2,r.height>=2 else{throw UIError.message("Choose a crop of at least 2 × 2 pixels inside the video.")}
        let width=max(2,Int(r.width)/2*2),height=max(2,Int(r.height)/2*2)
        return try write(output(input,directory,"Cropped"),args:["-i",input.path,"-map","0:v:0","-map","0:a?","-vf","crop=\(width):\(height):\(Int(r.minX)):\(Int(r.minY)),setsar=1"]+encoding,control:control)
    }
    static func speed(_ input:URL,directory:URL,multiplier:Double,control:VideoJobControl?=nil)throws->URL {
        guard multiplier.isFinite,(0.25...4).contains(multiplier) else{throw UIError.message("Choose a speed between 0.25× and 4×.")}
        let source=try info(input)
        var remainder=multiplier,tempos:[String]=[]
        while remainder>2{tempos.append("atempo=2");remainder/=2}
        while remainder<0.5{tempos.append("atempo=0.5");remainder/=0.5}
        tempos.append("atempo=\(decimal(remainder))")
        var args=["-i",input.path,"-map","0:v:0","-map","0:a?","-vf","setpts=(PTS-STARTPTS)/\(decimal(multiplier)),scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1","-r",decimal(min(120,max(1,source.frameRate)))]
        if source.hasAudio{args += ["-af",tempos.joined(separator:",")]}
        return try write(output(input,directory,"Speed \(decimal(multiplier))x"),args:args+encoding,control:control)
    }
    static func mute(_ input:URL,directory:URL,control:VideoJobControl?=nil)throws->URL {
        let ext=["mp4","mov","m4v","mkv","webm","avi","wmv"].contains(input.pathExtension.lowercased()) ? input.pathExtension.lowercased():"mp4"
        return try write(output(input,directory,"Muted",ext:ext),args:["-i",input.path,"-map","0:v:0","-an","-c:v","copy"],control:control)
    }
    static func frame(_ input:URL,time:Double,maxEdge:Int=960)throws->CGImage {
        let source=try info(input)
        guard time.isFinite,time>=0,time<source.duration else{throw UIError.message("Choose a frame before the end of the video.")}
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("citrus-frame-\(UUID()).png")
        defer{try? FileManager.default.removeItem(at:temporary)}
        let sample=min(time,max(0,source.duration-1/source.frameRate))
        var args=["-ss",decimal(sample),"-i",input.path,"-frames:v","1"]
        if maxEdge>0{args += ["-vf","scale='min(iw,\(maxEdge))':'min(ih,\(maxEdge))':force_original_aspect_ratio=decrease"]}
        try ffmpeg(args+[temporary.path])
        guard let reader=CGImageSourceCreateWithURL(temporary as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(reader,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw UIError.message("Could not decode the selected video frame.")};return image
    }
    static func snapshots(_ input:URL,directory:URL,times:[Double],control:VideoJobControl?=nil)throws->[URL] {
        let source=try info(input)
        guard !times.isEmpty,times.count<=1000,times.allSatisfy({$0.isFinite && $0>=0 && $0<source.duration}) else{throw UIError.message("Choose one or more frames inside the video.")}
        var outputs:[URL]=[]
        do{for (index,time) in times.enumerated(){let path=try output(input,directory,"Frame \(index+1)",ext:"png");outputs.append(path);try write(path,args:["-ss",decimal(min(time,max(0,source.duration-1/source.frameRate))),"-i",input.path,"-frames:v","1"],control:control)};return outputs}
        catch{outputs.forEach{try? FileManager.default.removeItem(at:$0)};throw error}
    }
    static func split(_ input:URL,directory:URL,ranges:[VideoTimeRange],merge:Bool,control:VideoJobControl?=nil)throws->[URL] {
        let source=try info(input);guard !ranges.isEmpty else{throw UIError.message("Keep at least one clip.")};try ranges.forEach{try validate($0,duration:source.duration)}
        if !merge{
            var outputs:[URL]=[]
            do{for (index,range) in ranges.enumerated(){let path=try output(input,directory,"Clip \(index+1)");outputs.append(path);try write(path,args:["-i",input.path,"-ss",decimal(range.start),"-t",decimal(range.duration),"-map","0:v:0","-map","0:a?","-vf","scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"]+encoding,control:control)};return outputs}
            catch{outputs.forEach{try? FileManager.default.removeItem(at:$0)};throw error}
        }
        var filters:[String]=[],labels=""
        for (index,range) in ranges.enumerated(){
            filters.append("[0:v]trim=start=\(decimal(range.start)):end=\(decimal(range.end)),setpts=PTS-STARTPTS,scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1[v\(index)]")
            labels += "[v\(index)]"
            if source.hasAudio{filters.append("[0:a]atrim=start=\(decimal(range.start)):end=\(decimal(range.end)),asetpts=PTS-STARTPTS[a\(index)]");labels += "[a\(index)]"}
        }
        filters.append(labels+"concat=n=\(ranges.count):v=1:a=\(source.hasAudio ? 1:0)[outv]"+(source.hasAudio ? "[outa]":""))
        var args=["-i",input.path,"-filter_complex",filters.joined(separator:";"),"-map","[outv]"]
        if source.hasAudio{args += ["-map","[outa]"]}
        let result=try write(output(input,directory,"Edited"),args:args+encoding,control:control);return [result]
    }
    static func redact(_ input:URL,directory:URL,layers:[VideoRedaction],control:VideoJobControl?=nil)throws->URL {
        let source=try info(input);guard !layers.isEmpty else{throw UIError.message("Draw at least one redaction rectangle.")}
        var filters:[String]=[],current="0:v"
        for (index,layer) in layers.enumerated(){
            try validate(layer.range,duration:source.duration)
            guard [layer.rect.minX,layer.rect.minY,layer.rect.width,layer.rect.height].allSatisfy({$0.isFinite}) else{throw UIError.message("Invalid redaction dimensions.")}
            let r=layer.rect.integral.intersection(CGRect(origin:.zero,size:source.size))
            guard r.width>=2,r.height>=2 else{throw UIError.message("A redaction rectangle must cover at least 2 × 2 pixels.")}
            let out="redacted\(index)",enable="between(t,\(decimal(layer.range.start)),\(decimal(layer.range.end)))"
            if layer.blur{
                let a="base\(index)",b="region\(index)",blur="blur\(index)",radius=max(1,min(Int(layer.radius),Int(min(r.width,r.height))/2-1))
                filters.append("[\(current)]split[\(a)][\(b)]")
                filters.append("[\(b)]crop=\(Int(r.width)): \(Int(r.height)):\(Int(r.minX)):\(Int(r.minY)),boxblur=luma_radius=\(radius):luma_power=3:chroma_radius=0[\(blur)]".replacingOccurrences(of:": ",with:":"))
                filters.append("[\(a)][\(blur)]overlay=x=\(Int(r.minX)):y=\(Int(r.minY)):enable='\(enable)'[\(out)]")
            }else{
                let c=layer.color.usingColorSpace(.sRGB) ?? .black
                let hex=String(format:"0x%02x%02x%02x",Int(c.redComponent*255),Int(c.greenComponent*255),Int(c.blueComponent*255))
                filters.append("[\(current)]drawbox=x=\(Int(r.minX)):y=\(Int(r.minY)):w=\(Int(r.width)):h=\(Int(r.height)):color=\(hex):t=fill:enable='\(enable)'[\(out)]")
            }
            current=out
        }
        return try write(output(input,directory,"Redacted"),args:["-i",input.path,"-filter_complex",filters.joined(separator:";"),"-map","[\(current)]","-map","0:a?"]+encoding,control:control)
    }
    static func metadata(_ input:URL,directory:URL,fields:[VideoMetadataField],removeAll:Bool,control:VideoJobControl?=nil)throws->URL {
        let ext=input.pathExtension.lowercased()
        var args=["-i",input.path]
        if removeAll{args += ["-map","0:v?","-map","0:a?","-map_metadata","-1","-map_metadata:s","-1","-map_chapters","-1"]}
        else{args += ["-map","0","-map_metadata","0"]}
        args += ["-c","copy"]
        for field in fields where !removeAll && (field.edited || field.removed){args += [field.stream.map{"-metadata:s:\($0)"} ?? "-metadata","\(field.key)=\(field.removed ? "":field.value)"]}
        if ["mov","mp4","m4v"].contains(ext){args += ["-movflags","use_metadata_tags"];if removeAll{args += ["-write_tmcd","0"]}}
        if removeAll{args += ["-metadata","encoder="]}
        return try write(output(input,directory,"Metadata",ext:ext),args:args,control:control)
    }
    static func compress(_ input:URL,directory:URL,mode:String,preset:String,reduction:Double,targetSize:Double,unit:String,control:VideoJobControl?=nil)throws->URL {
        let source=try info(input)
        let target:Int
        switch mode{
        case "percentage":guard reduction.isFinite,(1...99).contains(reduction) else{throw UIError.message("Choose a reduction between 1 and 99 percent.")};target=max(1,Int(Double(source.bytes)*(1-reduction/100)))
        case "fileSize":let bytes=targetSize*(unit=="GB" ? 1_000_000_000:unit=="KB" ? 1000:1_000_000);guard bytes.isFinite,bytes>=1000,bytes<=1_000_000_000_000 else{throw UIError.message("Enter a target size of at least 1 KB.")};target=min(source.bytes-1,Int(bytes))
        default:target=max(1,Int(Double(source.bytes)*(preset=="strong" ? 0.45:0.75)))
        }
        var videoRate=max(8000,Double(target)*8/source.duration*0.9-(source.hasAudio ? 64000:0)),audioRate=source.hasAudio ? 64000:0
        for attempt in 0..<7{
            try control?.check()
            let path=try output(input,directory,"Compressed")
            let totalPixels=Double(source.width*source.height)*source.frameRate
            let qualityScale=min(1,sqrt(max(0.01,videoRate/(totalPixels*0.055))))*pow(0.86,Double(max(0,attempt-2)))
            let w=max(16,Int(Double(source.width)*qualityScale)/2*2),h=max(16,Int(Double(source.height)*qualityScale)/2*2)
            var args=["-i",input.path,"-map","0:v:0","-map","0:a?","-vf","scale=\(w):\(h):flags=lanczos,setsar=1","-c:v","libx264","-preset","veryfast","-b:v",String(Int(videoRate)),"-maxrate",String(Int(videoRate)),"-bufsize",String(Int(videoRate*2)),"-pix_fmt","yuv420p","-movflags","+faststart"]
            if source.hasAudio{args += ["-c:a","aac","-b:a",String(audioRate)]}
            do{
                try write(path,args:args,control:control)
                let actual=try path.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
                if actual<=target && actual<source.bytes{return path}
                try FileManager.default.removeItem(at:path)
                let ratio=min(0.8,Double(target)/Double(max(1,actual))*0.85)
                videoRate=max(1000,videoRate*ratio);audioRate=max(8000,Int(Double(audioRate)*ratio))
            }catch{try? FileManager.default.removeItem(at:path);throw error}
        }
        throw UIError.message("This target is too small for a valid video. Choose a larger file size or a smaller reduction.")
    }
    static func join(_ inputs:[URL],directory:URL,control:VideoJobControl?=nil)throws->URL {
        guard inputs.count>=2 else{throw UIError.message("Choose at least two videos to join.")}
        let sources=try inputs.map(info),first=sources[0],w=max(2,first.width/2*2),h=max(2,first.height/2*2)
        var filters:[String]=[],labels=""
        for (i,source) in sources.enumerated(){
            filters.append("[\(i):v]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(decimal(min(60,first.frameRate))),setpts=PTS-STARTPTS[v\(i)]")
            if source.hasAudio{filters.append("[\(i):a]aresample=48000,aformat=channel_layouts=stereo,apad,atrim=duration=\(decimal(source.duration)),asetpts=PTS-STARTPTS[a\(i)]")}
            else{filters.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(decimal(source.duration)),asetpts=PTS-STARTPTS[a\(i)]")}
            labels += "[v\(i)][a\(i)]"
        }
        filters.append(labels+"concat=n=\(inputs.count):v=1:a=1[v][a]")
        return try write(output(inputs[0],directory,"Joined"),args:inputs.flatMap{["-i",$0.path]}+["-filter_complex",filters.joined(separator:";"),"-map","[v]","-map","[a]"]+encoding,control:control)
    }
    static func validate(_ range:VideoTimeRange,duration:Double)throws {
        guard range.start.isFinite,range.end.isFinite,range.start>=0,range.end<=duration+0.001,range.duration>=0.001 else{throw UIError.message("Choose a nonempty time range inside the video.")}
    }
    static func decimal(_ value:Double)->String {String(format:"%.6f",locale:Locale(identifier:"en_US_POSIX"),value)}
    static func run(_ operation:String,inputs:[URL],directory:URL,options:[String:String])throws->[URL] {
        guard let input=inputs.first else{throw UIError.message("Choose a video.")}
        func number(_ key:String,_ fallback:Double)->Double {Double(options[key] ?? "") ?? fallback}
        switch operation{
        case "joinVideos":return [try join(inputs,directory:directory)]
        case "muteVideo":return try inputs.map{try mute($0,directory:directory)}
        case "removeMetadata":return try inputs.map{try metadata($0,directory:directory,fields:[],removeAll:true)}
        case "compress":return try inputs.map{try compress($0,directory:directory,mode:options["videoCompressionMode"] ?? "preset",preset:options["videoCompressionPreset"] ?? "balanced",reduction:number("reduction",50),targetSize:number("targetSize",1),unit:options["targetUnit"] ?? "MB")}
        case "trimVideo":let source=try info(input),start=number("start",0),end=options["duration"] != nil ? start+number("duration",source.duration-start):number("end",source.duration);return [try trim(input,directory:directory,range:.init(start:start,end:end))]
        case "cropVideo":let source=try info(input);return [try crop(input,directory:directory,rect:CGRect(x:number("x",0),y:number("y",0),width:number("width",Double(source.width)),height:number("height",Double(source.height))))]
        case "changeVideoSpeed":return [try speed(input,directory:directory,multiplier:number("speed",1))]
        case "videoSnapshots":return try snapshots(input,directory:directory,times:(options["times"] ?? "0").split(separator:",").compactMap{Double($0)})
        case "splitVideo":let source=try info(input),cuts=(options["times"] ?? "").split(separator:",").compactMap{Double($0)}.sorted(),points=[0]+cuts+[source.duration];return try split(input,directory:directory,ranges:(0..<points.count-1).map{.init(start:points[$0],end:points[$0+1])},merge:options["merge"]=="true")
        case "redactVideo":let source=try info(input);return [try redact(input,directory:directory,layers:[.init(rect:CGRect(x:number("x",0),y:number("y",0),width:number("width",100),height:number("height",100)),range:.init(start:number("start",0),end:number("end",source.duration)),blur:options["style"]=="blur")])]
        default:throw UIError.message("Unsupported video tool: \(operation)")
        }
    }
}
