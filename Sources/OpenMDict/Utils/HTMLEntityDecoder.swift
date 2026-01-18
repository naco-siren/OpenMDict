import Foundation

extension String {
    
    /// Decode common HTML/XML entities
    ///
    /// MDX file headers are stored as XML (UTF-16LE encoded), so metadata fields like
    /// Title and Description are XML attribute values that may contain escaped entities.
    /// XML defines 5 predefined entities: &amp; &lt; &gt; &quot; &apos;
    /// But some dictionary authors also use HTML named entities, so we support common ones.
    ///
    /// Note: This is for metadata decoding, NOT for article content.
    /// Article content format is determined by the "Format" field (Html/Text).
    var htmlEntityDecoded: String {
        var result = self
        
        // Named entities (most common ones in dictionary metadata)
        let namedEntities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&ndash;", "–"),
            ("&mdash;", "—"),
            ("&lsquo;", "'"),
            ("&rsquo;", "'"),
            ("&ldquo;", "\""),
            ("&rdquo;", "\""),
            ("&hellip;", "…"),
            ("&copy;", "©"),
            ("&reg;", "®"),
            ("&trade;", "™"),
        ]
        
        for (entity, char) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        
        // Decimal numeric entities: &#39; &#160; etc.
        if let regex = try? NSRegularExpression(pattern: "&#([0-9]+);", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range).reversed()
            for match in matches {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[codeRange]),
                   let scalar = Unicode.Scalar(codePoint) {
                    let char = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: char)
                    }
                }
            }
        }
        
        // Hex numeric entities: &#x27; &#x2019; etc.
        if let regex = try? NSRegularExpression(pattern: "&#[xX]([0-9a-fA-F]+);", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range).reversed()
            for match in matches {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[codeRange], radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    let char = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: char)
                    }
                }
            }
        }
        
        return result
    }
}
