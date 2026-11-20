import CoreServices
import Foundation

/// Recursive file-system watcher (FSEvents). Calls `handler` on the main queue with changed paths.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(path: String, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            me.handler(list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
