#if os(Android)
import FoundationEssentials
import PlatformSupport
#else
import Foundation
#endif

func localized(_ key: String, default value: String) -> String {
    #if os(Android)
    return catalogString(key, default: value, preferredLanguages: preferredLanguages(), tables: stringTables)
    #else
    return Bundle.module.localizedString(forKey: key, value: value, table: nil)
    #endif
}

func catalogString(_ key: String, default value: String, preferredLanguages: [String], tables: [String: [String: String]]) -> String {
    let normalized = Dictionary(uniqueKeysWithValues: tables.map { ($0.key.lowercased(), $0.value) })
    for preference in preferredLanguages {
        var language = preference.lowercased()
        while !language.isEmpty {
            if let table = normalized[language] { return table[key] ?? value }
            guard let separator = language.lastIndex(of: "-") else { break }
            language = String(language[..<separator])
        }
    }
    return value
}

// Scan only the template: inserted user text must never become a format token.
func formatLocalized(_ template: String, _ arguments: [String]) -> String {
    var output = ""
    var cursor = template.startIndex
    var implicitIndex = 0
    while cursor < template.endIndex {
        let character = template[cursor]
        cursor = template.index(after: cursor)
        guard character == "%" else { output.append(character); continue }
        precondition(cursor < template.endIndex, "Incomplete catalog format")
        if template[cursor] == "%" {
            output.append("%")
            cursor = template.index(after: cursor)
            continue
        }
        var digits = ""
        while cursor < template.endIndex, template[cursor].isASCII, template[cursor].isNumber {
            digits.append(template[cursor])
            cursor = template.index(after: cursor)
        }
        let index: Int
        if !digits.isEmpty {
            precondition(cursor < template.endIndex && template[cursor] == "$")
            index = (Int(digits) ?? 0) - 1
            cursor = template.index(after: cursor)
        } else {
            index = implicitIndex
            implicitIndex += 1
        }
        if template[cursor...].hasPrefix("lld") {
            cursor = template.index(cursor, offsetBy: 3)
        } else {
            precondition(cursor < template.endIndex && (template[cursor] == "@" || template[cursor] == "d"))
            cursor = template.index(after: cursor)
        }
        precondition(arguments.indices.contains(index), "Invalid catalog argument index")
        output += arguments[index]
    }
    return output
}
