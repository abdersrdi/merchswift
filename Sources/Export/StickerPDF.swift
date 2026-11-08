import CPDFio
import CutLine
import Foundation

/// 8-bit RGBA pixels, not premultiplied, row 0 at the top.
public struct RGBAImage {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "pixel buffer does not match the dimensions")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var alpha: AlphaImage { AlphaImage(width: width, height: height, rgba: pixels) }
}

public struct StickerPDFOptions {
    public var title: String
    public var creator: String
    /// Resolution of the artwork, used to size the page.
    public var dpi: Double
    /// Cut line stroke width in points (a hairline).
    public var cutLineWidth: Double
    public var outputCondition: String

    public init(title: String = "MerchSwift sticker", creator: String = "MerchSwift", dpi: Double = 300,
                cutLineWidth: Double = 0.25, outputCondition: String = "sRGB IEC61966-2.1") {
        self.title = title
        self.creator = creator
        self.dpi = dpi
        self.cutLineWidth = cutLineWidth
        self.outputCondition = outputCondition
    }
}

public enum StickerPDFError: Error, CustomStringConvertible {
    case pdfio(String)

    public var description: String {
        switch self {
        case .pdfio(let message): return "PDF writer: \(message)"
        }
    }
}

public struct PDFInfo: Equatable {
    public var version: String
    public var pageCount: Int
}

private final class ErrorBox {
    var messages: [String] = []
}

public enum StickerPDF {
    public static var pdfioVersion: String { "PDFio " + PDFIO_VERSION }

    /// Writes a one-page PDF with the artwork and the cut line as a vector path in the spot colour `CutContour`.
    ///
    /// The file carries what PDF/X-4 needs structurally: PDF 1.6, an output intent with an embedded ICC profile,
    /// XMP metadata with `pdfxid:GTS_PDFXVersion`, a TrimBox and a BleedBox. `cut` is in artwork pixels (y down).
    public static func write(artwork: RGBAImage, cut: CutPath, to url: URL,
                             options: StickerPDFOptions = StickerPDFOptions()) throws {
        let box = ErrorBox()
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        let pt = 72.0 / options.dpi
        let pageW = Double(artwork.width) * pt
        let pageH = Double(artwork.height) * pt

        var media = pdfio_rect_t(x1: 0, y1: 0, x2: pageW, y2: pageH)
        guard let pdf = pdfioFileCreate(url.path, "1.6", &media, nil, { _, message, data in
            if let data, let message {
                Unmanaged<ErrorBox>.fromOpaque(data).takeUnretainedValue().messages.append(String(cString: message))
            }
            return false
        }, ctx) else {
            throw StickerPDFError.pdfio(box.messages.last ?? "could not create \(url.lastPathComponent)")
        }
        func fail(_ what: String) -> StickerPDFError {
            pdfioFileClose(pdf)
            return .pdfio(box.messages.last ?? what)
        }

        pdfioFileSetTitle(pdf, options.title)
        pdfioFileSetCreator(pdf, options.creator)
        pdfioFileSetCreationDate(pdf, time(nil))

        // Output intent with an embedded ICC profile.
        let profile = SRGBProfile.data
        let iccObj: OpaquePointer? = profile.withUnsafeBytes { raw in
            pdfioFileCreateICCObjFromData(pdf, raw.bindMemory(to: UInt8.self).baseAddress, profile.count, 3)
        }
        guard let iccObj else { throw fail("could not embed the ICC profile") }

        guard let catalog = pdfioFileGetCatalog(pdf),
              let intent = pdfioDictCreate(pdf),
              let intents = pdfioArrayCreate(pdf) else { throw fail("could not create the catalog entries") }
        pdfioDictSetName(intent, "Type", "OutputIntent")
        pdfioDictSetName(intent, "S", "GTS_PDFX")
        pdfioDictSetString(intent, "OutputConditionIdentifier", options.outputCondition)
        pdfioDictSetString(intent, "Info", options.outputCondition)
        pdfioDictSetString(intent, "RegistryName", "http://www.color.org")
        pdfioDictSetObj(intent, "DestOutputProfile", iccObj)
        pdfioArrayAppendDict(intents, intent)
        pdfioDictSetArray(catalog, "OutputIntents", intents)

        // XMP metadata that declares PDF/X-4.
        let xmp = xmpPacket(title: options.title, creator: options.creator)
        guard let metaDict = pdfioDictCreate(pdf) else { throw fail("could not create metadata") }
        pdfioDictSetName(metaDict, "Type", "Metadata")
        pdfioDictSetName(metaDict, "Subtype", "XML")
        guard let metaObj = pdfioFileCreateObj(pdf, metaDict),
              let metaStream = pdfioObjCreateStream(metaObj, PDFIO_FILTER_NONE) else { throw fail("could not create metadata") }
        let xmpBytes = Array(xmp.utf8)
        pdfioStreamWrite(metaStream, xmpBytes, xmpBytes.count)
        pdfioStreamClose(metaStream)
        pdfioDictSetObj(catalog, "Metadata", metaObj)

        // Artwork image (RGB with a soft mask for the alpha channel).
        guard let colour = pdfioArrayCreateColorFromICCObj(pdf, iccObj) else { throw fail("could not create the colour space") }
        let image: OpaquePointer? = artwork.pixels.withUnsafeBufferPointer { buf in
            pdfioFileCreateImageObjFromData(pdf, buf.baseAddress, artwork.width, artwork.height, 3, colour, true, true)
        }
        guard let image else { throw fail("could not embed the artwork") }

        // CutContour: a Separation colour space, tint 1 = 100% magenta in the CMYK alternate.
        guard let separation = pdfioArrayCreate(pdf),
              let tint = pdfioDictCreate(pdf),
              let c0 = pdfioArrayCreate(pdf),
              let c1 = pdfioArrayCreate(pdf),
              let domain = pdfioArrayCreate(pdf) else { throw fail("could not create the CutContour colour") }
        for v in [0.0, 0, 0, 0] { pdfioArrayAppendNumber(c0, v) }
        for v in [0.0, 1, 0, 0] { pdfioArrayAppendNumber(c1, v) }
        pdfioArrayAppendNumber(domain, 0)
        pdfioArrayAppendNumber(domain, 1)
        pdfioDictSetNumber(tint, "FunctionType", 2)
        pdfioDictSetArray(tint, "Domain", domain)
        pdfioDictSetArray(tint, "C0", c0)
        pdfioDictSetArray(tint, "C1", c1)
        pdfioDictSetNumber(tint, "N", 1)
        pdfioArrayAppendName(separation, "Separation")
        pdfioArrayAppendName(separation, "CutContour")
        pdfioArrayAppendName(separation, "DeviceCMYK")
        pdfioArrayAppendDict(separation, tint)

        guard let pageDict = pdfioDictCreate(pdf) else { throw fail("could not create the page") }
        pdfioPageDictAddImage(pageDict, "Art", image)
        pdfioPageDictAddColorSpace(pageDict, "CutContour", separation)
        var bleed = media
        pdfioDictSetRect(pageDict, "BleedBox", &bleed)
        var trim = media
        if let b = cut.bounds {
            trim = pdfio_rect_t(x1: max(0, b.min.x * pt), y1: max(0, pageH - b.max.y * pt),
                                x2: min(pageW, b.max.x * pt), y2: min(pageH, pageH - b.min.y * pt))
        }
        pdfioDictSetRect(pageDict, "TrimBox", &trim)

        guard let page = pdfioFileCreatePage(pdf, pageDict) else { throw fail("could not create the page") }
        pdfioContentDrawImage(page, "Art", 0, 0, pageW, pageH)

        pdfioContentSave(page)
        pdfioContentSetStrokeColorSpace(page, "CutContour")
        pdfioStreamPuts(page, "1 SCN\n")
        pdfioContentSetLineWidth(page, options.cutLineWidth)
        func map(_ p: Point) -> (Double, Double) { (p.x * pt, pageH - p.y * pt) }
        for contour in cut.contours {
            guard let first = contour.segments.first else { continue }
            let s = map(first.p0)
            pdfioContentPathMoveTo(page, s.0, s.1)
            for seg in contour.segments {
                let a = map(seg.p1), b = map(seg.p2), c = map(seg.p3)
                pdfioContentPathCurve(page, a.0, a.1, b.0, b.1, c.0, c.1)
            }
            pdfioContentPathClose(page)
        }
        pdfioContentStroke(page)
        pdfioContentRestore(page)
        pdfioStreamClose(page)

        guard pdfioFileClose(pdf) else { throw StickerPDFError.pdfio(box.messages.last ?? "could not finish the file") }
        if !box.messages.isEmpty { throw StickerPDFError.pdfio(box.messages.joined(separator: "; ")) }
    }

    /// Opens a PDF again with PDFio and reports its version and page count.
    public static func inspect(_ url: URL) throws -> PDFInfo {
        let box = ErrorBox()
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        guard let pdf = pdfioFileOpen(url.path, nil, nil, { _, message, data in
            if let data, let message {
                Unmanaged<ErrorBox>.fromOpaque(data).takeUnretainedValue().messages.append(String(cString: message))
            }
            return false
        }, ctx) else {
            throw StickerPDFError.pdfio(box.messages.last ?? "could not open \(url.lastPathComponent)")
        }
        defer { pdfioFileClose(pdf) }
        let version = pdfioFileGetVersion(pdf).map { String(cString: $0) } ?? ""
        return PDFInfo(version: version, pageCount: Int(pdfioFileGetNumPages(pdf)))
    }

    private static func xmpPacket(title: String, creator: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let doc = UUID().uuidString.lowercased(), inst = UUID().uuidString.lowercased()
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:pdfxid="http://www.npes.org/pdfx/ns/id/" pdfxid:GTS_PDFXVersion="PDF/X-4"/>
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:CreatorTool="\(esc(creator))" xmp:CreateDate="\(now)" xmp:ModifyDate="\(now)" xmp:MetadataDate="\(now)"/>
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(esc(title))</rdf:li></rdf:Alt></dc:title></rdf:Description>
          <rdf:Description rdf:about="" xmlns:pdf="http://ns.adobe.com/pdf/1.3/" pdf:Producer="\(esc(creator))" pdf:Trapped="False"/>
          <rdf:Description rdf:about="" xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/" xmpMM:DocumentID="uuid:\(doc)" xmpMM:InstanceID="uuid:\(inst)" xmpMM:RenditionClass="default" xmpMM:VersionID="1"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }
}
