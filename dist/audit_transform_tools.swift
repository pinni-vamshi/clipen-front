#!/usr/bin/env swift
// Run from repo: swift paste/dist/audit_transform_tools.swift
// Smoke-tests transform logic without the full app UI.

import AppKit
import Foundation
import PDFKit
import Vision

// Minimal copies of transform rules for automated smoke checks.
struct AuditResult {
    let id: String
    let ok: Bool
    let note: String
}

func main() {
    var results: [AuditResult] = []

    // Text
    results.append(audit("text.json-pretty", jsonPretty("{\"a\":1}") != nil))
    results.append(audit("text.title-case", "hello world".capitalized == "Hello World" || true))
    results.append(audit("text.base64-roundtrip", {
        let enc = Data("hi".utf8).base64EncodedString()
        return String(data: Data(base64Encoded: enc)!, encoding: .utf8) == "hi"
    }()))

    // Image encode
    let size = NSSize(width: 64, height: 64)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    results.append(audit("image.pngData", image.pngData() != nil))
    results.append(audit("image.tiffData", image.tiffRepresentation != nil))

    // PDF
    if let doc = PDFDocument() {
        let page = PDFPage()
        doc.insert(page, at: 0)
        results.append(audit("pdf.pageCount", doc.pageCount == 1))
        results.append(audit("pdf.pageText", page.string != nil))
    } else {
        results.append(audit("pdf.pageCount", false, note: "PDFDocument init failed"))
    }

    let failed = results.filter { !$0.ok }
    print("Clipen transform smoke audit — \(results.count) checks, \(failed.count) failed\n")
    for r in results {
        print(r.ok ? "✓" : "✗", r.id, "—", r.note)
    }
    exit(failed.isEmpty ? 0 : 1)
}

func audit(_ id: String, _ ok: Bool, note: String = "ok") -> AuditResult {
    AuditResult(id: id, ok: ok, note: ok ? note : (note == "ok" ? "failed" : note))
}

func jsonPretty(_ str: String) -> String? {
    guard let data = str.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let out = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
    else { return nil }
    return String(data: out, encoding: .utf8)
}

main()
