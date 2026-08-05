import Foundation
import CoreGraphics
import ImageIO

/// Writes ownership and licensing metadata into exported files.
///
/// This is the only place the app *authors* metadata rather than copying it through.
/// Two carriers are involved and they are not interchangeable:
///
/// - **IPTC** goes in the normal properties dictionary. ImageIO mirrors the fields it
///   recognises into XMP on its own, so setting `Byline` also produces `dc:creator`.
/// - **XMP** needs a `CGImageMetadata` and `CGImageDestinationAddImageAndMetadata`,
///   because `xmpRights:WebStatement` and `plus:Licensor` have no property-dictionary
///   equivalent to set.
enum RightsWriter {
    private static let xmpRightsNamespace = "http://ns.adobe.com/xap/1.0/rights/" as CFString
    private static let plusNamespace = "http://ns.useplus.org/ldf/xmp/1.0/" as CFString
    private static let photoshopNamespace = "http://ns.adobe.com/photoshop/1.0/" as CFString

    /// The IPTC dictionary to write, merged over anything the source already carried.
    ///
    /// Returns `nil` when there is nothing to say, so callers can leave inherited
    /// metadata untouched rather than rewriting it identically.
    static func iptcDictionary(
        existing: [CFString: Any]?,
        rights: RightsMetadata,
        source: URL,
        altText: String? = nil
    ) -> [CFString: Any]? {
        var iptc = existing ?? [:]
        var changed = false

        func assign(_ key: CFString, _ value: Any?) {
            guard let value else { return }
            iptc[key] = value
            changed = true
        }

        // Byline is a list in IPTC even when there is one author.
        if let creator = rights.creator, !creator.isEmpty {
            assign(kCGImagePropertyIPTCByline, [creator])
        }
        if let copyright = rights.copyrightNotice, !copyright.isEmpty {
            assign(kCGImagePropertyIPTCCopyrightNotice, copyright)
        }
        if let credit = rights.credit, !credit.isEmpty {
            assign(kCGImagePropertyIPTCCredit, credit)
        }

        switch resolve(rights.titlePolicy, source: source, humanise: true, altText: altText) {
        case .some(let title): assign(kCGImagePropertyIPTCObjectName, title)
        case nil where rights.titlePolicy == .empty:
            iptc.removeValue(forKey: kCGImagePropertyIPTCObjectName)
            changed = true
        default: break
        }

        switch resolve(rights.descriptionPolicy, source: source, humanise: true, altText: altText) {
        case .some(let description): assign(kCGImagePropertyIPTCCaptionAbstract, description)
        case nil where rights.descriptionPolicy == .empty:
            iptc.removeValue(forKey: kCGImagePropertyIPTCCaptionAbstract)
            changed = true
        default: break
        }

        return changed ? iptc : nil
    }

    /// The XMP that cannot be expressed as image properties.
    static func metadata(rights: RightsMetadata) -> CGImageMetadata? {
        let webStatement = rights.webStatementURL?.isEmpty == false ? rights.webStatementURL : nil
        let licensor = rights.licensorURL?.isEmpty == false ? rights.licensorURL : nil
        let credit = rights.credit?.isEmpty == false ? rights.credit : nil
        guard webStatement != nil || licensor != nil || credit != nil else { return nil }

        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, xmpRightsNamespace, "xmpRights" as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(metadata, plusNamespace, "plus" as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(metadata, photoshopNamespace, "photoshop" as CFString, nil)

        if let webStatement {
            CGImageMetadataSetValueWithPath(metadata, nil, "xmpRights:WebStatement" as CFString, webStatement as CFString)
        }
        if let credit {
            CGImageMetadataSetValueWithPath(metadata, nil, "photoshop:Credit" as CFString, credit as CFString)
        }
        if let licensor { setLicensor(licensor, in: metadata) }
        return metadata
    }

    /// An XMP packet for carriers that take raw XMP rather than a `CGImageMetadata` —
    /// WebP, whose chunks are set by the bundled `webpmux`.
    static func xmpPacket(rights: RightsMetadata) -> Data? {
        guard let metadata = metadata(rights: rights) else { return nil }
        return CGImageMetadataCreateXMPData(metadata, nil) as Data?
    }

    /// `plus:Licensor` is an ordered array of structures, which the path syntax cannot
    /// create — `SetValueWithPath` on `plus:Licensor[1]/plus:LicensorURL` simply returns
    /// false. The array and its structure have to be built as tags and set in one go.
    private static func setLicensor(_ url: String, in metadata: CGMutableImageMetadata) {
        guard let urlTag = CGImageMetadataTagCreate(
            plusNamespace, "plus" as CFString, "LicensorURL" as CFString,
            .string, url as CFString
        ), let structure = CGImageMetadataTagCreate(
            plusNamespace, "plus" as CFString, "Licensor" as CFString,
            .structure, ["LicensorURL": urlTag] as CFDictionary
        ), let array = CGImageMetadataTagCreate(
            plusNamespace, "plus" as CFString, "Licensor" as CFString,
            .arrayOrdered, [structure] as CFArray
        ) else { return }
        CGImageMetadataSetTagWithPath(metadata, nil, "plus:Licensor" as CFString, array)
    }

    /// The text a policy produces, or `nil` to leave the field as it is.
    static func resolve(
        _ policy: RightsMetadata.TextPolicy,
        source: URL,
        humanise: Bool,
        altText: String? = nil
    ) -> String? {
        switch policy {
        case .keepExisting, .empty: nil
        case .fromFilename:
            humanise
                ? humanised(source.deletingPathExtension().lastPathComponent)
                : source.deletingPathExtension().lastPathComponent
        // No suggestion means leave the field alone rather than clear it: the generator
        // declines when it is not confident, and that is not an instruction to erase
        // whatever the source already carried.
        case .fromAltText: altText
        }
    }

    /// Turns a filename into something readable enough to be a title: the slug, with
    /// separators as spaces and each word capitalised. `IMG_4821 Café Sign` becomes
    /// `Cafe Sign` rather than the raw stem, because the camera prefix and its frame
    /// number are noise in a caption as much as in a filename.
    static func humanised(_ stem: String) -> String {
        let slug = OutputNaming.slug(stem)
        guard !slug.isEmpty else { return stem }
        return slug
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
