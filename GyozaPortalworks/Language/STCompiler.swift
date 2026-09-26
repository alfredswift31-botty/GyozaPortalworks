import Foundation

/// Compiles SCL (TIA Portal) and ST (GX Works) block bodies into programs
/// the simulated CPU runs.
nonisolated enum STCompiler {
    /// Compiles one block's body. `program` is nil when there is any error.
    static func compile(_ source: String, resolver: SymbolResolver) -> (program: STProgram?, diagnostics: [Diagnostic]) {
        let units = Array(source.utf16)
        let lexed = STLexer.tokenize(units)
        var parser = STParser(tokens: lexed.tokens, source: units)
        let statements = parser.parseBody()
        let checker = STChecker(resolver: resolver, source: units)
        let body = checker.compileBody(statements)
        let diagnostics = ordered(lexed.diagnostics + parser.diagnostics + checker.diagnostics)
        guard !diagnostics.contains(where: { $0.severity == .error }) else { return (nil, diagnostics) }
        return (STProgram(body: body, trace: checker.makeTrace()), diagnostics)
    }

    /// Sorted by position, without repeats.
    private static func ordered(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        var seen: Set<String> = []
        let unique = diagnostics.enumerated().filter { _, diagnostic in
            seen.insert("\(diagnostic.line ?? 0):\(diagnostic.column ?? 0):\(diagnostic.severity.rawValue):\(diagnostic.message)").inserted
        }
        return unique.sorted { first, second in
            let a = (first.element.line ?? 0, first.element.column ?? 0, first.offset)
            let b = (second.element.line ?? 0, second.element.column ?? 0, second.offset)
            return a < b
        }.map(\.element)
    }
}
