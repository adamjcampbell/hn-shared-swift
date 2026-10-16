import Foundation
import SwiftParser
import SwiftSyntax

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sources = root.appendingPathComponent("HackerNewsReader/Sources/HackerNewsReader")
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func parse(_ name: String) throws -> SourceFileSyntax {
    Parser.parse(source: try String(contentsOf: sources.appendingPathComponent(name + ".swift"), encoding: .utf8))
}

struct Field {
    let name: String
    let type: String
    let writable: Bool
    var upper: String { name.prefix(1).uppercased() + name.dropFirst() }
    var booleanStem: String {
        name.hasPrefix("is") && name.dropFirst(2).first?.isUppercase == true ? String(name.dropFirst(2)) : upper
    }
    var getter: String { type == "Bool" ? "is\(booleanStem)" : "get\(upper)" }
    var setter: String { "set\(type == "Bool" ? booleanStem : upper)" }
}

func fields(_ members: MemberBlockItemListSyntax) -> [Field] {
    members.flatMap { member -> [Field] in
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              variable.modifiers.contains(where: { $0.name.text == "public" && $0.detail == nil }) else { return [] }
        return variable.bindings.map { binding in
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let type = binding.typeAnnotation?.type.trimmedDescription else {
                fatalError("Bridged properties require an explicit name and type")
            }
            let restricted = variable.modifiers.contains { $0.detail?.detail.text == "set" && $0.name.text != "public" }
            let computed: Bool
            if let block = binding.accessorBlock {
                if let accessors = block.accessors.as(AccessorDeclListSyntax.self) {
                    computed = !accessors.contains { ["set", "willSet", "didSet"].contains($0.accessorSpecifier.text) }
                } else {
                    computed = true
                }
            } else {
                computed = false
            }
            return Field(name: name, type: type, writable: variable.bindingSpecifier.text == "var" && !restricted && !computed)
        }
    }
}

let model = try parse("Model").statements.compactMap { $0.item.as(ClassDeclSyntax.self) }.first { $0.name.text == "Model" }!
let properties = fields(model.memberBlock.members)
let valueNames = ["StoryRow", "LoadedStories", "LoadStatus"]

func validate(_ field: Field, in owner: String, writable: Bool) {
    let scalars = ["String", "Int", "Int64", "Bool", "Double"]
    let readable = scalars + ["Date", "String?", "[String]"] + valueNames + valueNames.map { $0 + "?" } + valueNames.map { "[" + $0 + "]" }
    guard readable.contains(field.type) else {
        fatalError("Unsupported bridge property \(owner).\(field.name): \(field.type). Supported reads: scalar String/Int/Int64/Bool/Double, Date, String?, [String], and StoryRow/LoadedStories/LoadStatus (plain, optional, or array). Primitive optionals and nested collections require explicit official JNI conversions.")
    }
    guard !writable || scalars.contains(field.type) else {
        fatalError("Unsupported writable bridge property \(owner).\(field.name): \(field.type). Public setters support only String/Int/Int64/Bool/Double; optional, array, Date, and projected-value setters require explicit official JNI conversions. Restrict setter visibility for read-only projection.")
    }
}

for field in properties { validate(field, in: "Model", writable: field.writable) }
let projections = try valueNames.map { name in
    let declaration = try parse(name).statements.compactMap { $0.item.as(StructDeclSyntax.self) }.first { $0.name.text == name }!
    let members = fields(declaration.memberBlock.members)
    for field in members { validate(field, in: name, writable: false) }
    return (name, members)
}

func swiftType(_ type: String) -> String {
    if type == "Date" { return "Double" }
    if valueNames.contains(type) { return "Android" + type }
    if type.hasSuffix("?") { return swiftType(String(type.dropLast())) + "?" }
    if type.hasPrefix("[") && type.hasSuffix("]") { return "[" + swiftType(String(type.dropFirst().dropLast())) + "]" }
    guard ["String", "Int", "Int64", "Bool", "Double"].contains(type) else { fatalError("Unsupported bridge type: \(type)") }
    return type
}

func swiftValue(_ expression: String, _ type: String) -> String {
    if type == "Date" { return expression + ".timeIntervalSince1970" }
    if valueNames.contains(type) { return "Android\(type)(\(expression))" }
    if type.hasSuffix("?") { return expression + ".map { " + swiftValue("$0", String(type.dropLast())) + " }" }
    if type.hasPrefix("[") && type.hasSuffix("]") { return expression + ".map { " + swiftValue("$0", String(type.dropFirst().dropLast())) + " }" }
    _ = swiftType(type)
    return expression
}

func kotlinType(_ type: String) -> String {
    switch type {
    case "Date", "Double": return "Double"
    case "String": return "String"
    case "Bool": return "Boolean"
    case "Int", "Int64": return "Long"
    default:
        if valueNames.contains(type) { return type }
        if type.hasSuffix("?") { return kotlinType(String(type.dropLast())) + "?" }
        if type.hasPrefix("[") && type.hasSuffix("]") { return "List<" + kotlinType(String(type.dropFirst().dropLast())) + ">" }
        fatalError("Unsupported Kotlin type: \(type)")
    }
}

func kotlinValue(_ expression: String, _ type: String) -> String {
    if valueNames.contains(type) { return "\(type).read(\(expression))" }
    if type.hasSuffix("?") { return expression + ".orElse(null)?.let { " + kotlinValue("it", String(type.dropLast())) + " }" }
    if type.hasPrefix("[") && type.hasSuffix("]") { return expression + ".map { " + kotlinValue("it", String(type.dropFirst().dropLast())) + " }" }
    return expression
}

var swift = "// Generated by scripts/generate-android.swift.\nextension AndroidReader {\n"
var kotlin = """
// Generated by scripts/generate-android.swift.
package com.example.hackernewsreader.bridge

import androidx.compose.runtime.mutableLongStateOf
import org.swift.swiftkit.core.SwiftArena
import com.example.hackernewsreader.swift.AndroidReader

class Model internal constructor(private val native: AndroidReader) : AutoCloseable {
    private val slots = mutableMapOf<String, Pair<androidx.compose.runtime.MutableLongState, Long>>()
    private var closed = false
    private fun access(name: String, subscribe: (() -> Unit) -> Long) {
        check(!closed)
        val slot = slots.getOrPut(name) {
            val revision = mutableLongStateOf(0L)
            val token = subscribe { if (!closed) revision.longValue += 1L }
            revision to token
        }
        slot.first.longValue
    }
    override fun close() {
        if (closed) return
        closed = true
        slots.values.forEach { native.cancel(it.second) }
        slots.clear()
    }

"""
for field in properties {
    swift += "    public var \(field.name): \(swiftType(field.type)) {\n"
    swift += "        get { MainActor.assumeIsolated { \(swiftValue("storage.model." + field.name, field.type)) } }\n"
    if field.writable {
        precondition(swiftType(field.type) == field.type, "Writable value conversion is not supported")
        swift += "        set { MainActor.assumeIsolated { storage.model.\(field.name) = newValue } }\n"
    }
    swift += "    }\n    public func observe\(field.upper)(_ callback: sending @escaping () -> Void) -> Int64 {\n"
    swift += "        MainActor.assumeIsolated { storage.observe(read: { [storage] in _ = storage.model.\(field.name) }, callback: callback) }\n    }\n"
    let arena = field.type.contains("StoryRow") || field.type.contains("LoadedStories") || field.type.contains("LoadStatus")
    let getter = field.getter
    kotlin += "    \(field.writable ? "var" : "val") \(field.name): \(kotlinType(field.type))\n        get() {\n"
    kotlin += "            access(\"\(field.name)\") { notify -> native.observe\(field.upper) { notify() } }\n"
    let value = kotlinValue("native.\(getter)(\(arena ? "arena" : ""))", field.type)
    kotlin += "            return \(arena ? "SwiftArena.ofConfined().use { arena -> " + value + " }" : value)\n        }\n"
    if field.writable { kotlin += "        set(value) { check(!closed); native.\(field.setter)(value) }\n" }
}
swift += "}\n"
kotlin += "}\n"

for (name, members) in projections {
    swift += "\npublic struct Android\(name): Sendable {\n"
    for field in members { swift += "    public let \(field.name): \(swiftType(field.type))\n" }
    swift += "    init(_ value: \(name)) {\n"
    for field in members { swift += "        \(field.name) = \(swiftValue("value." + field.name, field.type))\n" }
    swift += "    }\n}\n"
    kotlin += "\ndata class \(name)(\n" + members.map { "    val \($0.name): \(kotlinType($0.type))," }.joined(separator: "\n") + "\n) {\n"
    kotlin += "    companion object {\n        internal fun read(value: com.example.hackernewsreader.swift.Android\(name)) = \(name)(\n"
    for field in members {
        let getter = field.getter
        let arena = valueNames.contains { field.type.contains($0) }
        let value = kotlinValue("value.\(getter)(\(arena ? "arena" : ""))", field.type)
        kotlin += "            \(field.name) = \(arena ? "SwiftArena.ofConfined().use { arena -> " + value + " }" : value),\n"
    }
    kotlin += "        )\n    }\n}\n"
}

try swift.write(to: sources.appendingPathComponent("AndroidReader.generated.swift"), atomically: true, encoding: .utf8)
try kotlin.write(to: output.appendingPathComponent("Model.kt"), atomically: true, encoding: .utf8)
print("Generated \(properties.count) observed properties and \(valueNames.count) value projections")
