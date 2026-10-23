import Foundation
import AppKit
import CoreImage
import ImageIO
import Vision

/// Local, destructive-free processing. All destinations are new files.
struct MediaEngine {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }

    static func run(_ operation: String, inputs: [URL], outputDirectory: URL, options: [String: String]) throws -> [URL] {
        guard !inputs.isEmpty else { throw Failure.message("Choose at least one input file.") }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for input in inputs where !FileManager.default.fileExists(atPath: input.path) { throw Failure.message("Input does not exist: \(input.lastPathComponent)") }
        let imageOperations: Set<String> = ["resizeImage", "cropImage", "rotateImage", "editImage", "redactImage", "frameImage", "annotateImage", "createCollage", "readQRCode"]
        if imageOperations.contains(operation) { return try images(operation, inputs, outputDirectory, options) }
        if operation == "joinVideos" {
            guard inputs.count > 1 else { throw Failure.message("Choose at least two videos to join.") }
            let output = destination(inputs[0], outputDirectory, "joined", "mp4")
            var args = inputs.flatMap { ["-i", $0.path] }
            // Normalize geometry, frame rate, and timestamps before concatenating video.
            var filters = inputs.indices.map { "[\($0):v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,setpts=PTS-STARTPTS[v\($0)]" }
            for (index, input) in inputs.enumerated() {
                if try hasAudio(input) { filters.append("[\(index):a]aresample=48000,aformat=channel_layouts=stereo,asetpts=PTS-STARTPTS[a\(index)]") }
                else {
                    let length = try duration(input)
                    filters.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(length),asetpts=PTS-STARTPTS[a\(index)]")
                }
            }
            let concat = inputs.indices.map { "[v\($0)][a\($0)]" }.joined() + "concat=n=\(inputs.count):v=1:a=1[outv][outa]"
            args += ["-filter_complex", (filters + [concat]).joined(separator: ";"), "-map", "[outv]", "-map", "[outa]", "-c:v", "libx264", "-c:a", "aac", "-pix_fmt", "yuv420p", output.path]
            try ffmpeg(args)
            return [output]
        }
        var outputs: [URL] = []
        for input in inputs {
            var args = ["-i", input.path]
            var ext = input.pathExtension.lowercased()
            if ext.isEmpty { ext = "mp4" }
            switch operation {
            case "convert":
                ext = (options["format"] ?? "png").lowercased().replacingOccurrences(of: ".", with: "")
                guard ["png", "jpg", "jpeg", "webp", "gif", "tiff", "bmp", "heic", "avif", "mp3", "wav", "aac", "m4a", "flac", "ogg", "opus", "aiff", "wma", "mp4", "mov", "mkv", "webm", "avi", "wmv"].contains(ext) else { throw Failure.message("Unsupported output format: \(ext)") }
                if ["jpg","jpeg","png","tiff","bmp","gif","webp","heic","avif"].contains(ext) {
                    let output=destination(input,outputDirectory,operation,ext)
                    if try NativeImageConversion.write(input,to:output,format:ext,options:options){outputs.append(output);continue}
                }
                if ext == "webp" {
                    let output = destination(input, outputDirectory, operation, "webp")
                    try webp(input, output, options); outputs.append(output); continue
                }
                if ["png", "jpg", "jpeg", "webp", "tiff", "bmp", "avif"].contains(ext) { args += ["-frames:v", "1"] }
                if ["jpg", "jpeg", "webp"].contains(ext) {
                    let quality = try number(options, "quality", 80, minimum: 1, maximum: 100)
                    args += ext == "webp" ? ["-quality", "\(Int(quality))"] : ["-q:v", "\(max(2, Int(31-quality*0.29)))"]
                }
                if ["mp3", "wav", "aac", "m4a", "flac", "ogg", "opus", "aiff", "wma"].contains(ext) { args += ["-vn"] }
                if ext == "ogg" {
                    let bitrate=try number(options,"audioBitrate",192,minimum:32,maximum:512)
                    args += ["-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-ar", "48000", "-b:a", "\(Int(bitrate))k"]
                }
                args += try conversionSettings(input,ext,options)
            case "compress":
                let quality = try number(options, "quality", 75, minimum: 1, maximum: 100)
                if ["jpg", "jpeg", "png", "webp", "tiff", "bmp", "heic"].contains(ext) {
                    ext = options["compressionFormat"] ?? "jpg"
                    if ext == "webp" {
                        let output = destination(input, outputDirectory, operation, "webp")
                        try webp(input, output, options); outputs.append(output); continue
                    }
                    args += ["-frames:v", "1"]
                    if ext == "webp" { args += ["-quality", "\(Int(quality))"] }
                    else { ext = "jpg"; args += ["-q:v", "\(max(2, Int(31 - quality * 0.29)))"] }
                    if let edge=Int(options["maxImageEdge"] ?? "0"),edge>0 {args += ["-vf","scale=w='if(gte(iw,ih),min(iw,\(edge)),-2)':h='if(gt(ih,iw),min(ih,\(edge)),-2)'"]}
                    else if let widthText = options["width"], !widthText.isEmpty { let width = try number(options, "width", 1280, minimum: 1, maximum: 32000); args += ["-vf", "scale=w='min(\(Int(width)),iw)':h=-1"] }
                } else if ["mp3", "wav", "aac", "m4a", "flac", "ogg"].contains(ext) {
                    ext = "mp3"; args += ["-vn", "-b:a", "\(Int(64 + quality * 2.56))k"]
                } else {
                    let crf = try number(options, "crf", 40 - quality * 0.3, minimum: 0, maximum: 51)
                    ext = "mp4"; args += ["-c:v", "libx264", "-crf", "\(Int(crf))", "-c:a", "aac", "-movflags", "+faststart"]
                    if let text = options["width"], !text.isEmpty { let width = try number(options, "width", 1280, minimum: 2, maximum: 32000); args += ["-vf", "scale=\(Int(width)/2*2):-2"] }
                }
            case "trimAudio", "trimVideo":
                let start = try number(options, "start", 0, minimum: 0)
                let length = try number(options, "duration", 10, minimum: 0.001)
                let end = options["duration"] != nil ? start + length : try number(options, "end", start + length, minimum: start + 0.001)
                args += ["-ss", "\(start)", "-t", "\(end-start)"]
                if operation == "trimAudio" { ext = "wav"; args += ["-vn"] } else { ext = "mp4"; args += videoEncoding }
            case "normalizeAudio":
                let loudness = try number(options, "loudness", -16, minimum: -70, maximum: -5)
                ext = "wav"; args += ["-vn", "-af", "loudnorm=I=\(loudness):TP=-1.5:LRA=11"]
            case "audioChannels":
                let channels = Int(try number(options, "channels", 1, minimum: 1, maximum: 2))
                ext = "wav"; args += ["-vn", "-ac", "\(channels)"]
            case "redactAudio":
                let start = try number(options, "start", 0, minimum: 0)
                let end = try number(options, "end", start + 1, minimum: start + 0.001)
                ext = "wav"
                args += ["-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=\(end-start)", "-filter_complex", "[0:a]volume=enable='between(t,\(start),\(end))':volume=0[original];[1:a]adelay=\(Int(start*1000)):all=1[bleep];[original][bleep]amix=inputs=2:duration=first:normalize=0[out]", "-map", "[out]"]
            case "audioToVideo":
                ext = "mp4"
                args = ["-i", input.path, "-filter_complex", "[0:a]showwaves=s=1280x720:mode=line:rate=25:colors=0xff7d33,format=yuv420p[v]", "-map", "[v]", "-map", "0:a", "-shortest", "-c:v", "libx264", "-c:a", "aac", "-pix_fmt", "yuv420p"]
            case "cropVideo":
                let width = try number(options, "width", 640, minimum: 2)
                let height = try number(options, "height", 480, minimum: 2)
                let x = try number(options, "x", 0, minimum: 0), y = try number(options, "y", 0, minimum: 0)
                ext = "mp4"; args += ["-vf", "crop=\(Int(width)): \(Int(height)):\(Int(x)):\(Int(y))".replacingOccurrences(of: " ", with: "")] + videoEncoding
            case "muteVideo":
                ext = "mp4"; args += ["-an", "-c:v", "libx264", "-pix_fmt", "yuv420p"]
            case "changeVideoSpeed":
                let speed = try number(options, "speed", 2, minimum: 0.125, maximum: 8)
                ext = "mp4"
                var remaining = speed, tempos: [String] = []
                while remaining > 2 { tempos.append("atempo=2"); remaining /= 2 }
                while remaining < 0.5 { tempos.append("atempo=0.5"); remaining /= 0.5 }
                tempos.append("atempo=\(remaining)")
                let rateText = try execute("/opt/homebrew/bin/ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=avg_frame_rate", "-of", "csv=p=0", input.path]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rateParts = rateText.split(separator: "/").compactMap { Double($0) }
                let rate = rateParts.count == 2 && rateParts[1] > 0 ? rateParts[0]/rateParts[1] : 30
                args += ["-vf", "setpts=(PTS-STARTPTS)/\(speed)", "-r", "\(max(0.1, rate*speed))"]
                if try hasAudio(input) { args += ["-af", tempos.joined(separator: ",")] }
                args += videoEncoding
            case "redactVideo":
                let x = try number(options, "x", 0, minimum: 0), y = try number(options, "y", 0, minimum: 0)
                let width = try number(options, "width", 100, minimum: 1), height = try number(options, "height", 100, minimum: 1)
                let chosen = try color(options["color"] ?? "black").usingColorSpace(.sRGB)!
                let hex = String(format: "0x%02x%02x%02x", Int(chosen.redComponent*255), Int(chosen.greenComponent*255), Int(chosen.blueComponent*255))
                ext = "mp4"; args += ["-vf", "drawbox=x=\(Int(x)):y=\(Int(y)):w=\(Int(width)):h=\(Int(height)):color=\(hex):t=fill"] + videoEncoding
            case "videoSnapshots":
                if let timesText = options["times"], !timesText.isEmpty {
                    let times = try timestamps(timesText)
                    for time in times {
                        let output = destination(input, outputDirectory, "frame-\(time)", "png")
                        try ffmpeg(["-ss", "\(time)", "-i", input.path, "-frames:v", "1", output.path])
                        guard FileManager.default.fileExists(atPath: output.path) else { throw Failure.message("No frame exists at \(time) seconds.") }
                        outputs.append(output)
                    }
                    continue
                }
                let interval = try number(options, "interval", 5, minimum: 0.1)
                let folder = outputDirectory.appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)-snapshots-\(UUID().uuidString.prefix(8))")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try ffmpeg(args + ["-vf", "fps=1/\(interval)", "-frames:v", "1000", folder.appendingPathComponent("frame-%04d.png").path])
                outputs += try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                continue
            case "splitVideo":
                if let timesText = options["times"], !timesText.isEmpty {
                    let length = try duration(input)
                    let times = try timestamps(timesText)
                    guard times.allSatisfy({ $0 > 0 && $0 < length }) else { throw Failure.message("Split times must be between zero and the video duration (\(length) seconds).") }
                    let boundaries = [0.0] + times + [length]
                    for index in 0..<(boundaries.count-1) {
                        let output = destination(input, outputDirectory, "part-\(index+1)", "mp4")
                        try ffmpeg(["-ss", "\(boundaries[index])", "-i", input.path, "-t", "\(boundaries[index+1]-boundaries[index])"] + videoEncoding + [output.path])
                        outputs.append(output)
                    }
                    continue
                }
                let segment = try number(options, "duration", 10, minimum: 0.1)
                let durationText = try execute("/opt/homebrew/bin/ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", input.path])
                guard let duration = Double(durationText.trimmingCharacters(in: .whitespacesAndNewlines)), duration.isFinite, duration > 0 else { throw Failure.message("Cannot determine video duration.") }
                guard duration / segment <= 1000 else { throw Failure.message("Choose a longer segment duration (maximum 1,000 segments).") }
                var start = 0.0, index = 1
                while start < duration {
                    let output = destination(input, outputDirectory, "part-\(index)", "mp4")
                    try ffmpeg(["-ss", "\(start)", "-i", input.path, "-t", "\(min(segment, duration-start))"] + videoEncoding + [output.path])
                    outputs.append(output); start += segment; index += 1
                }
                continue
            default: throw Failure.message("Unsupported operation: \(operation)")
            }
            let output = destination(input, outputDirectory, operation, ext)
            do { try ffmpeg(args + [output.path]); outputs.append(output) }
            catch { try? FileManager.default.removeItem(at: output); throw error }
        }
        return outputs
    }

    private static let videoEncoding = ["-c:v", "libx264", "-c:a", "aac", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    private static func destination(_ input: URL, _ directory: URL, _ suffix: String, _ ext: String) -> URL {
        directory.appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)-\(suffix)-\(UUID().uuidString.prefix(8)).\(ext)")
    }
    private static func number(_ options: [String: String], _ key: String, _ fallback: Double, minimum: Double = -Double.greatestFiniteMagnitude, maximum: Double = Double.greatestFiniteMagnitude) throws -> Double {
        let text = options[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let value = Double(text.isEmpty ? "\(fallback)" : text), value.isFinite, value >= minimum, value <= maximum else { throw Failure.message("Invalid \(key). Expected a number between \(minimum) and \(maximum).") }
        return value
    }
    @discardableResult private static func execute(_ executable: String, _ arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw Failure.message("Required media tool is missing: \(executable)") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw Failure.message("Media processing failed: \(text.suffix(2400))") }
        return text
    }
    private static func ffmpeg(_ arguments: [String]) throws { try execute("/opt/homebrew/bin/ffmpeg", ["-hide_banner", "-loglevel", "error", "-nostdin", "-n"] + arguments) }
    private static func hasAudio(_ input: URL) throws -> Bool {
        !(try execute("/opt/homebrew/bin/ffprobe", ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", input.path])).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static func duration(_ input: URL) throws -> Double {
        let value = try execute("/opt/homebrew/bin/ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", input.path])
        guard let duration = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), duration > 0, duration.isFinite else { throw Failure.message("Cannot determine duration of \(input.lastPathComponent).") }
        return duration
    }
    private static func timestamps(_ text: String) throws -> [Double] {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !numbers.isEmpty, numbers.count == parts.count, numbers.count <= 1000, numbers.allSatisfy({ $0.isFinite && $0 >= 0 }), Set(numbers).count == numbers.count else { throw Failure.message("Enter unique, nonnegative times separated by commas.") }
        return numbers.sorted()
    }
    private static func conversionSettings(_ input:URL,_ format:String,_ options:[String:String])throws->[String] {
        var args:[String]=[]
        if let preserve=options["preserveMetadata"] {args += ["-map_metadata",preserve=="false" ? "-1":"0"]}
        if let bitrate=options["audioBitrate"],["mp3","m4a","opus","wma"].contains(format) {let value=try number(["bitrate":bitrate],"bitrate",256,minimum:32,maximum:512);args += ["-b:a","\(Int(value))k"]}
        if ["wav","aiff"].contains(format),let chosen=options["audioBitDepth"] {
            var depth=chosen
            if depth=="source" {
                let raw=try execute("/opt/homebrew/bin/ffprobe",["-v","error","-select_streams","a:0","-show_entries","stream=bits_per_sample,bits_per_raw_sample,sample_fmt","-of","json",input.path])
                let object=(try? JSONSerialization.jsonObject(with:Data(raw.utf8))) as? [String:Any]
                let stream=(object?["streams"] as? [[String:Any]])?.first ?? [:]
                let bits=Int(String(describing:stream["bits_per_raw_sample"] ?? stream["bits_per_sample"] ?? "0")) ?? 0
                depth=bits==24 ? "24":bits==32 ? "32":String(describing:stream["sample_fmt"] ?? "").hasPrefix("flt") ? "float32":"16"
            }
            guard ["16","24","32","float32"].contains(depth) else{throw Failure.message("Choose a valid audio bit depth.")}
            let order=format=="aiff" ? "be":"le"
            args += ["-c:a",depth=="float32" ? "pcm_f32\(order)":"pcm_s\(depth)\(order)"]
        }
        if format=="flac",let preset=options["flacCompression"] {args += ["-compression_level",preset=="faster" ? "0":preset=="smallest" ? "12":"5"]}
        if ["mp4","mov","mkv","webm","avi","wmv"].contains(format),let quality=options["qualityPreset"] {
            if format=="webm" {args += ["-c:v","libvpx-vp9","-crf",quality=="higher" ? "24":quality=="smaller" ? "40":"32","-b:v","0","-c:a","libopus","-pix_fmt","yuv420p"]}
            else if ["avi","wmv"].contains(format){args += ["-q:v",quality=="higher" ? "2":quality=="smaller" ? "10":"5"]}
            else{args += ["-c:v","libx264","-crf",quality=="higher" ? "18":quality=="smaller" ? "28":"23","-c:a","aac","-pix_fmt","yuv420p"]}
            if let height=Int(options["maxVideoHeight"] ?? "0"),height>0 {args += ["-vf","scale=-2:'trunc(min(ih,\(height))/2)*2'"]}
        }
        if format=="gif",options["gifFrameRate"] != nil || options["gifMaxWidth"] != nil {
            let rate=try number(options,"gifFrameRate",15,minimum:1,maximum:60),width=try number(options,"gifMaxWidth",960,minimum:16,maximum:4096)
            args += ["-vf","fps=\(Int(rate)),scale='min(iw,\(Int(width)))':-1:flags=lanczos"]
        }
        if format=="avif",options["qualityPreset"] != nil {args += ["-crf",options["qualityPreset"]=="higher" ? "18":options["qualityPreset"]=="smaller" ? "40":"28"]}
        if format=="webm",options["qualityPreset"] == nil {args += ["-c:v","libvpx-vp9","-pix_fmt","yuv420p","-c:a","libopus"]}
        return args
    }
    private static func webp(_ input: URL, _ output: URL, _ options: [String: String]) throws {
        let quality = try number(options, "quality", 80, minimum: 1, maximum: 100)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("citrus-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try NativeImageConversion.normalizedPNG(input,to:temp)
        let image=try load(temp)
        var args=["-quiet","-q","\(quality)","-metadata",options["preserveMetadata"]=="false" ? "none":"all"]
        if let edge=Int(options["maxImageEdge"] ?? "0"),edge>0,max(image.width,image.height)>edge {
            let ratio=Double(edge)/Double(max(image.width,image.height));args += ["-resize",String(max(1,Int(Double(image.width)*ratio))),String(max(1,Int(Double(image.height)*ratio)))]
        }
        try execute("/opt/homebrew/bin/cwebp",args+[temp.path,"-o",output.path])
    }

    private static func images(_ operation: String, _ inputs: [URL], _ directory: URL, _ options: [String: String]) throws -> [URL] {
        if operation == "createCollage" {
            let loaded = try inputs.map(load)
            let columns = Int(try number(options, "columns", ceil(sqrt(Double(loaded.count))), minimum: 1, maximum: 30))
            let rows = (loaded.count + columns - 1) / columns
            let cell = Int(try number(options, "cellSize", 512, minimum: 16, maximum: 4096))
            let width = Int(try number(options, "width", Double(columns*cell), minimum: 16, maximum: 32000))
            let height = Int(try number(options, "height", Double(rows*cell), minimum: 16, maximum: 32000))
            let spacing = try number(options, "spacing", 12, minimum: 0)
            let cellWidth = (Double(width)-spacing*Double(columns+1))/Double(columns)
            let cellHeight = (Double(height)-spacing*Double(rows+1))/Double(rows)
            guard cellWidth > 0, cellHeight > 0 else { throw Failure.message("Spacing is too large for the collage canvas.") }
            let context = try canvas(width, height)
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (index, image) in loaded.enumerated() {
                let scale = min(cellWidth/Double(image.width), cellHeight/Double(image.height))
                let w = Double(image.width)*scale, h = Double(image.height)*scale
                let x = spacing + Double(index % columns)*(cellWidth+spacing)+(cellWidth-w)/2
                let y = spacing + Double(rows-1-index/columns)*(cellHeight+spacing)+(cellHeight-h)/2
                context.draw(image, in: CGRect(x: x, y: y, width: w, height: h))
            }
            let output = destination(inputs[0], directory, "collage", "png"); try save(context.makeImage()!, output); return [output]
        }
        var outputs: [URL] = []
        for input in inputs {
            let original = try load(input)
            var result = original
            let w = original.width, h = original.height
            switch operation {
            case "resizeImage":
                let width = Int(try number(options, "width", Double(w), minimum: 1, maximum: 32000))
                let height = Int(try number(options, "height", Double(h)*Double(width)/Double(w), minimum: 1, maximum: 32000))
                let context = try canvas(width, height); context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height)); result = context.makeImage()!
            case "cropImage":
                let x = try number(options, "x", 0, minimum: 0), y = try number(options, "y", 0, minimum: 0)
                let width = try number(options, "width", Double(w)-x, minimum: 1), height = try number(options, "height", Double(h)-y, minimum: 1)
                guard x+width <= Double(w), y+height <= Double(h), let cropped = original.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else { throw Failure.message("Crop rectangle must fit within the image (\(w) × \(h)).") }
                result = cropped
            case "rotateImage":
                let degrees = try number(options, "angle", 90)
                let radians = degrees * .pi / 180
                let width = Int(ceil(abs(Double(w)*cos(radians))+abs(Double(h)*sin(radians))-0.00000001))
                let height = Int(ceil(abs(Double(w)*sin(radians))+abs(Double(h)*cos(radians))-0.00000001))
                let context = try canvas(width, height)
                context.translateBy(x: Double(width)/2, y: Double(height)/2); context.rotate(by: -radians)
                context.draw(original, in: CGRect(x: -Double(w)/2, y: -Double(h)/2, width: Double(w), height: Double(h))); result = context.makeImage()!
            case "editImage":
                let brightness = try number(options, "brightness", 0, minimum: -1, maximum: 1)
                let contrast = try number(options, "contrast", 1, minimum: 0, maximum: 4)
                let saturation = try number(options, "saturation", 1, minimum: 0, maximum: 4)
                let context = try canvas(w, h)
                context.draw(original, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let data = context.data else { throw Failure.message("Cannot access image pixels.") }
                let pixels = data.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let offset = y*context.bytesPerRow+x*4
                    let alpha = Double(pixels[offset+3])/255
                    guard alpha > 0 else { continue }
                    let r = Double(pixels[offset])/255/alpha, g = Double(pixels[offset+1])/255/alpha, b = Double(pixels[offset+2])/255/alpha
                    let luminance = 0.2126*r+0.7152*g+0.0722*b
                    for (channel, component) in [r,g,b].enumerated() {
                        let adjusted = ((luminance+(component-luminance)*saturation)-0.5)*contrast+0.5+brightness
                        pixels[offset+channel] = UInt8(max(0,min(255,(adjusted*alpha*255).rounded())))
                    }
                } }
                result = context.makeImage()!
            case "redactImage", "frameImage", "annotateImage":
                let padding = options["padding"] ?? options["border"] ?? "24"
                let border = operation == "frameImage" ? Int(try number(["padding": padding], "padding", 24, minimum: 1, maximum: 2000)) : 0
                let context = try canvas(w+border*2, h+border*2)
                context.setFillColor(try color(options["color"] ?? "#ffffff").cgColor); context.fill(CGRect(x: 0, y: 0, width: w+border*2, height: h+border*2))
                context.draw(original, in: CGRect(x: border, y: border, width: w, height: h))
                if operation == "redactImage" {
                    let x = try number(options, "x", 0, minimum: 0), y = try number(options, "y", 0, minimum: 0)
                    let width = try number(options, "width", 100, minimum: 1), height = try number(options, "height", 100, minimum: 1)
                    guard x+width <= Double(w), y+height <= Double(h) else { throw Failure.message("Redaction rectangle must fit within the image.") }
                    context.setFillColor(try color(options["color"] ?? "black").cgColor); context.fill(CGRect(x: x, y: Double(h)-y-height, width: width, height: height))
                } else if operation == "annotateImage" {
                    let text = options["text"] ?? "Annotation"
                    guard !text.isEmpty else { throw Failure.message("Enter annotation text.") }
                    let size = try number(options, "fontSize", max(18, Double(w)/24), minimum: 1, maximum: 1000)
                    let x = try number(options, "x", 20, minimum: 0), y = try number(options, "y", 20, minimum: 0)
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.white, .strokeColor: NSColor.black, .strokeWidth: -3]
                    (text as NSString).draw(at: NSPoint(x: x, y: Double(h)-y-size*1.3), withAttributes: attributes)
                    NSGraphicsContext.restoreGraphicsState()
                }
                result = context.makeImage()!
            case "readQRCode":
                let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
                try VNImageRequestHandler(cgImage: original).perform([request])
                let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
                guard !payloads.isEmpty else { throw Failure.message("No readable QR code found in \(input.lastPathComponent).") }
                let output = destination(input, directory, "qr", "txt")
                try payloads.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8); outputs.append(output); continue
            default: throw Failure.message("Unsupported image operation: \(operation)")
            }
            let output = destination(input, directory, operation, "png"); try save(result, output); outputs.append(output)
        }
        return outputs
    }
    private static func color(_ text: String) throws -> NSColor {
        let named: [String: NSColor] = ["white": .white, "black": .black, "red": .red, "blue": .blue, "green": .green, "clear": .clear]
        if let value = named[text.lowercased()] { return value }
        let hex = text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { throw Failure.message("Use a color name or a six digit hex color such as #ff8800.") }
        return NSColor(srgbRed: Double((value >> 16)&255)/255, green: Double((value >> 8)&255)/255, blue: Double(value&255)/255, alpha: 1)
    }
    private static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.message("Cannot read image: \(url.lastPathComponent)") }
        return image
    }
    private static func canvas(_ width: Int, _ height: Int) throws -> CGContext {
        guard width > 0, height > 0, Double(width)*Double(height) <= 150_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.message("Image dimensions are too large to process.") }
        context.interpolationQuality = .high; return context
    }
    private static func save(_ image: CGImage, _ url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw Failure.message("Cannot create image output.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.message("Cannot save image output.") }
    }
}
