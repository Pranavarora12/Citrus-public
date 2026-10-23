import AppKit
import SwiftUI
import AVFoundation

struct AudioTrimSource {
    let duration:Double
    let peaks:[Double]
    let audible:VideoTimeRange?
    let audibleWindows:[VideoTimeRange]
    let playback:URL
    let temporary:URL
    func audibleBounds(in range:VideoTimeRange)->VideoTimeRange? {
        let matches=audibleWindows.filter{$0.end>range.start && $0.start<range.end}
        guard let first=matches.first,let last=matches.last else{return nil}
        let result=VideoTimeRange(start:max(range.start,first.start),end:min(range.end,last.end))
        return result.duration>=0.001 ? result:nil
    }
}
enum AudioTrim {
    static let extensions:Set<String>=["mp3","m4a","wav","wave","flac","ogg","oga","opus","aiff","aif","aifc","wma","aac"]
    static func duration(_ input:URL)throws->Double {
        let data=try VideoTools.process("/opt/homebrew/bin/ffprobe",["-v","error","-select_streams","a:0","-show_entries","stream=codec_type:format=duration","-of","json",input.path])
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],let streams=value["streams"] as? [[String:Any]],!streams.isEmpty,let format=value["format"] as? [String:Any],let duration=Double(format["duration"] as? String ?? ""),duration.isFinite,duration>0 else{throw UIError.message("This file has no readable audio track or duration.")};return duration
    }
    static func load(_ input:URL,control:VideoJobControl)throws->AudioTrimSource {
        let duration=try duration(input)
        let data=try VideoTools.process("/opt/homebrew/bin/ffmpeg",["-hide_banner","-loglevel","error","-nostdin","-i",input.path,"-map","0:a:0","-vn","-ac","1","-ar","8000","-c:a","pcm_f32le","-f","f32le","pipe:1"],control:control)
        let count=data.count/4
        guard count>0 else{throw UIError.message("This audio file contains no samples.")}
        var peaks=[Double](repeating:0,count:144),first:Int?,last:Int?,runStart:Int?
        var windows:[VideoTimeRange]=[]
        data.withUnsafeBytes{bytes in for index in 0..<count {
            let sample=abs(Float(bitPattern:UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:index*4,as:UInt32.self))))
            guard sample.isFinite else{continue};let bucket=min(peaks.count-1,index*peaks.count/count);peaks[bucket]=max(peaks[bucket],Double(sample))
            if sample>=0.01{
                if first==nil{first=index}
                if let last,let start=runStart,index-last>800{windows.append(.init(start:max(0,Double(start)/8000-0.01),end:min(duration,Double(last+1)/8000+0.01)));runStart=index}
                if runStart==nil{runStart=index};last=index
            }
        }}
        if let start=runStart,let last{windows.append(.init(start:max(0,Double(start)/8000-0.01),end:min(duration,Double(last+1)/8000+0.01)))}
        let maximum=max(0.001,peaks.max() ?? 1);peaks=peaks.map{min(1,$0/maximum)}
        // Keep 10 ms around audible samples to avoid clipping attacks and tails.
        let audible:VideoTimeRange?
        if let first,let last{audible = .init(start:max(0,Double(first)/8000-0.01),end:min(duration,Double(last+1)/8000+0.01))}else{audible=nil}
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("citrus-audio-\(UUID())",isDirectory:true),playback=temporary.appendingPathComponent("Preview.m4a")
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        do{try VideoTools.ffmpeg(["-i",input.path,"-map","0:a:0","-vn","-c:a","aac","-b:a","192k",playback.path],control:control);return .init(duration:duration,peaks:peaks,audible:audible,audibleWindows:windows,playback:playback,temporary:temporary)}catch{try? FileManager.default.removeItem(at:temporary);throw error}
    }
    static func export(_ input:URL,directory:URL,range:VideoTimeRange,control:VideoJobControl?=nil)throws->URL {
        try VideoTools.validate(range,duration:duration(input))
        return try VideoTools.write(VideoTools.output(input,directory,"Trimmed",ext:"wav"),args:["-i",input.path,"-ss",VideoTools.decimal(range.start),"-t",VideoTools.decimal(range.duration),"-map","0:a:0","-vn","-c:a","pcm_s16le"],control:control)
    }
}

@MainActor final class AudioTrimState:ObservableObject {
    let url:URL
    @Published var source:AudioTrimSource?
    @Published var range=VideoTimeRange(start:0,end:1)
    @Published var time=0.0
    @Published var automatic=false
    @Published var playing=false
    @Published var loading=true
    @Published var busy=false
    @Published var message=""
    private var manual:VideoTimeRange?
    private var player:AVAudioPlayer?
    private var timer:Timer?
    private var control=VideoJobControl()
    private var stopped=false
    var duration:Double{source?.duration ?? 1}
    var canSave:Bool{source != nil && (!automatic || source?.audibleBounds(in:range) != nil)}
    init(url:URL){self.url=url;let control=control
        DispatchQueue.global(qos:.userInitiated).async{let result=Result{try AudioTrim.load(url,control:control)};DispatchQueue.main.async{[weak self] in
            guard let self,!self.stopped else{if case .success(let source)=result{try? FileManager.default.removeItem(at:source.temporary)};return};self.loading=false
            switch result{case .success(let source):self.source=source;self.range = .init(start:0,end:source.duration)
                do{self.player=try AVAudioPlayer(contentsOf:source.playback);self.player?.prepareToPlay()}catch{self.message="Playback unavailable: \(error.localizedDescription)"}
            case .failure(let error):self.message=error.localizedDescription}
        }}
    }
    func pause(){player?.pause();playing=false;timer?.invalidate();timer=nil}
    func changeRange(_ value:VideoTimeRange,seek:Double){pause();range=automatic ? (source?.audibleBounds(in:value) ?? value):value;time=min(range.end,max(range.start,seek));player?.currentTime=time}
    func setAutomatic(_ enabled:Bool){pause();automatic=enabled;message=""
        if enabled{manual=range;guard let audible=source?.audibleBounds(in:range) else{message="No sound above −40 dB was found. Choose a range manually.";return};let start=max(range.start,audible.start),end=min(range.end,audible.end)
            guard end-start>=0.001 else{message="The selected range contains only silence.";return};range = .init(start:start,end:end)
        }else if let manual{range=manual;self.manual=nil}
        time=range.start;player?.currentTime=time
    }
    func togglePlayback(){if playing{pause();return};guard let player else{return};player.currentTime=range.start;time=range.start;playing=player.play()
        guard playing else{message="Could not start audio playback.";return}
        let timer=Timer(timeInterval:0.025,repeats:true){[weak self] _ in DispatchQueue.main.async{guard let self,let player=self.player else{return};self.time=player.currentTime;if !player.isPlaying || self.time>=self.range.end{self.pause();player.currentTime=self.range.start;self.time=self.range.start}}};self.timer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func save(destination:URL,onSave:@escaping(URL)->Void){guard canSave,!busy else{return};pause();busy=true;message="";control=VideoJobControl();let control=control,url=url,range=automatic ? (source?.audibleBounds(in:range) ?? range):range
        DispatchQueue.global(qos:.userInitiated).async{let result=Result{try AudioTrim.export(url,directory:destination,range:range,control:control)};DispatchQueue.main.async{[weak self] in guard let self,!self.stopped else{return};self.busy=false;switch result{case .success(let output):self.stop();onSave(output);case .failure(let error):self.message=error.localizedDescription}}}
    }
    func stop(){stopped=true;pause();player?.stop();player=nil;control.cancel();if let source{try? FileManager.default.removeItem(at:source.temporary)}}
}

func audioTime(_ value:Double)->String {String(format:"%d:%05.2f",Int(max(0,value))/60,max(0,value).truncatingRemainder(dividingBy:60))}
struct AudioTrimPanel:View {
    @StateObject var state:AudioTrimState
    let destination:URL
    let onSave:(URL)->Void
    let onClose:()->Void
    init(url:URL,destination:URL,onSave:@escaping(URL)->Void,onClose:@escaping()->Void){_state=StateObject(wrappedValue:AudioTrimState(url:url));self.destination=destination;self.onSave=onSave;self.onClose=onClose}
    var body:some View {VStack(spacing:0){
        PDFToolHeader(title:"Trim Audio",onClose:{state.stop();onClose()})
        ScrollView{VStack(alignment:.leading,spacing:14){
            HStack{Text("Drag the ends to trim");Spacer();Text("\(audioTime(state.range.duration)) selected").monospacedDigit()}.font(.system(size:11,weight:.medium)).foregroundColor(.white.opacity(0.7))
            ZStack{AudioWaveformRange(peaks:state.source?.peaks ?? [],range:state.range,duration:state.duration,time:state.time){range,time in state.changeRange(range,seek:time)};if state.loading{ProgressView()}}.frame(height:96)
            HStack{Text("Start \(audioTime(state.range.start))");Spacer();Text("End \(audioTime(state.range.end))")}.font(.system(size:11,weight:.medium,design:.monospaced)).foregroundColor(.white.opacity(0.7))
            Toggle("Trim silent ends automatically",isOn:Binding(get:{state.automatic},set:{state.setAutomatic($0)})).toggleStyle(.checkbox).font(.system(size:12,weight:.medium)).padding(.top,4)
            HStack{Spacer();Button{state.togglePlayback()}label:{Label(state.playing ? "Stop Playback":"Play Selected Range",systemImage:state.playing ? "stop.fill":"play.fill").font(.system(size:12,weight:.medium))}.buttonStyle(PDFQuietButtonStyle()).disabled(state.source==nil)}
        }.padding(12)}.disabled(state.loading || state.busy)
        ImagePanelFooter(message:state.message,busy:state.busy,title:"Apply",disabled:!state.canSave,onSave:{state.save(destination:destination,onSave:onSave)})
    }.foregroundColor(.white.opacity(0.94)).tint(pdfToolOrange).preferredColorScheme(.dark).onExitCommand{state.stop();onClose()}}
}

struct AudioWaveformRange:View {
    let peaks:[Double]
    let range:VideoTimeRange
    let duration:Double
    let time:Double
    let onChange:(VideoTimeRange,Double)->Void
    @State private var initial:VideoTimeRange?
    var body:some View {GeometryReader{g in
        let inset:CGFloat=15,w=max(1,g.size.width-inset*2),s=inset+range.start/duration*w,e=inset+range.end/duration*w
        ZStack(alignment:.leading){
            RoundedRectangle(cornerRadius:8).fill(.black.opacity(0.13))
            Canvas{context,size in
                let step=w/CGFloat(max(1,peaks.count))
                for (index,peak) in peaks.enumerated(){let x=inset+(CGFloat(index)+0.5)*step,height=max(2,peak*(size.height-16));var path=Path();path.move(to:CGPoint(x:x,y:(size.height-height)/2));path.addLine(to:CGPoint(x:x,y:(size.height+height)/2));context.stroke(path,with:.color(pdfToolOrange.opacity(x>=s && x<=e ? 1:0.25)),style:StrokeStyle(lineWidth:max(1,min(2,step*0.45)),lineCap:.round))}
            }.allowsHitTesting(false)
            Rectangle().fill(.white.opacity(0.12)).frame(width:max(0,e-s)).offset(x:s).allowsHitTesting(false)
            RoundedRectangle(cornerRadius:2).stroke(pdfToolOrange,lineWidth:2).frame(width:max(2,e-s)).offset(x:s).allowsHitTesting(false)
            Rectangle().fill(.white.opacity(0.8)).frame(width:1).offset(x:inset+time/duration*w).allowsHitTesting(false)
            thumb(x:s-15,width:w,start:true);thumb(x:e,width:w,start:false)
        }.clipShape(RoundedRectangle(cornerRadius:8))
    }}
    private func thumb(x:CGFloat,width:CGFloat,start:Bool)->some View {
        Rectangle().fill(pdfToolOrange).frame(width:15).overlay(Rectangle().fill(.white).frame(width:2,height:22)).offset(x:x)
            .gesture(DragGesture(minimumDistance:0).onChanged{e in
                if initial==nil{initial=range};guard let initial else{return};let minimum=min(0.01,duration/2);var next=initial
                if start{next.start=max(0,min(initial.end-minimum,initial.start+e.translation.width/width*duration))}else{next.end=min(duration,max(initial.start+minimum,initial.end+e.translation.width/width*duration))};onChange(next,start ? next.start:next.end)
            }.onEnded{_ in initial=nil})
            .accessibilityElement().accessibilityLabel(start ? "Trim start":"Trim end").accessibilityValue(audioTime(start ? range.start:range.end)).accessibilityAdjustableAction{direction in let delta=direction == .increment ? 0.1 : -0.1;var next=range;let minimum=min(0.01,duration/2);if start{next.start=max(0,min(next.end-minimum,next.start+delta))}else{next.end=min(duration,max(next.start+minimum,next.end+delta))};onChange(next,start ? next.start:next.end)}
    }
}
