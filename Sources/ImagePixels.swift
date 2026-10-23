import AppKit

/// CPU rendering also works without a Metal/Core Image rendering service.
/// The pixel pipeline keeps geometry and alpha unchanged.
enum ImagePixels {
    static func buffer(_ image:CGImage)throws->CGContext {
        guard let cg=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw UIError.message("Cannot allocate image pixels.")}
        cg.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return cg
    }
    static func boxBlur(_ source:[Float],width:Int,height:Int,radius:Int)->[Float] {
        guard radius>0 else{return source}
        let r=min(max(width,height),radius),span=Float(r*2+1)
        var horizontal=[Float](repeating:0,count:source.count),result=horizontal
        for y in 0..<height {for channel in 0..<4 {
            var sum:Float=0
            for x in -r...r{sum += source[(y*width+min(width-1,max(0,x)))*4+channel]}
            for x in 0..<width {horizontal[(y*width+x)*4+channel]=sum/span;let add=min(width-1,x+r+1),remove=max(0,x-r);sum += source[(y*width+add)*4+channel]-source[(y*width+remove)*4+channel]}
        }}
        for x in 0..<width {for channel in 0..<4 {
            var sum:Float=0
            for y in -r...r{sum += horizontal[(min(height-1,max(0,y))*width+x)*4+channel]}
            for y in 0..<height {result[(y*width+x)*4+channel]=sum/span;let add=min(height-1,y+r+1),remove=max(0,y-r);sum += horizontal[(add*width+x)*4+channel]-horizontal[(remove*width+x)*4+channel]}
        }}
        return result
    }
    static func rgba(_ image:CGImage)throws->[Float] {
        let cg=try buffer(image);guard let bytes=cg.data?.assumingMemoryBound(to:UInt8.self) else{throw UIError.message("Cannot access image pixels.")}
        var result=[Float](repeating:0,count:image.width*image.height*4)
        for y in 0..<image.height {for x in 0..<image.width {let p=(y*image.width+x)*4,offset=y*cg.bytesPerRow+x*4;for c in 0..<4{result[p+c]=Float(bytes[offset+c])/255}}}
        return result
    }
    static func image(_ values:[Float],width:Int,height:Int)throws->CGImage {
        guard let cg=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let bytes=cg.data?.assumingMemoryBound(to:UInt8.self) else{throw UIError.message("Cannot create rendered pixels.")}
        for y in 0..<height {for x in 0..<width {let p=(y*width+x)*4,offset=y*cg.bytesPerRow+x*4;for c in 0..<4{bytes[offset+c]=UInt8(max(0,min(255,(values[p+c]*255).rounded())))}}}
        guard let image=cg.makeImage() else{throw UIError.message("Could not render image pixels.")};return image
    }
    static func blurred(_ source:CGImage,radius:Double)throws->CGImage {
        var pixels=try rgba(source)
        // Three box passes approximate a Gaussian without requiring GPU services.
        let r=max(1,Int(radius/2))
        for _ in 0..<3{pixels=boxBlur(pixels,width:source.width,height:source.height,radius:r)}
        return try image(pixels,width:source.width,height:source.height)
    }
    static func adjusted(_ source:CGImage,values:[String:Double])throws->CGImage {
        guard values.values.allSatisfy({$0.isFinite}) else{throw UIError.message("Adjustment values must be finite numbers.")}
        let width=source.width,height=source.height
        var pixels=try rgba(source)
        func v(_ key:String)->Float{Float(values[key] ?? 0)}
        let exposure=pow(Float(2),v("exposure")),contrast=pow(Float(2),v("contrast")/100),brightness=v("brightness")/200,saturation=1+v("saturation")/100
        let temperature=v("temperature")/500,tint=v("tint")/600,gamma=pow(Float(2),-v("gamma")/100)
        let angle=v("hue") * .pi/180,cosine=cos(angle),sine=sin(angle)
        let hue=v("hue") != 0,vignette=v("vignette")/100,grain=v("grain")/100*0.15
        for y in 0..<height {for x in 0..<width {
            let p=(y*width+x)*4,a=pixels[p+3];guard a>0 else{continue}
            var r=pixels[p]/a,g=pixels[p+1]/a,b=pixels[p+2]/a
            r *= exposure;g *= exposure;b *= exposure
            var l=0.2126*r+0.7152*g+0.0722*b
            let high=max(0,min(1,(l-0.4)/0.6)),shadow=max(0,min(1,(0.6-l)/0.6))
            let lift=v("highlights")/100*high*0.35+v("shadows")/100*shadow*0.35+v("whites")/100*high*high*0.4+v("blacks")/100*shadow*shadow*0.25
            r += lift;g += lift;b += lift
            r=(r-0.5)*contrast+0.5+brightness;g=(g-0.5)*contrast+0.5+brightness;b=(b-0.5)*contrast+0.5+brightness
            r=pow(max(0,r),gamma);g=pow(max(0,g),gamma);b=pow(max(0,b),gamma)
            r += temperature+tint*0.5;g -= tint;b -= temperature-tint*0.5
            l=0.2126*r+0.7152*g+0.0722*b
            let spread=max(r,max(g,b))-min(r,min(g,b)),vibrance=1+v("vibrance")/100*(1-min(1,spread))
            let sat=max(0,saturation*vibrance)
            r=l+(r-l)*sat;g=l+(g-l)*sat;b=l+(b-l)*sat
            if hue {
                let i=0.596*r-0.274*g-0.322*b,q=0.211*r-0.523*g+0.312*b
                let ii=i*cosine-q*sine,qq=i*sine+q*cosine
                r=l+0.956*ii+0.621*qq;g=l-0.272*ii-0.647*qq;b=l-1.106*ii+1.703*qq
            }
            let haze=1+v("dehaze")/250,fade=v("fade")/100*0.3
            r=((r-0.5)*haze+0.5)*(1-fade)+fade*0.5;g=((g-0.5)*haze+0.5)*(1-fade)+fade*0.5;b=((b-0.5)*haze+0.5)*(1-fade)+fade*0.5
            if vignette != 0 {let xx=(Float(x)+0.5)/Float(width)*2-1,yy=(Float(y)+0.5)/Float(height)*2-1,distance=min(1,(xx*xx+yy*yy)/1.5),factor=1-vignette*distance*0.85;r *= factor;g *= factor;b *= factor}
            if grain>0 {let hash=UInt32(truncatingIfNeeded:(x &* 73856093) ^ (y &* 19349663));let noise=(Float(hash % 1024)/1023-0.5)*grain;r += noise;g += noise;b += noise}
            pixels[p]=max(0,min(1,r))*a;pixels[p+1]=max(0,min(1,g))*a;pixels[p+2]=max(0,min(1,b))*a
        }}
        for (key,radius) in [("clarity",8),("texture",2),("sharpness",1)] where v(key) != 0 {
            let blurred=boxBlur(pixels,width:width,height:height,radius:radius),strength=v(key)/100
            for p in stride(from:0,to:pixels.count,by:4){for c in 0..<3{pixels[p+c]=max(0,min(pixels[p+3],pixels[p+c]+(pixels[p+c]-blurred[p+c])*strength))}}
        }
        if v("noise")>0 {
            let blurred=boxBlur(pixels,width:width,height:height,radius:1),strength=v("noise")/100*0.9
            for p in stride(from:0,to:pixels.count,by:4) {for c in 0..<3 {let delta=blurred[p+c]-pixels[p+c];if abs(delta)<0.18{pixels[p+c] += delta*strength}}}
        }
        if v("blur")>0 {
            let radius=max(1,Int(v("blur")/100*Float(max(width,height))/100))
            for _ in 0..<3{pixels=boxBlur(pixels,width:width,height:height,radius:radius)}
        }
        return try image(pixels,width:width,height:height)
    }
}
