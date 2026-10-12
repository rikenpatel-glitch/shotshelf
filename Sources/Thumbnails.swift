import SwiftUI
import ImageIO

/// Decodes downscaled thumbnails with ImageIO off the main thread and keeps them in memory.
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()

    private let cache = NSCache<NSString, CGImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 6
        q.qualityOfService = .userInitiated
        return q
    }()

    init() { cache.totalCostLimit = 400 * 1024 * 1024 }

    private func key(_ url: URL, _ size: Int) -> NSString { "\(size)|\(url.path)" as NSString }

    func cached(_ url: URL, size: Int) -> CGImage? { cache.object(forKey: key(url, size)) }

    func image(_ url: URL, size: Int) async -> CGImage? {
        if let hit = cached(url, size: size) { return hit }
        return await withCheckedContinuation { cont in
            queue.addOperation {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: size,
                ]
                var image: CGImage?
                if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
                    image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                }
                if let image { self.cache.setObject(image, forKey: self.key(url, size), cost: image.bytesPerRow * image.height) }
                cont.resume(returning: image)
            }
        }
    }
}

struct Thumbnail: View {
    let url: URL
    var size = 520
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle().fill(.quaternary.opacity(0.6))
            }
        }
        .task(id: url) {
            if let hit = ThumbnailStore.shared.cached(url, size: size) { image = hit; return }
            image = nil
            let loaded = await ThumbnailStore.shared.image(url, size: size)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { image = loaded }
        }
    }
}
