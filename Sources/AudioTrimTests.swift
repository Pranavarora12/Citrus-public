import Foundation
import AppKit

enum AudioTrimTests {
    @MainActor static func run(in directory:URL) async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var checks=0
        func check(_ value:Bool,_ message:String)throws{guard value else{throw UIError.message(message)};checks+=1;print("PASS \(message)")}
        let input=directory.appendingPathComponent("Audio Fixture.wav")
        if !FileManager.default.fileExists(atPath:input.path){try VideoTools.ffmpeg(["-f","lavfi","-i","sine=frequency=440:sample_rate=16000:duration=2","-af","adelay=1000:all=1,apad=pad_dur=1","-c:a","pcm_s16le",input.path])}
        let original=try Data(contentsOf:input)
        for ext in AudioTrim.extensions.sorted(){let wheel=WheelDropView(group:"Tools",inputs:[input.deletingPathExtension().appendingPathExtension(ext)],onDrop:{_,_ in},onClose:{});try check(wheel.tools.map(\.id)==["trimAudio"] && wheel.pageCount==1,"\(ext) Command wheel has only Trim")}
        let wheel=WheelDropView(group:"Tools",inputs:[input],onDrop:{_,_ in},onClose:{})
        try check(wheel.slot(at:wheel.polar(150,wheel.angle(0)))==0 && wheel.shortName(wheel.tools[0])=="TRIM","Single Trim segment is visible and accepts a drop")
        let model=AppModel();model.feedbackEnabled=false;model.options["start"]="99";model.options["duration"]="0.1";var received=false
        model.audioToolPresenter={urls,output in received=urls==[input] && output==directory};model.submitWheelDrop(Tool.all.first{$0.id=="trimAudio"}!,urls:[input],destination:directory)
        try check(received,"Audio Trim opens its editor instead of running saved options")
        let source=try AudioTrim.load(input,control:VideoJobControl());defer{try? FileManager.default.removeItem(at:source.temporary)}
        try check(abs(source.duration-4)<0.01 && source.peaks.count==144 && source.peaks.max()==1,"Waveform loads actual normalized audio peaks")
        try check(source.peaks.first==0 && (source.peaks[65]>0.8),"Waveform distinguishes silent and audible regions")
        try check(abs((source.audible?.start ?? 0)-1)<0.02 && abs((source.audible?.end ?? 0)-3)<0.02,"Automatic trim detects leading and trailing silence")
        try check(source.audibleBounds(in:.init(start:0,end:0.5))==nil,"Automatic trim rejects an entirely silent selection")
        let output=try AudioTrim.export(input,directory:directory,range:.init(start:1.25,end:2.75))
        try check(abs((try AudioTrim.duration(output))-1.5)<0.002,"Apply saves the exact selected range as playable WAV")
        let auto=try AudioTrim.export(input,directory:directory,range:source.audible!)
        try check(abs((try AudioTrim.duration(auto))-2)<0.03,"Automatic trim exports audio without silent ends")
        let state=AudioTrimState(url:input)
        for _ in 0..<200 where state.loading{try await Task.sleep(nanoseconds:50_000_000)}
        try check(state.source != nil && state.canSave,"Trim state loads without depending on view appearance")
        state.setAutomatic(true);try check(state.range.start>0.98 && state.range.end<3.02,"Checkbox updates the visible selected range")
        state.setAutomatic(false);try check(state.range == .init(start:0,end:4),"Turning automatic trim off restores the manual selection")
        state.changeRange(.init(start:0.5,end:2.5),seek:0.5);try check(state.time==0.5 && state.range.duration==2,"Dragging range updates duration and playback position")
        state.stop()
        var invalid=false;do{_ = try AudioTrim.export(input,directory:directory,range:.init(start:3,end:2))}catch{invalid=true}
        try check(invalid,"Invalid ranges fail without creating an output")
        try check(try Data(contentsOf:input)==original,"Trimming preserves the original audio file")
        print("AUDIO TRIM AUDIT PASSED: \(checks) checks")
    }
}
