import Testing
@testable import StreamCore

/// G01 (issue #81): pins the image-asset format rules — supported
/// PNG/JPEG/HEIF/TIFF + PDF, explicit rejections for animated (G09-owned) and
/// non-natively-renderable formats, and the decode gate.
@Suite("ImageAssetValidator")
struct ImageAssetValidatorTests {

    // MARK: - Supported formats

    @Test("PNG/JPEG/HEIF/TIFF/PDF type identifiers are supported")
    func supportedTypeIdentifiers() {
        for identifier in ["public.png", "public.jpeg", "public.heic",
                           "public.heif", "public.tiff", "com.adobe.pdf"] {
            #expect(ImageAssetValidator.isSupported(typeIdentifier: identifier))
        }
    }

    @Test("Unsupported type identifiers are rejected")
    func unsupportedTypeIdentifiers() {
        for identifier in ["com.compuserve.gif", "public.svg-image",
                           "org.webmproject.webp", "public.mp4",
                           "com.microsoft.bmp", "public.data"] {
            #expect(!ImageAssetValidator.isSupported(typeIdentifier: identifier))
        }
    }

    @Test("Extensions pre-filter matches the type identifier set")
    func supportedExtensions() {
        for ext in ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "pdf"] {
            #expect(ImageAssetValidator.isSupportedExtension(ext))
            #expect(ImageAssetValidator.isSupportedExtension(ext.uppercased()))
        }
        for ext in ["gif", "svg", "webp", "bmp", "mp4", ""] {
            #expect(!ImageAssetValidator.isSupportedExtension(ext))
        }
    }

    // MARK: - Flavor classification

    @Test("Raster formats classify as raster, PDF as vector")
    func flavorClassification() {
        #expect(ImageAssetValidator.flavor(forTypeIdentifier: "public.png") == .raster)
        #expect(ImageAssetValidator.flavor(forTypeIdentifier: "public.jpeg") == .raster)
        #expect(ImageAssetValidator.flavor(forTypeIdentifier: "public.heic") == .raster)
        #expect(ImageAssetValidator.flavor(forTypeIdentifier: "public.tiff") == .raster)
        #expect(ImageAssetValidator.flavor(forTypeIdentifier: "com.adobe.pdf") == .vector)
        #expect(ImageAssetValidator.flavor(forTypeIdentifier: "public.mp4") == nil)
    }

    // MARK: - Validation gate

    @Test("A supported type with image content validates")
    func validateSupported() {
        for identifier in ImageAssetValidator.supportedTypeIdentifiers {
            let result = ImageAssetValidator.validate(typeIdentifier: identifier, imageCount: 1)
            guard case .success = result else {
                Issue.record("expected \(identifier) to validate")
                continue
            }
        }
        // A multi-page PDF / multi-image TIFF is fine too.
        guard case .success(let flavor) =
                ImageAssetValidator.validate(typeIdentifier: "com.adobe.pdf", imageCount: 4) else {
            Issue.record("expected a multi-page PDF to validate")
            return
        }
        #expect(flavor == .vector)
    }

    @Test("A supported type with no decodable image is rejected")
    func validateUndecodable() {
        let result = ImageAssetValidator.validate(typeIdentifier: "public.png", imageCount: 0)
        guard case .failure(let error) = result else {
            Issue.record("expected a zero-image PNG to be rejected")
            return
        }
        #expect(error.message.contains("could not be decoded"))
    }

    @Test("An unidentifiable type is rejected with a format hint")
    func validateUnknownType() {
        let result = ImageAssetValidator.validate(typeIdentifier: nil, imageCount: 1)
        guard case .failure(let error) = result else {
            Issue.record("expected a nil type identifier to be rejected")
            return
        }
        #expect(error.message.contains("PNG, JPEG, HEIF, TIFF, or PDF"))
    }

    @Test("GIF is redirected to the animated-overlay path")
    func validateGIFRedirect() {
        let result = ImageAssetValidator.validate(typeIdentifier: "com.compuserve.gif", imageCount: 12)
        guard case .failure(let error) = result else {
            Issue.record("expected GIF to be rejected from the image-layer path")
            return
        }
        #expect(error.message.contains("animated overlay"))
    }

    @Test("SVG is rejected as not natively renderable")
    func validateSVGRejected() {
        let result = ImageAssetValidator.validate(typeIdentifier: "public.svg-image", imageCount: 1)
        guard case .failure(let error) = result else {
            Issue.record("expected SVG to be rejected")
            return
        }
        #expect(error.message.contains("SVG"))
    }

    @Test("A static single-frame image is valid (the ≥2-frame rule is G09's)")
    func validateStaticImage() {
        let result = ImageAssetValidator.validate(typeIdentifier: "public.png", imageCount: 1)
        #expect((try? result.get()) == .raster)
    }
}
