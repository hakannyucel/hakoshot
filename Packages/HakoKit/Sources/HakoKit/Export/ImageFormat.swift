import ImageIO
import UniformTypeIdentifiers

/// Raster export formats HakoShot writes via ImageIO (plan §1.6).
public enum ImageFormat: String, Sendable, CaseIterable, Equatable {
    case png
    case jpeg
    case heic
    case webp

    /// UTI ImageIO expects when creating a `CGImageDestination`.
    public var utTypeIdentifier: String {
        switch self {
        case .png: return UTType.png.identifier
        case .jpeg: return UTType.jpeg.identifier
        case .heic: return UTType.heic.identifier
        case .webp: return "org.webmproject.webp"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .webp: return "webp"
        }
    }

    /// Whether the running system's ImageIO can actually encode this format.
    /// PNG/JPEG/HEIC are always available on macOS; WebP write support isn't
    /// guaranteed, so it's checked at runtime via
    /// `CGImageDestinationCopyTypeIdentifiers()` rather than assumed (spiked
    /// in WP7.3: as of macOS 26, ImageIO can decode WebP but not write it).
    /// When this is `false` for `.webp`, `ImageEncoder` falls back to a
    /// `libwebp`-based encoder (`Export/WebPEncoder.swift`) — `isSupported`
    /// itself still reports `false` since that's about the ImageIO path.
    public var isSupported: Bool {
        let identifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return identifiers.contains(utTypeIdentifier)
    }

    /// Whether `ImageEncoder.encode(_:format:options:)` can actually produce
    /// this format on the current machine. Unlike `isSupported` (ImageIO's
    /// write path specifically), this is `true` for `.webp` even when
    /// ImageIO can't write it, since `ImageEncoder` then falls back to a
    /// `libwebp`-based encoder (WP7.3). UI that lists selectable export
    /// formats (e.g. a format picker) should filter on this, not
    /// `isSupported` — otherwise WebP silently disappears from the list on
    /// exactly the OS versions where the fallback exists to serve it.
    public var isEncodable: Bool {
        self == .webp ? true : isSupported
    }
}
