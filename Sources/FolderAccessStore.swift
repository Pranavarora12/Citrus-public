import AppKit
import Foundation

final class FolderAccessStore:ObservableObject {
    struct Entry:Codable,Identifiable {
        let path:String
        let bookmark:Data
        var id:String {path}
    }
    @Published private(set) var entries:[Entry]
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard){
        self.defaults=defaults
        entries=(defaults.data(forKey:"allowedFolderBookmarks").flatMap{try? JSONDecoder().decode([Entry].self,from:$0)}) ?? []
    }
    func add(_ url:URL)throws {
        let path=url.standardizedFileURL.path
        let bookmark=try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
        entries.removeAll{$0.path==path};entries.append(Entry(path:path,bookmark:bookmark));save()
    }
    func remove(_ entry:Entry){entries.removeAll{$0.id==entry.id};save()}
    private func save(){if let data=try? JSONEncoder().encode(entries){defaults.set(data,forKey:"allowedFolderBookmarks")}}
    static func withAccess<T>(_ entries:[Entry],for files:[URL],_ work:()throws->T)rethrows->T {
        let access=Lease(entries:entries,files:files)
        defer{access.close()}
        return try work()
    }
    /// Keep both the dropped file's grant and any saved folder grants alive
    /// across asynchronous editor loading and saving, not just a single job.
    final class Lease {
        private var opened:[URL]=[]
        private let lock=NSLock()
        init(entries:[Entry],files:[URL]) {
            for file in files where file.startAccessingSecurityScopedResource(){opened.append(file)}
            for entry in entries where files.contains(where:{$0.path==entry.path || $0.path.hasPrefix(entry.path+"/")}) {
                var stale=false
                if let url=try? URL(resolvingBookmarkData:entry.bookmark,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale),url.startAccessingSecurityScopedResource(){opened.append(url)}
            }
        }
        func close(){
            lock.lock();let resources=opened;opened=[];lock.unlock()
            resources.forEach{$0.stopAccessingSecurityScopedResource()}
        }
        deinit{close()}
    }
}
