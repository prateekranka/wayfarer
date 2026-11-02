import ImageIO
import SwiftUI

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var images: [URL: CGImage] = [:]
    private var order: [URL] = []
    func image(url: URL) -> CGImage? {
        if let image = images[url] { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        images[url] = image; order.append(url)
        if order.count > 90 { images.removeValue(forKey: order.removeFirst()) }
        return image
    }
}

struct ThumbnailView: View {
    let url: URL?
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .task(id: url) {
            image = nil
            if let url { image = await ThumbnailCache.shared.image(url: url) }
        }
    }
}
