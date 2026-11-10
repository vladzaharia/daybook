import DaybookDesign
import DaybookKit
import Foundation
import ImageIO
import SwiftUI

/// Downscaled, upright copies of photo originals, made off the main actor and kept while memory allows. A tile scrolled
/// away cancels its decode before it starts (`detachedWork` passes the cancellation on), so a fast scroll through many
/// large photos decodes only the ones that stay on screen.
public final class PhotoImageCache: @unchecked Sendable {
    public static let shared = PhotoImageCache()
    private let cache = NSCache<NSString, Box>()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    public init() {}

    public func cached(_ url: URL, maxPixels: Int) -> CGImage? { cache.object(forKey: key(url, maxPixels))?.image }

    /// The image at `maxPixels` on its longer side, decoded off the caller's actor; nil when the file isn't a readable
    /// image, or when the caller was cancelled before the decode began.
    public func image(_ url: URL, maxPixels: Int) async -> CGImage? {
        if let hit = cached(url, maxPixels: maxPixels) { return hit }
        let made = await detachedWork(priority: .userInitiated) { () -> CGImage? in
            // Cancelled while it waited to run: the tile is gone, so the decode isn't worth making.
            guard !Task.isCancelled else { return nil }
            return PhotoImage.thumbnail(url, maxPixels: maxPixels)
        }
        if let made { cache.setObject(Box(made), forKey: key(url, maxPixels)) }
        return made
    }

    private func key(_ url: URL, _ maxPixels: Int) -> NSString { "\(url.path)#\(maxPixels)" as NSString }
}

/// One photo, filled or fitted into the frame its caller gives it. A quiet fill stands in while it loads; when the
/// original can't be had (offline, missing), Try Again: its words where they fit with room either side, and in a small
/// tile (under about 120 pt) its glyph alone, which VoiceOver still reads as Try Again.
public struct PhotoImage: View {
    private let photo: MeetingPhoto
    private let meetingID: UUID
    private let maxPixels: Int
    private let contentMode: ContentMode
    private let services: PhotoServices?
    @Environment(\.photoServices) private var environmentServices
    @State private var image: CGImage?
    @State private var failure: String?
    @State private var attempt = 0

    public init(photo: MeetingPhoto, meetingID: UUID, maxPixels: Int = 480, contentMode: ContentMode = .fill,
                services: PhotoServices? = nil) {
        self.photo = photo
        self.meetingID = meetingID
        self.maxPixels = maxPixels
        self.contentMode = contentMode
        self.services = services
    }

    public var body: some View {
        // The frame comes from the caller; the image fills or fits it and never sizes it.
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
                } else {
                    Rectangle().fill(DaybookPalette.quietFill)
                        .overlay {
                            if let failure {
                                Button { attempt += 1 } label: {
                                    // Never "Try / Again" wrapped in a transcript's small tile.
                                    ViewThatFits(in: .horizontal) {
                                        Label("Try Again", systemImage: "arrow.clockwise")
                                            .fixedSize()
                                            .padding(.horizontal, DaybookSpacing.s4)
                                        Label("Try Again", systemImage: "arrow.clockwise")
                                            .labelStyle(.iconOnly)
                                            .daybookHitTarget()
                                    }
                                }
                                .buttonStyle(.daybookLink)
                                .font(DaybookFont.status.font(.platformDefault))
                                .accessibilityLabel("Try Again")
                                .accessibilityHint(failure)
                            } else {
                                Image(systemName: "photo").foregroundStyle(DaybookPalette.Ink.faint).accessibilityHidden(true)
                            }
                        }
                }
            }
            .clipped()
            .task(id: "\(meetingID):\(photo.id):\(photo.sha256):\(maxPixels):\(attempt)") { await load() }
    }

    private func load() async {
        failure = nil
        guard let services = services ?? environmentServices else { return }
        do {
            let url = try await services.original(photo, meetingID)
            if let hit = PhotoImageCache.shared.cached(url, maxPixels: maxPixels) { image = hit; return }
            image = nil
            let loaded = await PhotoImageCache.shared.image(url, maxPixels: maxPixels)
            guard !Task.isCancelled else { return }
            if let loaded { image = loaded } else { failure = "The photo couldn’t be read." }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            image = nil
            // Daybook's own errors say what to do (offline, missing); anything else in plain words.
            failure = (error as? LocalizedError)?.errorDescription ?? "The photo couldn’t be loaded."
        }
    }

    /// An upright thumbnail at most `maxPixels` on its longer side, read without keeping the original in memory.
    public nonisolated static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
