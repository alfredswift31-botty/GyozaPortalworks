import Foundation

/// TIA Portal's SCL editor auto-correction: `#` before interface names,
/// quotes around global tag names, upper-case keywords and instruction
/// names. Comments, literals and REGION names stay as they are. GX Works
/// doesn't rewrite code, so MELSEC source is returned unchanged.
nonisolated enum STFormatter {
    static func canonicalize(_ source: String, resolver: SymbolResolver) -> String {
        guard resolver.dialect == .siemens else { return source }
        let units = Array(source.utf16)
        let tokens = STLexer.tokenize(units).tokens
        let significant = tokens.filter { $0.kind != .comment }
        var replacements: [(range: STSourceRange, text: String)] = []
        var depth = 0
        for (index, token) in significant.enumerated() {
            let previous = index > 0 ? significant[index - 1].kind : nil
            let next = index + 1 < significant.count ? significant[index + 1].kind : nil
            switch token.kind {
            case .symbol(.leftParen):
                depth += 1
            case .symbol(.rightParen):
                depth = max(0, depth - 1)
            case .keyword:
                let upper = token.text.uppercased()
                if upper != token.text { replacements.append((token.range, upper)) }
            case .identifier:
                guard previous != .symbol(.dot) else { continue }
                let isParameterName = depth > 0 && (previous == .symbol(.leftParen) || previous == .symbol(.comma))
                    && (next == .symbol(.assign) || next == .symbol(.output))
                guard !isParameterName, let text = corrected(token.text, isCall: next == .symbol(.leftParen), resolver: resolver),
                      text != token.text
                else { continue }
                replacements.append((token.range, text))
            default:
                break
            }
        }
        guard !replacements.isEmpty else { return source }
        var result: [UInt16] = []
        result.reserveCapacity(units.count + replacements.count * 2)
        var position = 0
        for replacement in replacements {
            result += units[position..<replacement.range.start.offset]
            result += Array(replacement.text.utf16)
            position = replacement.range.end.offset
        }
        result += units[position...]
        return String(decoding: result, as: UTF16.self)
    }

    /// How TIA writes a bare name, or nil to leave it.
    private static func corrected(_ name: String, isCall: Bool, resolver: SymbolResolver) -> String? {
        if name.caseInsensitiveCompare("ENO") == .orderedSame { return "ENO" }
        if STChecker.isPlaceholder(name) { return nil }
        if isCall {
            if let function = STStandardLibrary.function(named: name) { return function.name }
            if resolver.procedure(named: name) != nil { return nil }
            if let block = resolver.userBlock(named: name) { return "\"\(block.name)\"" }
        }
        if resolver.block.localBinding(name) != nil { return "#" + name }
        let binding: SymbolBinding?
        do {
            binding = try resolver.resolve(.plain(name))
        } catch {
            return nil
        }
        switch binding {
        case .local?: return "#" + name
        case .global?, .constant?: return "\"\(name)\""
        case nil: return nil
        }
    }
}
