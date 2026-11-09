import Foundation

/// The upload sizes the app can make files for. The figures come from public seller guides and help pages, not from each
/// site's own rules, which change and sometimes differ by print provider. Each note tells the person to compare with the
/// upload page. Where guides disagreed, the preset is left out unless the app's owner gave the size.
public enum MarketplaceCatalog {
    // MARK: Shirts and apparel

    /// The standard Merch on Demand apparel print area is 15 x 18 inches at 300 DPI. It is used for shirts, hoodies,
    /// sweatshirts and tank tops.
    public static let amazonMerchShirt = MarketplacePreset(
        id: "amazon-merch-shirt", name: "Amazon Merch on Demand · shirt, hoodie, tank", pixelWidth: 4500, pixelHeight: 5400, maxFileMegabytes: 25,
        note: "Transparent PNG, sRGB. Amazon reads the pixel size, so the file is made at exactly 4500 × 5400. Other Amazon products use other sizes, and Amazon can change its rules, so compare with the upload page in your account.")

    public static let printOnDemandShirt = MarketplacePreset(
        id: "pod-shirt", name: "Print-on-demand shirt (Printful, Printify, Spring, Gelato)", pixelWidth: 4500, pixelHeight: 5400, maxFileMegabytes: 25,
        note: "The size most print-on-demand shops accept for a shirt front or back. Each shop and print provider can differ, so compare with the product page before you upload.")

    public static let redbubbleApparel = MarketplacePreset(
        id: "redbubble-large", name: "Redbubble · apparel, posters, phone cases (large upload)", pixelWidth: 6000, pixelHeight: 8000, maxFileMegabytes: 300,
        note: "Redbubble scales one large upload to every product. 6000 × 8000 is the starting size seller guides recommend, and the site accepts up to 13500 × 13500 and 300 MB. Compare with Redbubble's own help page.")

    /// Amazon's phone grip. Seller guides disagreed (485 or 1876 px); this is the size given by the app's owner, who sells on Merch.
    public static let amazonPopSocket = MarketplacePreset(
        id: "amazon-popsocket", name: "Amazon Merch on Demand · phone grip", pixelWidth: 485, pixelHeight: 485, centerVertically: true,
        note: "Transparent PNG, 485 × 485 px. Keep it simple, because fine detail gets lost on a small grip. Compare with the template in your Amazon account.")

    public static let teepublicLarge = MarketplacePreset(
        id: "teepublic-5000", name: "TeePublic · large square", pixelWidth: 5000, pixelHeight: 5000, centerVertically: true,
        note: "TeePublic does not need one fixed size; a 5000 × 5000 transparent PNG is accepted. Compare with TeePublic's artist upload page.")

    public static let teepublicSmall = MarketplacePreset(
        id: "teepublic-1500", name: "TeePublic · 1500 × 1995", pixelWidth: 1500, pixelHeight: 1995, centerVertically: true,
        note: "A smaller size TeePublic also accepts. Use the large one when you can, since a bigger file prints sharper.")

    // MARK: Stickers

    public static let redbubbleSticker = MarketplacePreset(
        id: "redbubble-sticker", name: "Redbubble · sticker, magnet", pixelWidth: 2800, pixelHeight: 2800, maxFileMegabytes: 300, centerVertically: true,
        note: "Square, transparent PNG. Sticker and magnet minimum on Redbubble's help page; compare with that page.")

    public static let squareLargeSticker = MarketplacePreset(
        id: "square-8000", name: "Square, large (stickers, hats, acrylic)", pixelWidth: 8000, pixelHeight: 8000, centerVertically: true,
        note: "A large square, the size some seller guides give for stickers, hats and acrylic blocks. It is a big file; use it only when the site asks for it.")

    public static let squarePattern = MarketplacePreset(
        id: "square-5000", name: "Square, pattern (totes, laptop sleeves, notebooks)", pixelWidth: 5000, pixelHeight: 5000, centerVertically: true,
        note: "A square 5000 × 5000 file, the size seller guides give for patterns on bags, sleeves and notebooks.")

    // MARK: Mugs

    public static let redbubbleMug = MarketplacePreset(
        id: "redbubble-mug", name: "Redbubble · mug", pixelWidth: 2700, pixelHeight: 1120, maxFileMegabytes: 300, centerVertically: true,
        note: "Standard mug wrap on Redbubble's help page. Compare with that page.")

    public static let printfulMug11 = MarketplacePreset(
        id: "printful-mug-11oz", name: "Printful · 11 oz mug", pixelWidth: 2700, pixelHeight: 1050, centerVertically: true,
        note: "From a seller support guide. Printful's own product page has the current template; compare with it.")

    public static let printifyMug11 = MarketplacePreset(
        id: "printify-mug-11oz", name: "Printify · 11 oz mug", pixelWidth: 2700, pixelHeight: 1100, centerVertically: true,
        note: "From a seller template guide. The size depends on the print provider you pick, so compare with the product page.")

    public static let all: [MarketplacePreset] = [
        amazonMerchShirt, printOnDemandShirt, redbubbleApparel,
        amazonPopSocket, teepublicLarge, teepublicSmall,
        redbubbleSticker, squareLargeSticker, squarePattern,
        redbubbleMug, printfulMug11, printifyMug11,
    ]

    public static func preset(id: String) -> MarketplacePreset? { all.first { $0.id == id } }
}
