import Foundation
import CoreServices

/// Watches a folder tree with FSEvents and reports changed paths on the main queue.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: ([String]) -> Void

    init(path: String, onChange: @escaping ([String]) -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            watcher.onChange(changed)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

/// Calls a block once after a burst of triggers settles.
final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval

    init(_ delay: TimeInterval) { self.delay = delay }

    func call(_ block: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: block)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
