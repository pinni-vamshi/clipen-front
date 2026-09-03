import Foundation

/// Converts already-structured content (a real table, valid JSON) straight
/// into the same JSON shape `AIStructuring` would eventually produce —
/// without ever calling a model. Runs ONLY after the importance-scoring
/// gate has already decided this item is worth analyzing; it never changes
/// WHETHER an item gets analyzed, only HOW — replacing a model call with a
/// few milliseconds of string processing when the content already has the
/// exact structure an LLM would otherwise be asked to extract.
///
/// The content that qualifies is content where "extraction" isn't actually
/// interpretation — a table's rows and columns already ARE the structure;
/// a JSON value already IS the structure. Asking a model to re-derive
/// something that's already there spends a full context window and 5-20
/// seconds to answer a question the content itself already answered.
///
/// This is deliberately narrow: it either produces a result it's fully
/// confident in, or returns `nil` and the caller falls straight through to
/// the normal model pipeline. There is no partial/best-effort output here
/// — a wrong deterministic guess would be worse than just asking the model,
/// since there's no repair loop for it the way there is for a model answer.
enum DeterministicStructuring {

    /// Entry point. Returns canonicalized JSON (sorted keys, matching what
    /// `AIStructuringService.validatedJSON` produces from a model answer)
    /// or `nil` to fall through to the real pipeline.
    static func convert(item: ClipboardItem) -> String? {
        switch item.primaryTag {
        case .table:
            return convertTable(item: item)
        case .json:
            return convertJSON(item: item)
        default:
            return nil
        }
    }

    // MARK: - Table

    /// Reuses the same grid extraction the inline table editor already
    /// relies on (`TableCellExtractor`), rather than re-parsing HTML/RTF
    /// tables a second, independent way — one extractor, one set of edge
    /// cases to get right, shared by editing and this.
    private static func convertTable(item: ClipboardItem) -> String? {
        guard let rows = TableCellExtractor.cells(for: item),
              TableCellExtractor.isDataTable(rows)
        else { return nil }

        let headerRowCount = detectHeaderRowCount(rows)
        guard rows.count > headerRowCount else { return nil }

        let headers = buildHeaders(from: Array(rows.prefix(headerRowCount)))
        guard headers.contains(where: { !$0.isEmpty }) else { return nil }

        let dataRows = rows.suffix(from: headerRowCount)
        var rowObjects: [[String: String]] = []
        rowObjects.reserveCapacity(dataRows.count)
        for row in dataRows {
            var obj: [String: String] = [:]
            for (idx, header) in headers.enumerated() where idx < row.count {
                let value = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                obj[header] = value
            }
            guard !obj.isEmpty else { continue }
            rowObjects.append(obj)
        }
        guard !rowObjects.isEmpty else { return nil }

        let keywords = Array(headers.filter { !$0.isEmpty }.prefix(10))
        let root: [String: Any] = [
            "rows": rowObjects,
            "row_count": rowObjects.count,
            "description": "a table with \(rowObjects.count) row\(rowObjects.count == 1 ? "" : "s") and columns: \(headers.joined(separator: ", "))",
            "keywords": keywords,
        ]
        return canonicalize(root)
    }

    /// Grouped/merged headers (a two-row "Name | Score" over "First, Last |
    /// Math, Science" layout) are a real shape spreadsheets produce, but
    /// `TableCellExtractor` extracts a flat grid with no colspan/rowspan
    /// information at all — that information is simply not recoverable
    /// from what's available. Treating it as unrecoverable rather than
    /// guessing is deliberate: a wrong guess here produces a confidently
    /// wrong header, and there is no repair loop to catch it the way a
    /// model answer has.
    ///
    /// What IS handled: the ordinary two-row-header case where the second
    /// row is non-empty in every column the first row IS empty in (each
    /// column has exactly one header source, never two to merge) — that
    /// shape carries no ambiguity, so it's joined into one label. Anything
    /// messier falls back to a single header row.
    private static func detectHeaderRowCount(_ rows: [[String]]) -> Int {
        guard rows.count >= 3 else { return 1 }
        let first = rows[0]
        let second = rows[1]
        guard first.count == second.count else { return 1 }
        let overlapping = zip(first, second).contains {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
                && !$1.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let secondLooksLikeHeader = second.allSatisfy {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || (t.count <= 40 && Double(t) == nil)
        }
        return (!overlapping && secondLooksLikeHeader) ? 2 : 1
    }

    private static func buildHeaders(from headerRows: [[String]]) -> [String] {
        let width = headerRows.map(\.count).max() ?? 0
        var combined = [String](repeating: "", count: width)
        for row in headerRows {
            for (idx, cell) in row.enumerated() where idx < width {
                let t = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                combined[idx] = combined[idx].isEmpty ? t : "\(combined[idx]) \(t)"
            }
        }
        var seen: [String: Int] = [:]
        return combined.enumerated().map { idx, raw in
            let base = raw.isEmpty ? "column_\(idx + 1)" : normalizeKey(raw)
            let count = seen[base, default: 0] + 1
            seen[base] = count
            return count == 1 ? base : "\(base)_\(count)"
        }
    }

    // MARK: - JSON

    /// A `.json`-tagged item whose text is genuinely valid JSON needs no
    /// extraction at all — it's already exactly the shape this whole
    /// pipeline exists to produce. Re-parsing here rather than trusting
    /// the tag matters: the tagger also assigns `.json` at 0.8 confidence
    /// for merely JSON-*shaped* text that doesn't actually parse, and that
    /// case must fall through to the model, not be forced through here.
    private static func convertJSON(item: ClipboardItem) -> String? {
        guard let text = item.content.plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        if var dict = parsed as? [String: Any] {
            if dict["description"] == nil {
                dict["description"] = "structured JSON data with \(dict.count) top-level field\(dict.count == 1 ? "" : "s")"
            }
            if dict["keywords"] == nil {
                dict["keywords"] = Array(dict.keys.filter { $0 != "description" }.prefix(10))
            }
            return canonicalize(dict)
        }

        if let array = parsed as? [Any], !array.isEmpty {
            let root: [String: Any] = [
                "items": array,
                "item_count": array.count,
                "description": "a JSON array of \(array.count) item\(array.count == 1 ? "" : "s")",
                "keywords": ["json", "array"],
            ]
            return canonicalize(root)
        }

        // A bare JSON scalar (a lone number/string/bool) has nothing to
        // structure — not a failure, just genuinely outside what this
        // converter or the model prompt's own JSON-object contract cover.
        return nil
    }

    // MARK: - Shared

    private static func normalizeKey(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let replaced = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "value" : trimmed
    }

    private static func canonicalize(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }
}
