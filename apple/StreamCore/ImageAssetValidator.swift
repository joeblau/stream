import Foundation

/// G01 (issue #81): the pure format-validation rules behind image and logo
/// layers — the "import supported PNG/JPEG/HEIF/TIFF and native-renderable
/// vector/PDF assets with explicit format validation" gate. UTType identifier
/// strings and ImageIO image counts in, supported/unsupported out; the
/// ImageIO/AppKit probing stays in the StreamMac caller
/// (`ImageAssetClassifier`), these rules are the testable core (the
/// `MediaOverlayValidator` precedent from G09).
///
/// **Why these formats.** PNG/JPEG/HEIF/TIFF decode through ImageIO with
/// their alpha channel, embedded color space, and pixel aspect intact — the
/// renderer composites the decoded `CGImage` directly, so transparency (the
/// logo use case) is preserved end to end. PDF is the natively renderable
/// vector format: ImageIO rasterizes it at a chosen DPI, so a vector logo
/// stays crisp at any layer size. GIF/APNG/animated HEIC are deliberately
/// NOT here — they are G09 animated overlays (`MediaOverlayValidator`) and
/// import through the media-overlay path. SVG has no native ImageIO decode
/// on macOS, so it is rejected with an explicit reason rather than silently
/// rendering wrong.

/// An import-time rejection with a user-facing reason (the
/// `MediaOverlayFormatError` precedent).
public struct ImageAssetFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Which flavor of image asset a validated file is — drives decode options
/// (PDF rasterizes at an explicit DPI) and the row badge.
public enum ImageAssetFlavor: String, Equatable, Sendable {
    /// PNG/JPEG/HEIF/TIFF — pixels decode as stored.
    case raster
    /// PDF — rasterized on decode at a chosen DPI (the vector path).
    case vector

    public var displayName: String {
        switch self {
        case .raster: return "Image"
        case .vector: return "Vector (PDF)"
        }
    }
}

/// Pure classification/validation rules for image-layer assets.
public enum ImageAssetValidator {
    /// Uniform type identifiers ImageIO decodes as stored pixels, preserving
    /// alpha and embedded color space.
    public static let rasterTypeIdentifiers: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.heic",
        "public.heif",
        "public.tiff",
    ]

    /// The natively renderable vector type identifier (PDF — ImageIO
    /// rasterizes it at decode time at a caller-chosen DPI).
    public static let vectorTypeIdentifiers: Set<String> = [
        "com.adobe.pdf",
    ]

    public static let supportedTypeIdentifiers: Set<String> =
        rasterTypeIdentifiers.union(vectorTypeIdentifiers)

    /// Lowercased file extensions (no dot) the pickers and Finder drop
    /// targets advertise. Kept in sync with the type identifiers above.
    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "pdf",
    ]

    /// Is this type identifier a supported image-layer asset?
    public static func isSupported(typeIdentifier: String) -> Bool {
        supportedTypeIdentifiers.contains(typeIdentifier)
    }

    /// Extension-based pre-filter (lowercased, no dot) — the cheap gate for
    /// Finder drops before any file I/O.
    public static func isSupportedExtension(_ ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }

    /// The flavor a supported type identifier decodes as, nil when
    /// unsupported.
    public static func flavor(forTypeIdentifier identifier: String) -> ImageAssetFlavor? {
        if rasterTypeIdentifiers.contains(identifier) { return .raster }
        if vectorTypeIdentifiers.contains(identifier) { return .vector }
        return nil
    }

    /// The import gate: the probed file must be a supported type that ImageIO
    /// actually decodes (at least one image). A static single-frame image is
    /// exactly right here — the ≥2-frame rule belongs to G09's animated
    /// overlays, which is also where animated GIF/APNG files are redirected.
    public static func validate(typeIdentifier: String?,
                                imageCount: Int) -> Result<ImageAssetFlavor, ImageAssetFormatError> {
        guard let typeIdentifier else {
            return .failure(ImageAssetFormatError(
                "The file's format couldn't be identified — pick a PNG, JPEG, HEIF, TIFF, or PDF."))
        }
        guard let flavor = flavor(forTypeIdentifier: typeIdentifier) else {
            switch typeIdentifier {
            case "com.compuserve.gif":
                return .failure(ImageAssetFormatError(
                    "GIF is an animated overlay — add it through the Overlay panel's Animated Image option."))
            case "public.svg-image":
                return .failure(ImageAssetFormatError(
                    "SVG isn't natively renderable — export it as a PDF (vector) or a high-resolution PNG (alpha preserved)."))
            default:
                return .failure(ImageAssetFormatError(
                    "Unsupported image format — pick a PNG, JPEG, HEIF, TIFF, or PDF."))
            }
        }
        guard imageCount > 0 else {
            return .failure(ImageAssetFormatError(
                "The file could not be decoded (no image content)."))
        }
        return .success(flavor)
    }
}
