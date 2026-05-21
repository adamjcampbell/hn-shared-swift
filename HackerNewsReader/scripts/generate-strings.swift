#!/usr/bin/env swift
// Reads HackerNewsReader's Localizable.xcstrings and writes a
// Strings.swift file with `tr(_:_:)`-routed accessors. Run from the
// package root:
//
//   swift HackerNewsReader/scripts/generate-strings.swift
//
// The output is deterministic (keys sorted) so re-running produces
// byte-identical output unless the catalog changed.
import Foundation

// MARK: - Catalog model

struct Catalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]
}

struct Entry: Decodable {
    let comment: String?
    let localizations: [String: Localization]?
}

struct Localization: Decodable {
    let stringUnit: StringUnit
}

struct StringUnit: Decodable {
    let value: String
}

// MARK: - Format-specifier parser

/// One positional argument extracted from a localised value's format
/// specifiers. `index` is 1-based so positional `%2$@` and bare `%@`
/// (auto-numbered) merge consistently.
struct FormatArg {
    let index: Int
    let swiftType: String
}

/// Scans `value` for `%@`, `%lld`, `%d`, and positional variants like
/// `%1$@`. Returns args ordered by positional index. `%%` is skipped.
func parseFormatArgs(_ value: String) -> [FormatArg] {
    var args: [FormatArg] = []
    var implicitIndex = 0
    var i = value.startIndex
    while i < value.endIndex {
        guard value[i] == "%" else { i = value.index(after: i); continue }
        let next = value.index(after: i)
        guard next < value.endIndex else { break }
        if value[next] == "%" {
            i = value.index(after: next)
            continue
        }
        var cursor = next
        var positional: Int? = nil
        if value[cursor].isASCII && value[cursor].isNumber {
            var digits = ""
            while cursor < value.endIndex, value[cursor].isNumber {
                digits.append(value[cursor])
                cursor = value.index(after: cursor)
            }
            if cursor < value.endIndex, value[cursor] == "$" {
                positional = Int(digits)
                cursor = value.index(after: cursor)
            } else {
                // Not actually positional (e.g. width spec); rewind.
                cursor = next
            }
        }
        guard cursor < value.endIndex else { break }
        let spec: String
        if value[cursor...].hasPrefix("lld") {
            spec = "lld"
            cursor = value.index(cursor, offsetBy: 3)
        } else {
            spec = String(value[cursor])
            cursor = value.index(after: cursor)
        }
        let swiftType: String
        switch spec {
        case "@": swiftType = "String"
        case "lld": swiftType = "Int"
        case "d": swiftType = "Int32"
        case "lf", "f": swiftType = "Double"
        default:
            // Unknown spec — skip, don't model it.
            i = cursor
            continue
        }
        implicitIndex += 1
        args.append(FormatArg(index: positional ?? implicitIndex, swiftType: swiftType))
        i = cursor
    }
    return args.sorted { $0.index < $1.index }
}

// MARK: - Code generation

func swiftStringLiteral(_ value: String) -> String {
    var out = "\""
    for ch in value {
        switch ch {
        case "\\": out.append("\\\\")
        case "\"": out.append("\\\"")
        case "\n": out.append("\\n")
        case "\t": out.append("\\t")
        case "\r": out.append("\\r")
        default: out.append(ch)
        }
    }
    out.append("\"")
    return out
}

func docComment(_ comment: String?, indent: String) -> String {
    guard let comment, !comment.isEmpty else { return "" }
    return comment
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { "\(indent)/// \($0)\n" }
        .joined()
}

func emitAccessor(key: String, value: String, comment: String?) -> String {
    let args = parseFormatArgs(value)
    let header = docComment(comment, indent: "    ")
    let keyLit = swiftStringLiteral(key)
    let valueLit = swiftStringLiteral(value)
    if args.isEmpty {
        return """
        \(header)    public static var \(key): String {
                tr(\(keyLit), \(valueLit))
            }
        """
    }
    let params = args.enumerated().map { offset, arg in
        "_ arg\(offset + 1): \(arg.swiftType)"
    }.joined(separator: ", ")
    let forwarded = args.indices.map { "arg\($0 + 1)" }.joined(separator: ", ")
    return """
    \(header)    public static func \(key)(\(params)) -> String {
            String(format: tr(\(keyLit), \(valueLit)), \(forwarded))
        }
    """
}

// MARK: - Driver

let packageRoot: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1])
    }
    // Default: script lives at <root>/scripts/generate-strings.swift
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}()

let catalogURL = packageRoot
    .appendingPathComponent("Sources/HackerNewsReader/Resources/Localizable.xcstrings")
let outputURL = packageRoot
    .appendingPathComponent("Sources/HackerNewsReader/Strings.swift")

let data = try Data(contentsOf: catalogURL)
let catalog = try JSONDecoder().decode(Catalog.self, from: data)

let entries: [(key: String, value: String, comment: String?)] = catalog.strings
    .compactMap { key, entry in
        guard let value = entry.localizations?[catalog.sourceLanguage]?.stringUnit.value
        else { return nil }
        return (key, value, entry.comment)
    }
    .sorted { $0.key < $1.key }

let accessors = entries.map { emitAccessor(key: $0.key, value: $0.value, comment: $0.comment) }

let body = accessors.joined(separator: "\n\n")
let output = """
// This file is generated by scripts/generate-strings.swift.
// Do not edit by hand — edit Localizable.xcstrings and rerun the script.
import Foundation

/// User-visible strings backed by `Localizable.xcstrings`. Each
/// accessor routes through ``tr(_:_:)`` for catalog lookup with the
/// English source as the runtime fallback.
// SKIP @bridgeMembers
public enum Strings {

\(body)
}

"""

try output.write(to: outputURL, atomically: true, encoding: .utf8)
print("Wrote \(outputURL.path)")
