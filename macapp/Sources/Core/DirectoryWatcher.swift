import CoreServices
import Foundation

/// FSEvents on a directory tree, calling `onChange` on the main queue for changes
/// that can alter the library listing.
///
/// A recording grows its .wav many times a second while it runs; reacting to that
/// would run `show --list` the whole meeting long. So a media file only counts when
/// it is removed or renamed; every other file counts on any change, and folders
/// always count.
final class DirectoryWatcher {
    let url: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    private static let mediaExtensions: Set<String> = [
        "wav", "mp3", "m4a", "flac", "ogg", "webm", "mp4", "m4v", "mov", "mkv", "part",
    ]

    init?(url: URL, latency: CFTimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
            let relevant = (0..<count).contains { DirectoryWatcher.isRelevant(path: names[$0], flags: flags[$0]) }
            if relevant { watcher.onChange() }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private static func isRelevant(path: String, flags: FSEventStreamEventFlags) -> Bool {
        let has = { (flag: Int) in flags & FSEventStreamEventFlags(flag) != 0 }
        if has(kFSEventStreamEventFlagItemIsDir) || has(kFSEventStreamEventFlagRootChanged)
            || has(kFSEventStreamEventFlagMustScanSubDirs) {
            return true
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if mediaExtensions.contains(ext) {
            return has(kFSEventStreamEventFlagItemRemoved) || has(kFSEventStreamEventFlagItemRenamed)
        }
        return true
    }
}
