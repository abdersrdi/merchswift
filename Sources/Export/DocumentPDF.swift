import CPDFio
import CutLine
import DocumentModel
import Foundation

/// Supplies the pixels of placed images, as 8-bit RGBA with straight (not premultiplied) alpha.
public protocol PixelSource: AnyObject {
    func pixels(for assetID: String) -> RGBAImage?
}

public struct DocumentPDFOptions {
    public var title: String
    public var creator: String
    /// The trim edge in canvas millimetres, written as the page's TrimBox. Defaults to the whole page.
    public var trim: Rect2?
    /// The cut line in canvas millimetres (y down), drawn as the spot colour `CutContour`.
    public var cutLine: CutPath?
    /// Line width of the cut line in millimetres: a hairline.
    public var cutLineWidth: Double
    public var outputCondition: String

    public init(title: String = "MerchSwift design", creator: String = "MerchSwift", trim: Rect2? = nil, cutLine: CutPath? = nil,
                cutLineWidth: Double = 0.0882, outputCondition: String = "sRGB IEC61966-2.1") {
        self.title = title; self.creator = creator; self.trim = trim; self.cutLine = cutLine
        self.cutLineWidth = cutLineWidth; self.outputCondition = outputCondition
    }
}

private final class PDFErrorBox { var messages: [String] = [] }

/// Writes a whole design as a one-page PDF/X-4 file. Shapes and text stay vector, blends and opacity use real PDF
/// transparency, images keep their alpha, and a cut line goes in as the `CutContour` spot colour.
/// Structure: PDF 1.6, an output intent with an embedded sRGB ICC profile, XMP that declares PDF/X-4, and TrimBox
/// and BleedBox. Conformance has still to be proven with Acrobat's Preflight.
public enum DocumentPDF {
    private static let pt = 72.0 / 25.4

    public static func write(_ doc: Document, assets: PixelSource? = nil, to url: URL,
                             options: DocumentPDFOptions = DocumentPDFOptions()) throws {
        let box = PDFErrorBox()
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        let pageW = doc.size.width * pt, pageH = doc.size.height * pt
        var media = pdfio_rect_t(x1: 0, y1: 0, x2: pageW, y2: pageH)
        var crop = media
        guard let pdf = pdfioFileCreate(url.path, "1.6", &media, &crop, { _, message, data in
            if let data, let message { Unmanaged<PDFErrorBox>.fromOpaque(data).takeUnretainedValue().messages.append(String(cString: message)) }
            return false
        }, ctx) else { throw StickerPDFError.pdfio(box.messages.last ?? "could not create \(url.lastPathComponent)") }

        // PDFio keeps the pointers it is given for names and strings, so each one comes from its own pool.
        func S(_ text: String) -> UnsafePointer<CChar> { UnsafePointer(pdfioStringCreate(pdf, text)!) }
        func fail(_ what: String) -> StickerPDFError { pdfioFileClose(pdf); return .pdfio(box.messages.last ?? what) }

        pdfioFileSetTitle(pdf, S(options.title))
        pdfioFileSetCreator(pdf, S(options.creator))
        pdfioFileSetCreationDate(pdf, time(nil))

        // Output intent and metadata.
        let profile = SRGBProfile.data
        let iccObj: OpaquePointer? = profile.withUnsafeBytes { raw in
            pdfioFileCreateICCObjFromData(pdf, raw.bindMemory(to: UInt8.self).baseAddress, profile.count, 3)
        }
        guard let iccObj, let catalog = pdfioFileGetCatalog(pdf), let intent = pdfioDictCreate(pdf),
              let intents = pdfioArrayCreate(pdf) else { throw fail("could not set up the output intent") }
        pdfioDictSetName(intent, S("Type"), S("OutputIntent"))
        pdfioDictSetName(intent, S("S"), S("GTS_PDFX"))
        pdfioDictSetString(intent, S("OutputConditionIdentifier"), S(options.outputCondition))
        pdfioDictSetString(intent, S("Info"), S(options.outputCondition))
        pdfioDictSetString(intent, S("RegistryName"), S("http://www.color.org"))
        pdfioDictSetObj(intent, S("DestOutputProfile"), iccObj)
        pdfioArrayAppendDict(intents, intent)
        pdfioDictSetArray(catalog, S("OutputIntents"), intents)

        let xmp = Array(StickerPDF.xmpPacket(title: options.title, creator: options.creator).utf8)
        guard let metaDict = pdfioDictCreate(pdf) else { throw fail("could not create metadata") }
        pdfioDictSetName(metaDict, S("Type"), S("Metadata"))
        pdfioDictSetName(metaDict, S("Subtype"), S("XML"))
        guard let metaObj = pdfioFileCreateObj(pdf, metaDict), let metaStream = pdfioObjCreateStream(metaObj, PDFIO_FILTER_NONE) else { throw fail("could not create metadata") }
        pdfioStreamWrite(metaStream, xmp, xmp.count)
        pdfioStreamClose(metaStream)
        pdfioDictSetObj(catalog, S("Metadata"), metaObj)

        // Resources shared by the page and the groups.
        guard let iccColour = pdfioArrayCreateColorFromICCObj(pdf, iccObj) else { throw fail("could not create the colour space") }
        var imageObjects: [String: OpaquePointer] = [:]

        func iccSpaceArray() -> OpaquePointer? {
            guard let a = pdfioArrayCreate(pdf) else { return nil }
            pdfioArrayAppendName(a, S("ICCBased"))
            pdfioArrayAppendObj(a, iccObj)
            return a
        }

        var fetched: [String: RGBAImage?] = [:]
        func fetch(_ assetID: String) -> RGBAImage? {
            if let cached = fetched[assetID] { return cached }
            let img = assets?.pixels(for: assetID)
            fetched[assetID] = .some(img)
            return img
        }

        func imageObject(_ assetID: String) -> OpaquePointer? {
            if let o = imageObjects[assetID] { return o }
            guard let img = fetch(assetID), img.width > 0, img.height > 0 else { return nil }
            let obj: OpaquePointer? = img.pixels.withUnsafeBufferPointer { buf in
                pdfioFileCreateImageObjFromData(pdf, buf.baseAddress, img.width, img.height, 3, iccColour, true, true)
            }
            if let obj { imageObjects[assetID] = obj }
            return obj
        }

        /// The resource dictionary for one scope, with its groups written out first.
        func materialize(_ scope: PDFScope, extraColourSpaces: [(String, OpaquePointer)] = []) throws -> OpaquePointer {
            guard let res = pdfioDictCreate(pdf), let cs = pdfioDictCreate(pdf), let icc0 = iccSpaceArray() else { throw fail("could not create resources") }
            pdfioDictSetArray(cs, S("CS0"), icc0)
            for (name, array) in extraColourSpaces { pdfioDictSetArray(cs, S(name), array) }
            pdfioDictSetDict(res, S("ColorSpace"), cs)

            if !scope.images.isEmpty || !scope.forms.isEmpty {
                guard let xo = pdfioDictCreate(pdf) else { throw fail("could not create resources") }
                for (name, ref) in scope.images { if let o = imageObject(ref.assetID) { pdfioDictSetObj(xo, S(name), o) } }
                for form in scope.forms {
                    let obj = try formObject(form)
                    pdfioDictSetObj(xo, S(form.name), obj)
                }
                pdfioDictSetDict(res, S("XObject"), xo)
            }
            if !scope.states.isEmpty {
                guard let gsd = pdfioDictCreate(pdf) else { throw fail("could not create resources") }
                for (name, st) in scope.states {
                    guard let g = pdfioDictCreate(pdf) else { throw fail("could not create resources") }
                    pdfioDictSetName(g, S("Type"), S("ExtGState"))
                    pdfioDictSetNumber(g, S("ca"), st.fillAlpha)
                    pdfioDictSetNumber(g, S("CA"), st.strokeAlpha)
                    pdfioDictSetName(g, S("BM"), S(st.blendMode))
                    pdfioDictSetDict(gsd, S(name), g)
                }
                pdfioDictSetDict(res, S("ExtGState"), gsd)
            }
            return res
        }

        func formObject(_ form: PDFFormScope) throws -> OpaquePointer {
            guard let d = pdfioDictCreate(pdf), let bbox = pdfioArrayCreate(pdf), let group = pdfioDictCreate(pdf),
                  let groupSpace = iccSpaceArray() else { throw fail("could not create a group") }
            pdfioDictSetName(d, S("Type"), S("XObject"))
            pdfioDictSetName(d, S("Subtype"), S("Form"))
            // PDFio writes the dictionary before it starts the stream, so the filter has to be named up front.
            pdfioDictSetName(d, S("Filter"), S("FlateDecode"))
            for v in [form.bbox.minX, form.bbox.minY, form.bbox.maxX, form.bbox.maxY] { pdfioArrayAppendNumber(bbox, v) }
            pdfioDictSetArray(d, S("BBox"), bbox)
            pdfioDictSetName(group, S("Type"), S("Group"))
            pdfioDictSetName(group, S("S"), S("Transparency"))
            pdfioDictSetArray(group, S("CS"), groupSpace)
            pdfioDictSetDict(d, S("Group"), group)
            pdfioDictSetDict(d, S("Resources"), try materialize(form.scope))
            guard let obj = pdfioFileCreateObj(pdf, d), let st = pdfioObjCreateStream(obj, PDFIO_FILTER_FLATE) else { throw fail("could not create a group") }
            let bytes = Array(form.scope.content.utf8)
            pdfioStreamWrite(st, bytes, bytes.count)
            pdfioStreamClose(st)
            return obj
        }

        // The page.
        let page = PDFContentBuilder.build(doc, hasImage: { fetch($0) != nil })
        var extra: [(String, OpaquePointer)] = []
        var cutContent = ""
        if let cut = options.cutLine, !cut.contours.isEmpty {
            guard let sep = pdfioArrayCreate(pdf), let tint = pdfioDictCreate(pdf), let c0 = pdfioArrayCreate(pdf),
                  let c1 = pdfioArrayCreate(pdf), let domain = pdfioArrayCreate(pdf) else { throw fail("could not create the CutContour colour") }
            for v in [0.0, 0, 0, 0] { pdfioArrayAppendNumber(c0, v) }
            for v in [0.0, 1, 0, 0] { pdfioArrayAppendNumber(c1, v) }
            pdfioArrayAppendNumber(domain, 0); pdfioArrayAppendNumber(domain, 1)
            pdfioDictSetNumber(tint, S("FunctionType"), 2)
            pdfioDictSetArray(tint, S("Domain"), domain)
            pdfioDictSetArray(tint, S("C0"), c0)
            pdfioDictSetArray(tint, S("C1"), c1)
            pdfioDictSetNumber(tint, S("N"), 1)
            pdfioArrayAppendName(sep, S("Separation"))
            pdfioArrayAppendName(sep, S("CutContour"))
            pdfioArrayAppendName(sep, S("DeviceCMYK"))
            pdfioArrayAppendDict(sep, tint)
            extra.append(("CutContour", sep))

            cutContent = "q /CutContour CS 1 SCN \(PDFContentBuilder.num(options.cutLineWidth)) w 1 j\n"
            for contour in cut.contours {
                guard let first = contour.segments.first else { continue }
                cutContent += "\(PDFContentBuilder.num(first.p0.x)) \(PDFContentBuilder.num(first.p0.y)) m\n"
                for s in contour.segments {
                    cutContent += "\(PDFContentBuilder.num(s.p1.x)) \(PDFContentBuilder.num(s.p1.y)) \(PDFContentBuilder.num(s.p2.x)) \(PDFContentBuilder.num(s.p2.y)) \(PDFContentBuilder.num(s.p3.x)) \(PDFContentBuilder.num(s.p3.y)) c\n"
                }
                cutContent += "h\n"
            }
            cutContent += "S Q\n"
        }

        guard let pageDict = pdfioDictCreate(pdf) else { throw fail("could not create the page") }
        pdfioDictSetDict(pageDict, S("Resources"), try materialize(page, extraColourSpaces: extra))
        var bleed = media
        pdfioDictSetRect(pageDict, S("BleedBox"), &bleed)
        let t = options.trim ?? Rect2(x: 0, y: 0, width: doc.size.width, height: doc.size.height)
        var trim = pdfio_rect_t(x1: max(0, t.minX * pt), y1: max(0, pageH - t.maxY * pt), x2: min(pageW, t.maxX * pt), y2: min(pageH, pageH - t.minY * pt))
        pdfioDictSetRect(pageDict, S("TrimBox"), &trim)

        guard let stream = pdfioFileCreatePage(pdf, pageDict) else { throw fail("could not create the page") }
        // Millimetres, y down, to points, y up.
        let header = "\(PDFContentBuilder.num(pt)) 0 0 \(PDFContentBuilder.num(-pt)) 0 \(PDFContentBuilder.num(pageH)) cm\n"
        let bytes = Array((header + page.content + cutContent).utf8)
        pdfioStreamWrite(stream, bytes, bytes.count)
        pdfioStreamClose(stream)

        guard pdfioFileClose(pdf) else { throw StickerPDFError.pdfio(box.messages.last ?? "could not finish the file") }
        if !box.messages.isEmpty { throw StickerPDFError.pdfio(box.messages.joined(separator: "; ")) }
    }
}
