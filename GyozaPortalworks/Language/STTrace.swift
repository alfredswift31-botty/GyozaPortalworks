import Foundation

/// One monitored value: an operand as written and its last value.
nonisolated struct STTraceEntry: Hashable {
    var line: Int
    /// 1-based, in UTF-16 code units.
    var column: Int
    /// In UTF-16 code units.
    var length: Int
    /// The operand as written (`#speed`, `"DB".values[#i]`), or for a
    /// condition entry the keyword (`IF`, `ELSIF`, `WHILE`, `UNTIL`, `CASE`).
    var text: String
    var value: PLCValue
    /// The value as the monitor shows it: TRUE, 12, 16#00FF, T#1S_500MS, 12.5.
    var display: String
}

/// A place in the source the program records values for; fixed at compile time.
nonisolated struct STTraceSite: Hashable, Sendable {
    var line: Int
    var column: Int
    var length: Int
    var text: String
    var type: PLCDataType
}

/// What the last monitored execution of a program did. The editor reads it
/// after each scan: values stay from earlier scans, and `executedLines`
/// tells which lines ran this time (the others are shown dimmed).
///
/// Condition entries: each executed IF / ELSIF / WHILE / UNTIL records the
/// condition result on its keyword, and CASE records the selector value.
nonisolated final class STTrace {
    /// Lines (1-based) holding a statement that ran during the last monitored call.
    var executedLines: Set<Int> = []
    private let sites: [STTraceSite]
    private var values: [PLCValue?]
    private let sitesByLine: [Int: [Int]]

    init(sites: [STTraceSite]) {
        self.sites = sites
        values = Array(repeating: nil, count: sites.count)
        var byLine: [Int: [Int]] = [:]
        for (index, site) in sites.enumerated() {
            byLine[site.line, default: []].append(index)
        }
        sitesByLine = byLine.mapValues { indices in
            indices.sorted { sites[$0].column != sites[$1].column ? sites[$0].column < sites[$1].column : sites[$0].length > sites[$1].length }
        }
    }

    /// Monitor entries for one line, in source order.
    func entries(line: Int) -> [STTraceEntry] {
        (sitesByLine[line] ?? []).compactMap(entry)
    }

    /// All entries with a value, in source order.
    var allEntries: [STTraceEntry] {
        sitesByLine.keys.sorted().flatMap { entries(line: $0) }
    }

    /// Forgets all recorded values and lines (e.g. after a download).
    func reset() {
        executedLines.removeAll()
        values = Array(repeating: nil, count: sites.count)
    }

    func record(_ site: Int, _ value: PLCValue) {
        values[site] = value
    }

    func markExecuted(_ lines: ClosedRange<Int>) {
        for line in lines {
            executedLines.insert(line)
        }
    }

    private func entry(_ index: Int) -> STTraceEntry? {
        guard let value = values[index] else { return nil }
        let site = sites[index]
        return STTraceEntry(line: site.line, column: site.column, length: site.length, text: site.text,
                            value: value, display: value.formatted(as: site.type))
    }
}
