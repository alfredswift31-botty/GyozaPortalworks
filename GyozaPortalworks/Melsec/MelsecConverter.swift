import Foundation

/// A conversion error at a ladder cell (all 0-based; the UI shows +1).
nonisolated struct MelsecConversionError: Hashable, Sendable {
    /// Index of the ladder block.
    var block: Int
    var row: Int
    var column: Int
    var message: String
}

/// Where a ladder block starts in the program, for the step numbers shown
/// at the left of the ladder.
nonisolated struct MelsecBlockStep: Hashable, Sendable {
    var rows: Range<Int>
    var step: Int
}

/// The outcome of Convert (F4) / Rebuild All for one ladder program.
nonisolated struct MelsecConversionResult: Hashable, Sendable {
    var program: MelsecILProgram
    var errors: [MelsecConversionError]
    /// Ladder cell → indices into `program.instructions` (a cell shared by
    /// several outputs can appear more than once).
    var cellInstructions: [MelsecCellRef: [Int]]
    var blockSteps: [MelsecBlockStep]
    /// The step number of END.
    var endStep: Int

    var succeeded: Bool { errors.isEmpty }

    /// Conversion Result window: Step | Code.
    func listing(_ profile: MelsecCPUProfile) -> [MelsecListingLine] {
        program.listing(profile)
    }
}

/// A block's logic as a series/parallel expression over ladder cells.
nonisolated indirect enum MelsecLogicExpression: Hashable, Sendable {
    case element(MelsecCellRef)
    case series([MelsecLogicExpression])
    case parallel([MelsecLogicExpression])

    /// The upper-left cell, for ordering branches top to bottom.
    var topCell: MelsecCellRef {
        switch self {
        case let .element(cell):
            return cell
        case let .series(items), let .parallel(items):
            return items.map(\.topCell).min() ?? MelsecCellRef(row: 0, column: 0)
        }
    }

    static func joinSeries(_ first: MelsecLogicExpression, _ second: MelsecLogicExpression) -> MelsecLogicExpression {
        var items: [MelsecLogicExpression] = []
        for part in [first, second] {
            if case let .series(inner) = part { items += inner } else { items.append(part) }
        }
        return .series(items)
    }

    static func joinParallel(_ parts: [MelsecLogicExpression]) -> MelsecLogicExpression {
        var branches: [MelsecLogicExpression] = []
        for part in parts {
            if case let .parallel(inner) = part { branches += inner } else { branches.append(part) }
        }
        return .parallel(branches.sorted { $0.topCell < $1.topCell })
    }

    /// Top-level series items.
    var seriesItems: [MelsecLogicExpression] {
        if case let .series(items) = self { return items }
        return [self]
    }
}

/// Converts a ladder into its instruction list, the way GX Works3's
/// Convert (F4) does: AND/OR for series and parallel contacts, ANB/ORB for
/// blocks, MPS/MRD/MPP where outputs branch off a shared condition.
nonisolated enum MelsecConverter {
    static func convert(_ ladder: MelsecLadder, scope: MelsecLabelScope = MelsecLabelScope(),
                        profile: MelsecCPUProfile = .fx5u) -> MelsecConversionResult {
        var builder = MelsecConversionBuilder(ladder: ladder, scope: scope, profile: profile)
        for (index, rows) in ladder.blocks().enumerated() {
            builder.convertBlock(index, rows: rows)
        }
        return builder.finish()
    }
}

/// An edge of a block's circuit graph: a contact from node `from` to `to`.
nonisolated private struct MelsecCircuitEdge: Hashable {
    var from: Int
    var to: Int
    var expression: MelsecLogicExpression
}

/// One entry of an output trie node: an output, or a child node.
nonisolated private enum MelsecTrieEntry: Hashable {
    case output(MelsecCellRef)
    case child(Int)

    var isChild: Bool {
        if case .child = self { return true }
        return false
    }
}

nonisolated private struct MelsecTrieNode: Hashable {
    var item: MelsecLogicExpression?
    var entries: [MelsecTrieEntry] = []
}

nonisolated private struct MelsecConversionBuilder {
    let ladder: MelsecLadder
    let scope: MelsecLabelScope
    let profile: MelsecCPUProfile
    var instructions: [MelsecInstruction] = []
    var errors: [MelsecConversionError] = []
    var blockStarts: [(rows: Range<Int>, index: Int)] = []
    /// Parsed instruction per cell of the current block.
    var cellInstructions: [MelsecCellRef: MelsecInstruction] = [:]
    var blockIndex = 0

    init(ladder: MelsecLadder, scope: MelsecLabelScope, profile: MelsecCPUProfile) {
        self.ladder = ladder
        self.scope = scope
        self.profile = profile
    }

    private mutating func fail(_ cell: MelsecCellRef, _ message: String) {
        errors.append(MelsecConversionError(block: blockIndex, row: cell.row, column: cell.column, message: message))
    }

    // MARK: Block

    mutating func convertBlock(_ index: Int, rows: Range<Int>) {
        blockIndex = index
        cellInstructions = [:]
        let errorCount = errors.count
        let columns = MelsecLadder.columnCount
        let width = columns + 1

        // 1. Elements and their operands.
        var outputs: [MelsecCellRef] = []
        var connectors: [MelsecCellRef] = []
        var lines: [MelsecCellRef] = []
        for row in rows {
            for column in 0..<columns {
                let cell = MelsecCellRef(row: row, column: column)
                let element = ladder.rows[row].cells[column]
                switch element {
                case .empty:
                    continue
                case .line:
                    if column == MelsecLadder.coilColumn {
                        fail(cell, "A line cannot be placed in the coil column.")
                    } else {
                        lines.append(cell)
                    }
                    continue
                case .output:
                    if column != MelsecLadder.coilColumn {
                        fail(cell, "A coil or instruction must be placed at the right end of the ladder.")
                        continue
                    }
                    outputs.append(cell)
                default:
                    if column == MelsecLadder.coilColumn {
                        fail(cell, "A contact cannot be placed in the coil column.")
                        continue
                    }
                    connectors.append(cell)
                }
                parseElement(element, at: cell)
            }
        }
        if outputs.isEmpty, let first = (connectors + lines).min() {
            fail(first, "The ladder block is not complete: it has no coil or instruction.")
        }

        // 2. The circuit graph: nodes are (row, boundary) points merged by lines.
        let first = rows.lowerBound
        func node(_ row: Int, _ boundary: Int) -> Int { (row - first) * width + boundary }
        var parent = Array(0..<(rows.count * width))
        func find(_ value: Int) -> Int {
            var current = value
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
        }
        for row in rows {
            union(node(row, 0), node(first, 0))
        }
        for cell in lines {
            union(node(cell.row, cell.column), node(cell.row, cell.column + 1))
        }
        var verticals: [MelsecCellRef] = []
        for row in rows {
            for boundary in 1..<columns where ladder.rows[row].verticalLines[boundary] {
                let cell = MelsecCellRef(row: row, column: boundary)
                if row + 1 < rows.upperBound {
                    union(node(row, boundary), node(row + 1, boundary))
                    verticals.append(cell)
                } else {
                    fail(cell, "The vertical line below row \(row + 1) is not connected (open branch).")
                }
            }
        }
        let left = find(node(first, 0))
        let edges: [MelsecCircuitEdge] = connectors.map { cell in
            MelsecCircuitEdge(from: find(node(cell.row, cell.column)), to: find(node(cell.row, cell.column + 1)),
                              expression: .element(cell))
        }
        let sinks: [MelsecCellRef: Int] = Dictionary(uniqueKeysWithValues: outputs.map { ($0, find(node($0.row, $0.column))) })

        // 3. Connectivity checks.
        let forward = reach(from: [left], edges: edges, forward: true)
        let backward = reach(from: Set(sinks.values), edges: edges, forward: false)
        for edge in edges {
            guard case let .element(cell) = edge.expression else { continue }
            if edge.from == edge.to {
                fail(cell, "The contact at row \(cell.row + 1), column \(cell.column + 1) is short-circuited by a line.")
            } else if !forward.contains(edge.from) {
                fail(cell, "The contact at row \(cell.row + 1), column \(cell.column + 1) is not connected to the left bus.")
            } else if !backward.contains(edge.to) {
                fail(cell, "The circuit after row \(cell.row + 1), column \(cell.column + 1) does not lead to a coil (open branch).")
            }
        }
        for cell in lines {
            let group = find(node(cell.row, cell.column))
            if !forward.contains(group) || !backward.contains(group) {
                fail(cell, "The line at row \(cell.row + 1), column \(cell.column + 1) is not connected (open branch).")
            }
        }
        for cell in verticals {
            let group = find(node(cell.row, cell.column))
            if !forward.contains(group) || !backward.contains(group) {
                fail(cell, "The vertical line at row \(cell.row + 1), column \(cell.column + 1) is not connected (open branch).")
            }
        }
        for cell in outputs {
            guard let sink = sinks[cell], let instruction = cellInstructions[cell] else { continue }
            let unconditional = instruction.definition.isUnconditional
            if sink == left {
                if !unconditional {
                    fail(cell, "\(instruction.mnemonic) is connected directly to the left bus: add a contact (e.g. SM400) in front of it.")
                }
            } else if unconditional {
                fail(cell, "\(instruction.mnemonic) must be connected directly to the left bus.")
            } else if !forward.contains(sink) {
                let fed = edges.contains { $0.to == sink } || lines.contains { find(node($0.row, $0.column)) == sink }
                fail(cell, fed
                     ? "The \(instruction.mnemonic) at row \(cell.row + 1) is not connected to the left bus."
                     : "There is a gap before the \(instruction.mnemonic) at row \(cell.row + 1): connect it with a line.")
            }
        }
        guard errors.count == errorCount else { return }

        // 4. Each output's condition as a series/parallel expression.
        var chains: [(cell: MelsecCellRef, items: [MelsecLogicExpression])] = []
        for cell in outputs.sorted() {
            guard let sink = sinks[cell] else { continue }
            if sink == left {
                chains.append((cell, []))
                continue
            }
            let toSink = reach(from: [sink], edges: edges, forward: false)
            let relevant = edges.filter { forward.contains($0.from) && toSink.contains($0.to) }
            guard let expression = reduce(relevant, source: left, sink: sink) else {
                fail(cell, "This ladder cannot be converted: the circuit before row \(cell.row + 1) is not a combination of series and parallel connections (e.g. a bridge). Redraw it.")
                return
            }
            chains.append((cell, expression.seriesItems))
        }

        // 5. Instructions.
        blockStarts.append((rows, instructions.count))
        if let pointer = ladder.rows[rows.lowerBound].pointer {
            instructions.append(MelsecInstruction(MelsecInstructionSet.pointerLabel, [.pointer(pointer)]))
        }
        var nodes = [MelsecTrieNode(item: nil)]
        for chain in chains {
            var current = 0
            for item in chain.items {
                var next: Int?
                for entry in nodes[current].entries {
                    if case let .child(child) = entry, nodes[child].item == item {
                        next = child
                        break
                    }
                }
                if let next {
                    current = next
                } else {
                    nodes.append(MelsecTrieNode(item: item))
                    nodes[current].entries.append(.child(nodes.count - 1))
                    current = nodes.count - 1
                }
            }
            nodes[current].entries.append(.output(chain.cell))
        }
        for entry in nodes[0].entries {
            switch entry {
            case let .output(cell):
                emitOutput(cell)
            case let .child(child):
                if let item = nodes[child].item {
                    emitLoad(item)
                }
                emitEntries(of: child, nodes: nodes)
            }
        }
    }

    private mutating func parseElement(_ element: MelsecLadderElement, at cell: MelsecCellRef) {
        let mnemonic: String
        switch element {
        case let .contact(kind, _): mnemonic = kind.mnemonic(.load)
        case let .comparison(op, width, _): mnemonic = "LD" + width.prefix + op.rawValue
        case let .operationResult(kind): mnemonic = kind.rawValue
        case let .output(name, _): mnemonic = name
        case .empty, .line: return
        }
        guard let definition = MelsecInstructionSet.definition(mnemonic) else {
            fail(cell, "'\(mnemonic)': the instruction does not exist.")
            return
        }
        if element.isOutput {
            if definition.kind == .end {
                fail(cell, "END is always the last block of the program and cannot be entered.")
                return
            }
            if !definition.isOutput {
                fail(cell, "\(definition.mnemonic) cannot be placed in the coil column.")
                return
            }
        }
        let result = MelsecOperandChecker.operands(for: definition, texts: element.operands, scope: scope, profile: profile)
        for problem in result.problems {
            fail(cell, problem)
        }
        cellInstructions[cell] = MelsecInstruction(definition, result.operands, cell: cell)
    }

    private func reach(from start: Set<Int>, edges: [MelsecCircuitEdge], forward: Bool) -> Set<Int> {
        var seen = start
        var stack = Array(start)
        while let current = stack.popLast() {
            for edge in edges {
                let (from, to) = forward ? (edge.from, edge.to) : (edge.to, edge.from)
                if from == current, !seen.contains(to) {
                    seen.insert(to)
                    stack.append(to)
                }
            }
        }
        return seen
    }

    /// Series/parallel reduction of the two-terminal graph from `source` to
    /// `sink`; nil when the graph is not series-parallel.
    private func reduce(_ input: [MelsecCircuitEdge], source: Int, sink: Int) -> MelsecLogicExpression? {
        var edges = input
        guard !edges.contains(where: { $0.from == $0.to }) else { return nil }
        var changed = true
        while changed {
            changed = false
            // Parallel edges between the same two nodes.
            var grouped: [MelsecCircuitEdge] = []
            var merged = false
            var used = Array(repeating: false, count: edges.count)
            for index in edges.indices where !used[index] {
                var group = [edges[index].expression]
                for other in (index + 1)..<edges.count where !used[other]
                    && edges[other].from == edges[index].from && edges[other].to == edges[index].to {
                    group.append(edges[other].expression)
                    used[other] = true
                }
                used[index] = true
                if group.count > 1 {
                    merged = true
                    grouped.append(MelsecCircuitEdge(from: edges[index].from, to: edges[index].to,
                                                     expression: MelsecLogicExpression.joinParallel(group)))
                } else {
                    grouped.append(edges[index])
                }
            }
            edges = grouped
            if merged { changed = true }
            // Series: a node with exactly one edge in and one edge out.
            var nodes = Set(edges.map(\.from)).union(edges.map(\.to))
            nodes.remove(source)
            nodes.remove(sink)
            for node in nodes.sorted() {
                let incoming = edges.indices.filter { edges[$0].to == node }
                let outgoing = edges.indices.filter { edges[$0].from == node }
                guard incoming.count == 1, outgoing.count == 1, let inIndex = incoming.first, let outIndex = outgoing.first,
                      inIndex != outIndex else { continue }
                let joined = MelsecCircuitEdge(from: edges[inIndex].from, to: edges[outIndex].to,
                                               expression: MelsecLogicExpression.joinSeries(edges[inIndex].expression, edges[outIndex].expression))
                edges = edges.indices.filter { $0 != inIndex && $0 != outIndex }.map { edges[$0] } + [joined]
                if joined.from == joined.to { return nil }
                changed = true
                break
            }
        }
        guard edges.count == 1, let only = edges.first, only.from == source, only.to == sink else { return nil }
        return only.expression
    }

    // MARK: Emission

    private mutating func emitEntries(of index: Int, nodes: [MelsecTrieNode]) {
        let entries = nodes[index].entries
        var pushed = false
        for position in entries.indices {
            if position > 0, entries[position - 1].isChild {
                // Another restore follows if a later entry comes after a child.
                let moreRestores = ((position + 1)..<entries.count).contains { entries[$0 - 1].isChild }
                emitStack(moreRestores ? "MRD" : "MPP")
                if !moreRestores { pushed = false }
            }
            switch entries[position] {
            case let .output(cell):
                emitOutput(cell)
            case let .child(child):
                if !pushed, position < entries.count - 1 {
                    emitStack("MPS")
                    pushed = true
                }
                if let item = nodes[child].item {
                    emitAnd(item)
                }
                emitEntries(of: child, nodes: nodes)
            }
        }
    }

    private mutating func emitStack(_ mnemonic: String) {
        guard let definition = MelsecInstructionSet.definition(mnemonic) else { return }
        instructions.append(MelsecInstruction(definition))
    }

    private mutating func emitOutput(_ cell: MelsecCellRef) {
        guard let instruction = cellInstructions[cell] else { return }
        instructions.append(instruction)
    }

    private mutating func emitLoad(_ expression: MelsecLogicExpression) {
        switch expression {
        case let .element(cell):
            emitElement(cell, position: .load)
        case let .series(items):
            guard let head = items.first else { return }
            emitLoad(head)
            for item in items.dropFirst() {
                emitAnd(item)
            }
        case let .parallel(branches):
            guard let head = branches.first else { return }
            emitLoad(head)
            for branch in branches.dropFirst() {
                emitOr(branch)
            }
        }
    }

    private mutating func emitAnd(_ expression: MelsecLogicExpression) {
        switch expression {
        case let .element(cell):
            emitElement(cell, position: .and)
        case let .series(items):
            for item in items {
                emitAnd(item)
            }
        case .parallel:
            emitLoad(expression)
            emitStack("ANB")
        }
    }

    private mutating func emitOr(_ expression: MelsecLogicExpression) {
        if case let .element(cell) = expression {
            emitElement(cell, position: .or)
            return
        }
        emitLoad(expression)
        emitStack("ORB")
    }

    /// A contact, comparison or INV/MEP/MEF in the given position.
    private mutating func emitElement(_ cell: MelsecCellRef, position: MelsecLogicPosition) {
        guard let parsed = cellInstructions[cell] else { return }
        let mnemonic: String
        switch parsed.definition.kind {
        case let .contact(kind, _):
            mnemonic = kind.mnemonic(position)
        case let .comparison(op, width, _):
            mnemonic = position.rawValue + width.prefix + op.rawValue
        case .operationResult:
            guard position == .and else {
                fail(cell, "\(parsed.mnemonic) must follow a contact: it cannot start a line or form a branch on its own.")
                return
            }
            mnemonic = parsed.mnemonic
        default:
            return
        }
        guard let definition = MelsecInstructionSet.definition(mnemonic) else { return }
        instructions.append(MelsecInstruction(definition, parsed.operands, cell: cell))
    }

    // MARK: Result

    func finish() -> MelsecConversionResult {
        var all = errors.isEmpty ? instructions : []
        if errors.isEmpty {
            if let pointer = ladder.endPointer {
                all.append(MelsecInstruction(MelsecInstructionSet.pointerLabel, [.pointer(pointer)]))
            }
            if let end = MelsecInstructionSet.definition("END") {
                all.append(MelsecInstruction(end))
            }
        }
        let program = MelsecILProgram(all)
        let steps = program.stepNumbers
        var map: [MelsecCellRef: [Int]] = [:]
        for (index, instruction) in all.enumerated() {
            if let cell = instruction.cell {
                map[cell, default: []].append(index)
            }
        }
        let blockSteps = errors.isEmpty
            ? blockStarts.map { MelsecBlockStep(rows: $0.rows, step: steps[min($0.index, steps.count - 1)]) }
            : []
        let endIndex = max(0, all.count - 1)
        return MelsecConversionResult(program: program, errors: errors, cellInstructions: map, blockSteps: blockSteps,
                                      endStep: steps.indices.contains(endIndex) ? steps[endIndex] : 0)
    }
}
