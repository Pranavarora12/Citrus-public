import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ImageAdjustment:Identifiable {
    let id:String
    let label:String
    let section:String
    let range:ClosedRange<Double>
    static let all:[ImageAdjustment] = [
        .init(id:"exposure",label:"Exposure",section:"Light",range:-3...3),
        .init(id:"brightness",label:"Brightness",section:"Light",range:-100...100),
        .init(id:"contrast",label:"Contrast",section:"Light",range:-100...100),
        .init(id:"highlights",label:"Highlights",section:"Light",range:-100...100),
        .init(id:"shadows",label:"Shadows",section:"Light",range:-100...100),
        .init(id:"whites",label:"Whites",section:"Light",range:-100...100),
        .init(id:"blacks",label:"Blacks",section:"Light",range:-100...100),
        .init(id:"gamma",label:"Gamma",section:"Light",range:-100...100),
        .init(id:"temperature",label:"Temperature",section:"Color",range:-100...100),
        .init(id:"tint",label:"Tint",section:"Color",range:-100...100),
        .init(id:"saturation",label:"Saturation",section:"Color",range:-100...100),
        .init(id:"vibrance",label:"Vibrance",section:"Color",range:-100...100),
        .init(id:"hue",label:"Hue",section:"Color",range:-180...180),
        .init(id:"clarity",label:"Clarity",section:"Detail",range:-100...100),
        .init(id:"texture",label:"Texture",section:"Detail",range:-100...100),
        .init(id:"sharpness",label:"Sharpness",section:"Detail",range:-100...100),
        .init(id:"noise",label:"Noise Reduction",section:"Detail",range:0...100),
        .init(id:"blur",label:"Blur",section:"Detail",range:0...100),
        .init(id:"dehaze",label:"Dehaze",section:"Effects",range:-100...100),
        .init(id:"fade",label:"Fade",section:"Effects",range:0...100),
        .init(id:"vignette",label:"Vignette",section:"Effects",range:-100...100),
        .init(id:"grain",label:"Grain",section:"Effects",range:0...100)
    ]
}

struct ImageBackground {
    var preset=0
    var color=NSColor.systemBlue
    var image:CGImage?
    var padding:Double=120
    var corners:Double=32
    var shadow:Double=24
    var ratio="Auto"
    static let gradients:[[NSColor]] = [
        [.systemPink,.systemOrange,.systemYellow,.systemPurple],
        [.systemCyan,.systemPurple,.systemOrange,.white],
        [.systemYellow,.systemGreen,.systemCyan], [.white,.systemPink,.systemPurple],
        [.systemPurple,.systemBlue,.systemCyan], [.systemOrange,.systemPink],
        [.systemGreen,.systemOrange,.systemBlue], [.systemCyan,.systemBlue],
        [.systemTeal,.systemMint], [.white,.systemPurple]
    ]
    static let solids:[NSColor] = [.white,.systemYellow,.systemGreen,.systemMint,.systemTeal,.systemCyan,.systemBlue,NSColor(srgbRed:0.08,green:0.16,blue:0.2,alpha:1),.systemPurple,.systemPink,.black]
}

struct ImageMetadataField:Identifiable {
    var id:String {path.joined(separator:"/")}
    var path:[String]
    var value:String
    var removed=false
    var edited=false
    var editable=true
    var group:String {path.count>1 ? path[0].replacingOccurrences(of:"{",with:"").replacingOccurrences(of:"}",with:"") : "Image"}
    var label:String {path.last!.replacingOccurrences(of:"_",with:" ")}
}

/// Image tools use oriented pixels throughout; all selection coordinates are top-left pixel coordinates.
enum ImageTools {
    static func load(_ url:URL)throws->CGImage {
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("citrus-editor-\(UUID()).png")
        defer{try? FileManager.default.removeItem(at:temporary)}
        try NativeImageConversion.normalizedPNG(url,to:temporary)
        guard let source=CGImageSourceCreateWithURL(temporary as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true,kCGImageSourceShouldCache:true] as CFDictionary),Double(image.width)*Double(image.height)<=100_000_000 else {throw UIError.message("Cannot open this image, or it exceeds the 100 megapixel editing limit.")}
        return image
    }
    static func scaled(_ image:CGImage,maxEdge:Int)->CGImage {
        guard max(image.width,image.height)>maxEdge else{return image}
        let scale=Double(maxEdge)/Double(max(image.width,image.height))
        return (try? bitmap(CGSize(width:max(1,(Double(image.width)*scale).rounded()),height:max(1,(Double(image.height)*scale).rounded()))){_ in
            draw(image,in:CGRect(x:0,y:0,width:max(1,(Double(image.width)*scale).rounded()),height:max(1,(Double(image.height)*scale).rounded())))
        }) ?? image
    }
    static func adjusted(_ original:CGImage,values:[String:Double])throws->CGImage {
        return try ImagePixels.adjusted(original,values:values)
    }
    static func bitmap(_ size:CGSize,draw:(CGContext)->Void)throws->CGImage {
        let w=Int(size.width.rounded()),h=Int(size.height.rounded())
        guard w>0,h>0,w<=32768,h<=32768,Double(w)*Double(h)<=100_000_000,let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let graphics=NSGraphicsContext(bitmapImageRep:bitmap) else{throw UIError.message("The output exceeds the 100 megapixel editing limit.")}
        NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
        let cg=graphics.cgContext;cg.translateBy(x:0,y:CGFloat(h));cg.scaleBy(x:1,y:-1)
        NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
        draw(cg)
        guard let image=bitmap.cgImage else{throw UIError.message("Could not render image.")};return image
    }
    static func draw(_ image:CGImage,in rect:CGRect) {NSImage(cgImage:image,size:.zero).draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high.rawValue])}
    static func background(_ original:CGImage,settings:ImageBackground)throws->CGImage {
        let p=max(0,settings.padding),w=Double(original.width),h=Double(original.height)
        var size=CGSize(width:w+2*p,height:h+2*p)
        let ratios:[String:Double] = ["1:1":1,"16:9":16/9,"4:5":0.8]
        if let ratio=ratios[settings.ratio] {if size.width/size.height<ratio {size.width=size.height*ratio}else{size.height=size.width/ratio}}
        return try bitmap(size){cg in
            let bounds=CGRect(origin:.zero,size:size)
            if settings.preset == -2,let custom=settings.image {
                let scale=max(size.width/CGFloat(custom.width),size.height/CGFloat(custom.height))
                draw(custom,in:CGRect(x:(size.width-CGFloat(custom.width)*scale)/2,y:(size.height-CGFloat(custom.height)*scale)/2,width:CGFloat(custom.width)*scale,height:CGFloat(custom.height)*scale))
            }else if settings.preset >= 0 {
                let colors=ImageBackground.gradients[settings.preset % ImageBackground.gradients.count]
                NSGradient(colors:colors)?.draw(in:bounds,angle:45)
            }else{settings.color.setFill();bounds.fill()}
            let rect=CGRect(x:(size.width-w)/2,y:(size.height-h)/2,width:w,height:h)
            let path=NSBezierPath(roundedRect:rect,xRadius:settings.corners,yRadius:settings.corners)
            cg.saveGState()
            if settings.shadow>0 {cg.setShadow(offset:CGSize(width:0,height:settings.shadow/3),blur:settings.shadow,color:NSColor.black.withAlphaComponent(0.45).cgColor);NSColor.black.setFill();path.fill()}
            cg.restoreGState();cg.saveGState();path.addClip();draw(original,in:rect);cg.restoreGState()
        }
    }
    static func unique(_ input:URL,directory:URL,suffix:String,ext:String="png")->URL {
        let stem=input.deletingPathExtension().lastPathComponent+" "+suffix
        var output=directory.appendingPathComponent(stem+"."+ext),index=1
        while FileManager.default.fileExists(atPath:output.path){index+=1;output=directory.appendingPathComponent(stem+" \(index)."+ext)}
        return output
    }
    static func save(_ image:CGImage,input:URL,directory:URL,suffix:String)throws->URL {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let output=unique(input,directory:directory,suffix:suffix)
        try encoded(image,type:"public.png",quality:1).write(to:output,options:.withoutOverwriting);return output
    }
    static func encoded(_ image:CGImage,type:String,quality:Double)throws->Data {
        let data=NSMutableData()
        guard let writer=CGImageDestinationCreateWithData(data,type as CFString,1,nil) else{throw UIError.message("This image encoder is unavailable.")}
        CGImageDestinationAddImage(writer,image,[kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else{throw UIError.message("Could not encode image.")};return data as Data
    }
    static func compress(_ input:URL,directory:URL,mode:String,preset:String,reduction:Double,size:Double,unit:String)throws->URL {
        let source=try load(input),original=try Data(contentsOf:input).count
        let target:Int?
        if mode=="percentage" {guard reduction>=1,reduction<=99 else{throw UIError.message("Choose a reduction from 1 to 99 percent.")};target=max(1,Int(Double(original)*(1-reduction/100)))}
        else if mode=="fileSize" {let bytes=size*(unit=="MB" ? 1_000_000:1000);guard bytes.isFinite,bytes>=100,bytes<=1_000_000_000 else{throw UIError.message("Enter a size between 0.1 KB and 1 GB.")};target=Int(bytes)}
        else{target=nil}
        // Keep alpha by choosing PNG. JPEG outputs use a white matte, never an accidental black background.
        let transparent=[CGImageAlphaInfo.first,.last,.premultipliedFirst,.premultipliedLast].contains(source.alphaInfo) && hasTransparency(source)
        let type=transparent ? "public.png":"public.jpeg",ext=transparent ? "png":"jpg"
        var image=source,best:Data?
        for _ in 0..<24 {
            if transparent {best=try encoded(image,type:type,quality:1)}
            else if let target {
                var low=0.02,high=0.96
                best=nil
                for _ in 0..<8 {let q=(low+high)/2,data=try encoded(image,type:type,quality:q);if data.count<=target{best=data;low=q}else{high=q}}
                if best==nil {best=try encoded(image,type:type,quality:0.02)}
            }else{best=try encoded(image,type:type,quality:preset=="small" ? 0.45:preset=="high" ? 0.9:0.72)}
            if let data=best,target==nil || data.count<=target! {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let output=unique(input,directory:directory,suffix:"Compressed",ext:ext);try data.write(to:output,options:.withoutOverwriting);return output
            }
            guard max(image.width,image.height)>1 else{break}
            let scale=min(0.85,max(0.25,sqrt(Double(target ?? 1)/Double(best?.count ?? 1))*0.9))
            let edge=max(1,Int(Double(max(image.width,image.height))*scale));image=scaled(image,maxEdge:edge)
        }
        throw UIError.message("The requested size is too small to encode a valid image. Choose a larger size.")
    }
    static func hasTransparency(_ image:CGImage)->Bool {
        guard let cg=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let bytes=cg.data?.assumingMemoryBound(to:UInt8.self) else{return false}
        cg.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        for y in 0..<image.height {for x in 0..<image.width where bytes[y*cg.bytesPerRow+x*4+3]<255{return true}};return false
    }
    static func metadata(_ input:URL)throws->[ImageMetadataField] {
        guard let source=CGImageSourceCreateWithURL(input as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] else{throw UIError.message("Cannot read image metadata.")}
        var fields:[ImageMetadataField]=[]
        func walk(_ dictionary:[String:Any],_ path:[String]) {for key in dictionary.keys.sorted(){let value=dictionary[key]!;if let nested=value as? [String:Any]{walk(nested,path+[key])}else{fields.append(.init(path:path+[key],value:String(describing:value),editable:(value is String || value is NSNumber) && !["PixelWidth","PixelHeight","Depth","ColorModel","ProfileName","HasAlpha","PixelXDimension","PixelYDimension"].contains(key)))}}}
        walk(properties,[]);return fields
    }
    static func saveMetadata(_ input:URL,directory:URL,fields:[ImageMetadataField],removeAll:Bool)throws->URL {
        guard let source=CGImageSourceCreateWithURL(input as CFURL,nil),let type=CGImageSourceGetType(source),(CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(type as String) else{throw UIError.message("Metadata editing is unavailable for this image format.")}
        let output=unique(input,directory:directory,suffix:"Metadata",ext:input.pathExtension)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        guard let writer=CGImageDestinationCreateWithURL(output as CFURL,type,CGImageSourceGetCount(source),nil) else{throw UIError.message("Cannot create image metadata output.")}
        for index in 0..<CGImageSourceGetCount(source) {
            var properties=(CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [String:Any]) ?? [:]
            if removeAll {
                // Baking orientation into pixels prevents removal from rotating a portrait sideways.
                guard let raw=CGImageSourceCreateImageAtIndex(source,index,nil) else{throw UIError.message("Cannot decode image frame.")}
                let orientation=(properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
                let image:CGImage
                if orientation == 1 {image=raw}
                else{guard let transformed=CGImageSourceCreateThumbnailAtIndex(source,index,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(raw.width,raw.height),kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw UIError.message("Cannot normalize image orientation.")};image=transformed}
                // Preserve only animation timing, so metadata removal doesn't destroy playback.
                let timing=properties.filter{$0.key==kCGImagePropertyGIFDictionary as String || $0.key==kCGImagePropertyPNGDictionary as String}.mapValues{ value -> Any in
                    guard let dict=value as? [String:Any] else{return [:] as [String:Any]};return dict.filter{$0.key.lowercased().contains("delay") || $0.key.lowercased().contains("loop")}
                }
                CGImageDestinationAddImage(writer,image,timing as CFDictionary)
            }else{
                func update(_ dictionary:inout [String:Any],path:ArraySlice<String>,field:ImageMetadataField){
                    guard let key=path.first else{return}
                    if path.count>1 {var nested=dictionary[key] as? [String:Any] ?? [:];update(&nested,path:path.dropFirst(),field:field);dictionary[key]=nested}
                    else if field.removed {dictionary.removeValue(forKey:key)}
                    else if field.edited {if let old=dictionary[key] as? NSNumber {dictionary[key]=CFGetTypeID(old)==CFBooleanGetTypeID() ? NSNumber(value:field.value=="true" || field.value=="1") : NSNumber(value:Double(field.value) ?? old.doubleValue)}else{dictionary[key]=field.value}}
                }
                for field in fields where field.editable && (field.removed || field.edited) {
                    var old:Any?=properties
                    for key in field.path{old=(old as? [String:Any])?[key]}
                    if !field.removed,field.edited,let number=old as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(){
                        guard let value=Double(field.value),value.isFinite else{throw UIError.message("Enter a number for \(field.label).")}
                    }
                    update(&properties,path:field.path[...],field:field)
                }
                guard let image=CGImageSourceCreateImageAtIndex(source,index,nil) else{throw UIError.message("Cannot decode image frame.")}
                CGImageDestinationAddImage(writer,image,properties as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(writer) else{try? FileManager.default.removeItem(at:output);throw UIError.message("Could not save metadata.")};return output
    }
    static func detectedRegions(_ image:CGImage,text:Bool)throws->[CGRect] {
        let handler=VNImageRequestHandler(cgImage:image)
        let boxes:[CGRect]
        if text {let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;try handler.perform([request]);boxes=(request.results ?? []).map(\.boundingBox)}
        else{let request=VNDetectFaceRectanglesRequest();try handler.perform([request]);boxes=(request.results ?? []).map(\.boundingBox)}
        return boxes.map{CGRect(x:$0.minX*CGFloat(image.width),y:(1-$0.maxY)*CGFloat(image.height),width:$0.width*CGFloat(image.width),height:$0.height*CGFloat(image.height)).insetBy(dx:-2,dy:-2).intersection(CGRect(x:0,y:0,width:image.width,height:image.height))}
    }
}
