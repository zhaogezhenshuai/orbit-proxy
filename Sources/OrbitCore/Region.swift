import Foundation

/// Works out a node's region from its name when the name doesn't start with a flag emoji,
/// e.g. "香港 01", "HK-02", "IEPL Tokyo", so region filters and same-region relays still work.
public enum Region {
    /// ISO code → place names (matched case-insensitively) and short codes (matched in upper case,
    /// not touching other letters: "HK01" matches, "CHKS" doesn't). No entry for China itself:
    /// "中国" usually prefixes another place ("中国香港"), and nodes in China aren't a thing here.
    static let table: [(code: String, names: [String], codes: [String])] = [
        ("HK", ["香港", "港", "Hong Kong", "HongKong"], ["HK", "HKG"]),
        ("TW", ["台湾", "台灣", "台北", "Taiwan", "Taipei"], ["TW"]),
        ("MO", ["澳门", "澳門", "Macau", "Macao"], ["MO"]),
        ("JP", ["日本", "东京", "東京", "大阪", "Japan", "Tokyo", "Osaka"], ["JP"]),
        ("KR", ["韩国", "韓國", "首尔", "Korea", "Seoul"], ["KR"]),
        ("SG", ["新加坡", "狮城", "獅城", "Singapore"], ["SG"]),
        ("US", ["美国", "美國", "洛杉矶", "硅谷", "西雅图", "纽约", "芝加哥", "圣何塞", "United States", "America",
                "Los Angeles", "Seattle", "San Jose", "Silicon Valley", "New York", "Chicago"], ["US", "USA"]),
        // Not "GB": it's the gigabyte unit in names like "剩余流量：10GB".
        ("GB", ["英国", "英國", "伦敦", "United Kingdom", "Britain", "London"], ["UK"]),
        ("DE", ["德国", "德國", "法兰克福", "Germany", "Frankfurt"], ["DE"]),
        ("FR", ["法国", "法國", "巴黎", "France", "Paris"], ["FR"]),
        ("NL", ["荷兰", "荷蘭", "阿姆斯特丹", "Netherlands", "Amsterdam"], ["NL"]),
        ("CA", ["加拿大", "多伦多", "Canada", "Toronto"], ["CA"]),
        ("AU", ["澳大利亚", "澳洲", "悉尼", "Australia", "Sydney"], ["AU"]),
        ("NZ", ["新西兰", "New Zealand"], ["NZ"]),
        ("RU", ["俄罗斯", "俄羅斯", "莫斯科", "Russia", "Moscow"], ["RU"]),
        ("IN", ["印度", "孟买", "India", "Mumbai"], ["IN"]),
        ("ID", ["印尼", "印度尼西亚", "雅加达", "Indonesia", "Jakarta"], []),
        ("MY", ["马来西亚", "馬來西亞", "吉隆坡", "Malaysia", "Kuala Lumpur"], ["MY"]),
        ("TH", ["泰国", "泰國", "曼谷", "Thailand", "Bangkok"], ["TH"]),
        ("VN", ["越南", "胡志明", "Vietnam", "Viet Nam"], ["VN"]),
        ("PH", ["菲律宾", "菲律賓", "马尼拉", "Philippines", "Manila"], ["PH"]),
        ("TR", ["土耳其", "伊斯坦布尔", "Turkey", "Türkiye", "Istanbul"], ["TR"]),
        ("AE", ["阿联酋", "迪拜", "Dubai", "Emirates"], ["UAE", "AE"]),
        ("SA", ["沙特", "Saudi"], ["SA"]),
        ("IL", ["以色列", "Israel"], ["IL"]),
        ("EG", ["埃及", "Egypt"], ["EG"]),
        ("ZA", ["南非", "South Africa"], ["ZA"]),
        ("NG", ["尼日利亚", "Nigeria"], ["NG"]),
        ("BR", ["巴西", "圣保罗", "Brazil", "Sao Paulo"], ["BR"]),
        ("AR", ["阿根廷", "Argentina"], ["AR"]),
        ("CL", ["智利", "Chile"], ["CL"]),
        ("MX", ["墨西哥", "Mexico"], ["MX"]),
        ("IT", ["意大利", "米兰", "Italy", "Milan"], ["IT"]),
        ("ES", ["西班牙", "马德里", "Spain", "Madrid"], ["ES"]),
        ("CH", ["瑞士", "苏黎世", "Switzerland", "Zurich"], ["CH"]),
        ("SE", ["瑞典", "Sweden"], ["SE"]),
        ("NO", ["挪威", "Norway"], []),
        ("FI", ["芬兰", "Finland"], ["FI"]),
        ("PL", ["波兰", "Poland"], ["PL"]),
        ("AT", ["奥地利", "Austria"], []),
        ("IE", ["爱尔兰", "Ireland"], ["IE"]),
        ("UA", ["乌克兰", "Ukraine"], ["UA"]),
        ("KZ", ["哈萨克斯坦", "Kazakhstan"], ["KZ"]),
    ]

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var flags: [String: String] = [:]
    }

    private static let cache = Cache()

    /// Flag emoji for the region named in `name`, or "" if none is recognised. A flag emoji anywhere
    /// in the name wins; otherwise the place name or code appearing first (longest on a tie, so
    /// "印度尼西亚" isn't read as "印度").
    public static func flag(inName name: String) -> String {
        cache.lock.lock()
        if let f = cache.flags[name] { cache.lock.unlock(); return f }
        cache.lock.unlock()
        let f = embeddedFlag(name) ?? detect(name).map(flag(code:)) ?? ""
        cache.lock.lock()
        cache.flags[name] = f
        cache.lock.unlock()
        return f
    }

    /// "HK" → "🇭🇰".
    public static func flag(code: String) -> String {
        let scalars = code.uppercased().unicodeScalars.compactMap { UnicodeScalar(0x1F1E6 - 65 + $0.value) }
        return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : ""
    }

    static func embeddedFlag(_ name: String) -> String? {
        let s = Array(name.unicodeScalars)
        guard s.count >= 2 else { return nil }
        for i in 0..<(s.count - 1) where isIndicator(s[i]) && isIndicator(s[i + 1]) {
            return String(String.UnicodeScalarView([s[i], s[i + 1]]))
        }
        return nil
    }

    static func detect(_ name: String) -> String? {
        var best: (offset: Int, length: Int, code: String)?
        for entry in table {
            for (keyword, isCode) in entry.names.map({ ($0, false) }) + entry.codes.map({ ($0, true) }) {
                guard let offset = firstMatch(of: keyword, in: name, isCode: isCode) else { continue }
                let length = keyword.count
                if best == nil || offset < best!.offset || (offset == best!.offset && length > best!.length) {
                    best = (offset, length, entry.code)
                }
            }
        }
        return best?.code
    }

    /// Character offset of the first occurrence that isn't part of a longer Latin word.
    static func firstMatch(of keyword: String, in name: String, isCode: Bool) -> Int? {
        let ascii = keyword.unicodeScalars.allSatisfy(\.isASCII)
        var from = name.startIndex
        while let r = name.range(of: keyword, options: isCode ? [] : [.caseInsensitive], range: from..<name.endIndex) {
            let before = r.lowerBound > name.startIndex ? name[name.index(before: r.lowerBound)] : nil
            let after = r.upperBound < name.endIndex ? name[r.upperBound] : nil
            if !ascii || (!isLatinLetter(before) && !isLatinLetter(after)) {
                return name.distance(from: name.startIndex, to: r.lowerBound)
            }
            from = name.index(after: r.lowerBound)
        }
        return nil
    }

    static func isLatinLetter(_ c: Character?) -> Bool {
        guard let c, let a = c.asciiValue else { return false }
        return (a >= 65 && a <= 90) || (a >= 97 && a <= 122)
    }

    static func isIndicator(_ s: Unicode.Scalar) -> Bool { (0x1F1E6...0x1F1FF).contains(s.value) }
}
