# MerchSwift

Design app for print-ready stickers, t-shirts and mugs, for iPhone, iPad and Mac. A PDFSwift product (https://pdfswift.cc/merchswift).

This repository holds the app and its engine. The AI server is kept private and is not part of this repository.

## Status

Milestones M0 and M1 of the product spec: the cut line and PDF proof.

- `CutLine`: traces the artwork's outline, offsets it by an exact distance, fits cubic Beziers, writes SVG and DXF. Pure Swift (Foundation only), so it is tested on Linux as well as on Apple platforms.
- `Export`: writes a one-page PDF with the artwork and the cut line as a vector path in the spot colour `CutContour`, with a PDF/X-4 output intent, ICC profile and XMP metadata, using PDFio.
- `Apps/Shared`: a SwiftUI proof screen for iPhone, iPad and Mac (`project.yml` is the XcodeGen description).

The PDF follows the structure PDF/X-4 requires, but it has not yet been checked with Acrobat Preflight or on a real cutter. That is the M1 acceptance test.

## Build and test

```
swift test
```

For the apps: `brew install xcodegen && xcodegen generate`, then open `MerchSwift.xcodeproj`.

## Third-party code

PDFio (Apache 2.0) by Michael R Sweet is vendored in `Sources/CPDFio`; see `THIRD_PARTY_NOTICES.md`.
