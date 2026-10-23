import Foundation
import AppKit
import AVFoundation

enum VideoToolTests {
    @MainActor static func run(in directory:URL) async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var checks=0
        func check(_ pass:Bool,_ message:String)throws{guard pass else{throw UIError.message(message)};checks+=1;print("PASS \(message)")}
        let source=directory.appendingPathComponent("Video Fixture.mov"),silent=directory.appendingPathComponent("Silent.mp4")
        if !FileManager.default.fileExists(atPath:source.path){try VideoTools.ffmpeg(["-f","lavfi","-i","testsrc2=size=320x240:rate=24:duration=4","-f","lavfi","-i","sine=frequency=440:sample_rate=48000:duration=4","-c:v","libx264","-preset","ultrafast","-crf","10","-c:a","aac","-metadata","title=Private Fixture","-metadata","comment=Remove me","-metadata","creation_time=2026-10-22T10:00:00Z",source.path])}
        if !FileManager.default.fileExists(atPath:silent.path){try VideoTools.ffmpeg(["-f","lavfi","-i","color=c=blue:size=240x320:rate=24:duration=1","-c:v","libx264",silent.path])}
        let original=try Data(contentsOf:source),info=try VideoTools.info(source)
        try check(info.width==320 && info.height==240 && info.hasAudio && abs(info.duration-4)<0.08,"Read dimensions, duration, audio and metadata")
        let wheel=WheelDropView(group:"Tools",inputs:[source],onDrop:{_,_ in},onClose:{})
        try check(wheel.tools.map(\.id)==VideoTools.singleToolIDs && wheel.pageCount==1 && wheel.current.count==9,"All nine video tools appear on one wheel in the configured order")
        let multi=WheelDropView(group:"Tools",inputs:[source,silent],onDrop:{_,_ in},onClose:{})
        try check(multi.tools.last?.id=="joinVideos" && multi.pageCount==1,"Join available for multiple videos")
        let model=AppModel();model.feedbackEnabled=false;var dispatched:[String]=[];model.videoToolPresenter={id,_,_ in dispatched.append(id)}
        for id in VideoTools.singleToolIDs where id != "muteVideo"{model.submitWheelDrop(Tool.all.first{$0.id==id}!,urls:[source],destination:directory)}
        try check(dispatched==VideoTools.singleToolIDs.filter{$0 != "muteVideo"},"Wheel opens dedicated video panels, including metadata")
        let trimmed=try VideoTools.trim(source,directory:directory,range:.init(start:0.75,end:2.25)),ti=try VideoTools.info(trimmed)
        try check(abs(ti.duration-1.5)<0.09 && ti.hasAudio,"Trim exports selected range with audio")
        let cropped=try VideoTools.crop(source,directory:directory,rect:CGRect(x:20,y:10,width:180,height:220)),ci=try VideoTools.info(cropped)
        try check(ci.width==180 && ci.height==220 && ci.hasAudio,"Crop exports chosen source pixel rectangle")
        for speed in [0.25,0.5,1.5,2,4]{let result=try VideoTools.speed(source,directory:directory,multiplier:speed),si=try VideoTools.info(result);try check(abs(si.duration-info.duration/speed)<0.15 && si.hasAudio,"Speed \(speed)× changes duration and retains audio")}
        let muted=try ProcessingJob.run("muteVideo",inputs:[source],outputDirectory:directory,options:[:])[0]
        try check(!(try VideoTools.info(muted)).hasAudio,"Mute removes audio via wheel processing backend")
        let times=[0.0,1.25,3.5],frames=try VideoTools.snapshots(source,directory:directory,times:times)
        try check(frames.count==3 && frames.allSatisfy{$0.pathExtension=="png"},"Snapshot selection exports every requested PNG")
        try check(try ImageTools.load(frames[0]).width==320,"Snapshots preserve full source resolution")
        let last=try VideoTools.snapshots(source,directory:directory,times:[info.duration-0.001])
        try check(last.count==1 && (try ImageTools.load(last[0])).width==320,"Selecting the video end exports the last available frame")
        let ranges=[VideoTimeRange(start:0,end:1),VideoTimeRange(start:2,end:4)]
        let clips=try VideoTools.split(source,directory:directory,ranges:ranges,merge:false)
        try check(clips.count==2 && abs((try VideoTools.info(clips[1])).duration-2)<0.1,"Split exports kept clips and omits removed segment")
        let edited=try VideoTools.split(source,directory:directory,ranges:ranges,merge:true)[0]
        try check(abs((try VideoTools.info(edited)).duration-3)<0.1,"One Video concatenates kept split ranges")
        let layers=[VideoRedaction(rect:CGRect(x:30,y:30,width:100,height:100),range:.init(start:1,end:2)),VideoRedaction(rect:CGRect(x:170,y:90,width:100,height:100),range:.init(start:2,end:3),blur:true)]
        let redacted=try VideoTools.redact(source,directory:directory,layers:layers)
        func brightness(_ input:URL,_ t:Double,_ rect:CGRect)throws->Double{let image=try VideoTools.frame(input,time:t,maxEdge:0);let data=try ImagePixels.rgba(image.cropping(to:rect)!);return Double(data.reduce(0,+))/Double(data.count)}
        try check(try brightness(redacted,1.5,CGRect(x:45,y:45,width:60,height:60))<0.27,"Timed solid redaction covers the selected region")
        try check(try brightness(redacted,0.5,CGRect(x:45,y:45,width:60,height:60))>0.30,"Redaction disappears outside its time range")
        try check((try VideoTools.info(redacted)).hasAudio,"Multiple solid and blur redactions retain audio")
        var fields=info.tags
        if let i=fields.firstIndex(where:{$0.stream==nil && $0.key=="title"}){fields[i].value="Citrus Edited";fields[i].edited=true}
        let metadata=try VideoTools.metadata(source,directory:directory,fields:fields,removeAll:false)
        try check((try VideoTools.info(metadata)).tags.contains{$0.key=="title" && $0.value=="Citrus Edited"},"Metadata edits are written")
        let stripped=try ProcessingJob.run("removeMetadata",inputs:[source],outputDirectory:directory,options:[:])[0],tags=try VideoTools.info(stripped).tags
        try check(!tags.contains{["title","comment","creation_time","timecode"].contains($0.key)},"Video metadata removes personal tags and timecode")
        for mode in ["preset","percentage","fileSize"]{let cap=mode=="preset" ? Int(Double(info.bytes)*0.45):mode=="percentage" ? info.bytes/2:150000
            let output=try VideoTools.compress(source,directory:directory,mode:mode,preset:"strong",reduction:50,targetSize:150,unit:"KB"),bytes=try VideoTools.info(output).bytes
            try check(bytes<=cap && bytes<info.bytes,"\(mode) compression meets actual file size ceiling")}
        let joined=try VideoTools.join([silent,source],directory:directory),ji=try VideoTools.info(joined)
        try check(abs(ji.duration-5)<0.15 && ji.width==240 && ji.height==320 && ji.hasAudio,"Join normalizes dimensions and supplies silence for missing audio")
        let firstJoin=try VideoTools.frame(joined,time:0.5,maxEdge:320),blue=try ImagePixels.rgba(firstJoin)
        try check(blue[2]>blue[0],"Join preserves requested input order")
        let silentSpeed=try VideoTools.speed(silent,directory:directory,multiplier:2)
        try check(!(try VideoTools.info(silentSpeed)).hasAudio,"Speed handles video without audio")
        let silentMerge=try VideoTools.split(silent,directory:directory,ranges:[.init(start:0,end:0.4),.init(start:0.6,end:1)],merge:true)[0]
        try check(abs((try VideoTools.info(silentMerge)).duration-0.8)<0.1,"Split handles video without audio")
        let state=VideoEditorState(url:source,operation:"splitVideo")
        for _ in 0..<200 where state.loading {try await Task.sleep(nanoseconds:50_000_000)}
        try check(state.info != nil,"Editor loads preview without relying on view appearance")
        state.seek(1);state.addCut();state.seek(2);state.addCut();state.selectedClip=1;state.removeSelected()
        try check(state.kept==ranges,"Split editor removes selected segment")
        state.moveCut(state.cuts[0].id,to:1.25)
        try check(state.removed==[1] && state.cuts[0].time==1.25,"Dragging split points preserves removed clip")
        state.selectedClip=1;state.removeSelected();try check(state.removed.isEmpty,"Removed clips can be restored")
        state.setAspect("3:4");try check(abs(state.crop.width/state.crop.height-0.75)<0.001,"Crop presets use source pixel aspect ratio")
        state.addLayer(rect:CGRect(x:20,y:20,width:40,height:40));try check(state.layers[0].range.end==4,"New redaction spans full video until timeline edited")
        state.stop()
        let rotated=directory.appendingPathComponent("Rotated-display.mov")
        if !FileManager.default.fileExists(atPath:rotated.path){try VideoTools.ffmpeg(["-display_rotation","90","-i",source.path,"-c","copy",rotated.path])}
        let rotatedInfo=try VideoTools.info(rotated)
        try check(rotatedInfo.width==240 && rotatedInfo.height==320,"Rotated videos report oriented dimensions")
        let rotatedCrop=try VideoTools.crop(rotated,directory:directory,rect:CGRect(x:0,y:0,width:180,height:240))
        try check((try VideoTools.info(rotatedCrop)).width==180 && (try VideoTools.info(rotatedCrop)).height==240,"Crop uses the displayed orientation for rotated videos")
        var invalid=0
        for work in [{_ = try VideoTools.trim(source,directory:directory,range:.init(start:3,end:2))},{_ = try VideoTools.crop(source,directory:directory,rect:CGRect(x:-5,y:0,width:20,height:20))},{_ = try VideoTools.speed(source,directory:directory,multiplier:0)},{_ = try VideoTools.snapshots(source,directory:directory,times:[4])},{_ = try VideoTools.split(source,directory:directory,ranges:[],merge:false)},{_ = try VideoTools.join([source],directory:directory)}]{do{try work()}catch{invalid+=1}}
        try check(invalid==6,"Invalid ranges, crops, speeds and empty exports fail clearly")
        try check(try Data(contentsOf:source)==original,"Every operation preserves the source video")
        print("VIDEO TOOL AUDIT PASSED: \(checks) checks")
    }
}
