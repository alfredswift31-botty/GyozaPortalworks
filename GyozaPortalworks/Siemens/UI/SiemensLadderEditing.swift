import Foundation
import SwiftUI

/// Where the cursor is in a LAD/FBD block.
nonisolated enum S7Selection: Hashable, Sendable {
    /// The whole network (its title bar).
    case network(UUID)
    /// The start of a path: next to the power rail, or where a branch begins.
    case rail(network: UUID, path: UUID)
    /// An element: contact, coil, box or branch group.
    case element(network: UUID, id: UUID)

    var networkID: UUID {
        switch self {
        case let .network(id), let .rail(id, _), let .element(id, _): return id
        }
    }
}

/// A field of an element that can be edited inline.
nonisolated enum S7OperandField: Hashable, Sendable {
    case slot(S7OperandSlot)
    /// A box pin: IN1, PT, OUT…
    case pin(String)
}

/// The operand being edited inline.
nonisolated struct S7OperandTarget: Hashable, Sendable {
    var network: UUID
    var element: UUID
    var field: S7OperandField
}

/// What the LAD/FBD editor can do, from keys, the Favorites bar or menus.
nonisolated enum S7EditorCommand: Hashable, Sendable {
    case insertContact(S7ContactKind)
    case insertCoil(S7CoilKind)
    case insertEmptyBox
    case insertBox(S7Instruction)
    case openBranch
    case closeBranch
    case delete
    case insertNetwork
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case editOperand
}

/// The result of an editing command on a block.
nonisolated struct S7EditResult {
    var selection: S7Selection?
    /// The element the command created, if any.
    var created: UUID?
    /// Whether the block changed.
    var changed: Bool
}

/// Keyboard, cursor and insertion logic of the LAD/FBD editor, kept free of
/// views so it can be tested.
nonisolated enum S7LadderEditing {
    /// TIA's keys in the LAD editor. Function keys use AppKit's private-use characters (F1 = U+F704).
    static func command(for key: KeyEquivalent, modifiers: EventModifiers) -> S7EditorCommand? {
        let character = key.character
        if modifiers.contains(.shift), let number = functionKeyNumber(character) {
            switch number {
            case 2: return .insertContact(.normallyOpen)
            case 3: return .insertContact(.normallyClosed)
            case 5: return .insertEmptyBox
            case 7: return .insertCoil(.assign)
            case 8: return .openBranch
            case 9: return .closeBranch
            default: return nil
            }
        }
        if modifiers.contains(.control), character == "r" || character == "R" { return .insertNetwork }
        guard modifiers.subtracting([.numericPad, .function]).isEmpty else { return nil }
        if functionKeyNumber(character) == 2 { return .editOperand }
        switch key {
        case .leftArrow: return .moveLeft
        case .rightArrow: return .moveRight
        case .upArrow: return .moveUp
        case .downArrow: return .moveDown
        case .return: return .editOperand
        case .delete, .deleteForward: return .delete
        default: return nil
        }
    }

    /// 1…35 for F1…F35, nil for other keys.
    static func functionKeyNumber(_ character: Character) -> Int? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        let value = Int(scalar.value)
        guard value >= 0xF704, value <= 0xF726 else { return nil }
        return value - 0xF704 + 1
    }

    // MARK: Cursor

    /// Every cursor position of a network in reading order: a path's start,
    /// then its elements; branches follow their group, top to bottom.
    static func stops(in network: S7Network) -> [S7Selection] {
        var result: [S7Selection] = []
        func walk(_ path: S7Path) {
            result.append(.rail(network: network.id, path: path.id))
            for node in path.items {
                result.append(.element(network: network.id, id: node.id))
                switch node {
                case let .parallel(group), let .fanOut(group):
                    for branch in group.branches { walk(branch) }
                default:
                    break
                }
            }
        }
        for rung in network.rungs { walk(rung) }
        return result
    }

    /// The first cursor position of a network.
    static func firstStop(in network: S7Network) -> S7Selection {
        stops(in: network).first ?? .network(network.id)
    }

    /// Moves the cursor: left/right within the network, up/down between networks.
    static func move(_ selection: S7Selection?, _ command: S7EditorCommand, in block: SiemensBlock) -> S7Selection? {
        guard !block.networks.isEmpty else { return nil }
        guard let selection, let networkIndex = block.networks.firstIndex(where: { $0.id == selection.networkID }) else {
            return firstStop(in: block.networks[0])
        }
        let network = block.networks[networkIndex]
        let list = stops(in: network)
        let position = list.firstIndex(of: selection)
        switch command {
        case .moveLeft:
            guard let position else { return list.first }
            return list[max(0, position - 1)]
        case .moveRight:
            guard let position else { return list.first }
            return list[min(list.count - 1, position + 1)]
        case .moveUp:
            if case .network = selection { return networkIndex > 0 ? .network(block.networks[networkIndex - 1].id) : selection }
            return .network(network.id)
        case .moveDown:
            if case .network = selection { return list.first ?? selection }
            guard networkIndex + 1 < block.networks.count else { return selection }
            return .network(block.networks[networkIndex + 1].id)
        default:
            return selection
        }
    }

    // MARK: Editing

    /// Applies an insert, branch or delete command at the selection. Moves
    /// and operand editing are handled by `move` and the view.
    static func apply(_ command: S7EditorCommand, to block: inout SiemensBlock, at selection: S7Selection?) -> S7EditResult {
        if command == .insertNetwork {
            let index = selection.flatMap { current in block.networks.firstIndex { $0.id == current.networkID } }
            let network = block.insertNetwork(after: index)
            return S7EditResult(selection: firstStop(in: network), created: network.id, changed: true)
        }
        guard block.language.usesNetworks else { return S7EditResult(selection: selection, created: nil, changed: false) }
        if block.networks.isEmpty { block.insertNetwork() }
        let current = selection ?? firstStop(in: block.networks[0])
        guard let networkIndex = block.networks.firstIndex(where: { $0.id == current.networkID }) else {
            return S7EditResult(selection: selection, created: nil, changed: false)
        }
        var network = block.networks[networkIndex]
        var result = S7EditResult(selection: current, created: nil, changed: false)
        switch command {
        case let .insertContact(kind):
            result = insert(.contact(S7Contact(kind)), into: &network, at: current, beforeTrailingCoil: true)
        case let .insertCoil(kind):
            result = insert(.coil(S7Coil(kind)), into: &network, at: current, beforeTrailingCoil: false)
        case .insertEmptyBox:
            result = insert(.box(S7Box(.empty)), into: &network, at: current, beforeTrailingCoil: true)
        case let .insertBox(instruction):
            result = insert(.box(S7Box(instruction)), into: &network, at: current, beforeTrailingCoil: true)
        case .openBranch:
            let point = insertionPoint(in: network, at: current, beforeTrailingCoil: false)
            if let branch = network.openBranch(at: point) {
                result = S7EditResult(selection: .rail(network: network.id, path: branch), created: branch, changed: true)
            }
        case .closeBranch:
            result = closeBranch(in: &network, at: current)
        case .delete:
            if case .network = current {
                block.deleteNetwork(at: networkIndex)
                let next = block.networks.isEmpty ? nil : block.networks[min(networkIndex, block.networks.count - 1)]
                return S7EditResult(selection: next.map { .network($0.id) }, created: nil, changed: true)
            }
            result = delete(in: &network, at: current)
        default:
            break
        }
        block.networks[networkIndex] = network
        return result
    }

    /// Where an insert at the selection goes. Contacts and boxes go in front
    /// of a rung's closing coil when the coil is selected, as in TIA.
    static func insertionPoint(in network: S7Network, at selection: S7Selection, beforeTrailingCoil: Bool) -> S7InsertionPoint {
        switch selection {
        case let .rail(_, path):
            return .start(path: path)
        case let .element(_, id):
            if beforeTrailingCoil, let location = network.location(of: id), location.index == location.path.items.count - 1,
               case .coil = location.path.items[location.index] {
                return .before(element: id)
            }
            return .after(element: id)
        case .network:
            guard let rung = network.rungs.first else { return .start(path: UUID()) }
            if let last = rung.items.last {
                if beforeTrailingCoil, case .coil = last { return .before(element: last.id) }
                if case .fanOut = last { return .before(element: last.id) }
                return .after(element: last.id)
            }
            return .start(path: rung.id)
        }
    }

    private static func insert(_ node: S7Node, into network: inout S7Network, at selection: S7Selection,
                               beforeTrailingCoil: Bool) -> S7EditResult {
        if network.rungs.isEmpty { network.rungs = [S7Path()] }
        let point = insertionPoint(in: network, at: selection, beforeTrailingCoil: beforeTrailingCoil)
        if case let .after(id) = point, case .fanOut? = network.element(id) {
            return S7EditResult(selection: selection, created: nil, changed: false)
        }
        guard network.insert(node, at: point) else { return S7EditResult(selection: selection, created: nil, changed: false) }
        return S7EditResult(selection: .element(network: network.id, id: node.id), created: node.id, changed: true)
    }

    private static func closeBranch(in network: inout S7Network, at selection: S7Selection) -> S7EditResult {
        let anchor: UUID
        switch selection {
        case let .rail(_, path): anchor = path
        case let .element(_, id): anchor = id
        case .network: return S7EditResult(selection: selection, created: nil, changed: false)
        }
        guard let open = network.openBranch(containing: anchor), let target = open.main.items.first?.id else {
            return S7EditResult(selection: selection, created: nil, changed: false)
        }
        let closed = network.closeBranch(open.branch, onto: target)
        return S7EditResult(selection: selection, created: nil, changed: closed)
    }

    private static func delete(in network: inout S7Network, at selection: S7Selection) -> S7EditResult {
        let list = stops(in: network)
        let position = list.firstIndex(of: selection) ?? 0
        let fallback = position > 0 ? list[position - 1] : nil
        var changed = false
        switch selection {
        case let .element(_, id):
            changed = network.removeElement(id)
        case let .rail(_, path):
            if !network.rungs.contains(where: { $0.id == path }) || network.rungs.count > 1 {
                changed = network.removeBranch(path)
            }
        case .network:
            break
        }
        guard changed else { return S7EditResult(selection: selection, created: nil, changed: false) }
        let stillThere = fallback.map { stops(in: network).contains($0) } ?? false
        return S7EditResult(selection: stillThere ? fallback : firstStop(in: network), created: nil, changed: true)
    }
}

/// Turns what the user typed at an operand into what TIA shows: an address
/// that belongs to a tag becomes the tag, an unknown address gets a new
/// "Tag_n" in the default tag table, and plain names get their # or quotes.
nonisolated enum SiemensOperandEntry {
    static func resolve(_ rawText: String, block: SiemensBlock, project: inout SiemensProject) -> String {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !S7OperandParser.isLiteral(text) else { return text }
        if text.hasPrefix("#") || text.hasPrefix("\"") {
            return text
        }
        if text.hasPrefix("%") || S7Address.looksLikeAddress(text) {
            let body = text.uppercased().hasSuffix(":P") ? String(text.dropLast(2)) : text
            let suffix = body.count == text.count ? "" : ":P"
            guard let address = try? S7Address.parse(body), !address.isPeripheral else { return text }
            if let existing = project.allTags.first(where: { $0.tag.parsedAddress == address }) {
                return "\"\(existing.tag.name)\"" + suffix
            }
            let name = SiemensTagRules.uniqueName(nextTagName(in: project), in: project.tagTables)
            let type: PLCDataType = address.width.defaultType
            project.addTag(SiemensTag(name, type, address.description))
            return "\"\(name)\"" + suffix
        }
        let name = text.split(separator: ".", maxSplits: 1).first.map(String.init) ?? text
        let rest = String(text.dropFirst(name.count))
        let interfaceNames = block.interface.allNames
        if interfaceNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "#" + name + rest
        }
        let globals = project.allTags.map(\.tag.name) + project.allConstants.map(\.constant.name) + project.dataBlocks.map(\.name)
        if let global = globals.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "\"\(global)\"" + rest
        }
        return text
    }

    /// "Tag_1", "Tag_2"… the next number after the highest Tag_n.
    static func nextTagName(in project: SiemensProject) -> String {
        var highest = 0
        for entry in project.allTags where entry.tag.name.hasPrefix("Tag_") {
            if let number = Int(entry.tag.name.dropFirst(4)) { highest = max(highest, number) }
        }
        return "Tag_\(highest + 1)"
    }

    /// Autocomplete for an operand field: locals first, then tags, data blocks and constants.
    static func suggestions(for rawPrefix: String, block: SiemensBlock, project: SiemensProject, limit: Int = 12) -> [String] {
        var prefix = rawPrefix.trimmingCharacters(in: .whitespaces)
        if prefix.hasPrefix("#") || prefix.hasPrefix("\"") { prefix.removeFirst() }
        let key = prefix.lowercased()
        let locals = block.interface.allNames.map { "#" + $0 }
        let globals = (project.allTags.map(\.tag.name) + project.dataBlocks.map(\.name) + project.allConstants.map(\.constant.name))
            .map { "\"\($0)\"" }
        let candidates = locals + globals
        let matches = candidates.filter { candidate in
            let bare = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "#\"")).lowercased()
            return key.isEmpty || bare.hasPrefix(key)
        }
        return Array(matches.prefix(limit))
    }
}

/// One entry of the Instructions task card.
nonisolated struct S7CatalogEntry: Hashable, Identifiable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case contact(S7ContactKind, S7Comparison?)
        case coil(S7CoilKind)
        case box(S7Instruction)
        case openBranch
        case closeBranch
    }

    var id: String
    var title: String
    var kind: Kind
}

/// A folder of the Instructions task card.
nonisolated struct S7CatalogFolder: Hashable, Identifiable, Sendable {
    var id: String { title }
    var title: String
    var entries: [S7CatalogEntry]
}

/// The Instructions task card, in TIA's folder order (Basic instructions),
/// limited to what this simulator runs.
nonisolated enum S7InstructionCatalog {
    static let favorites: [S7CatalogEntry] = [
        S7CatalogEntry(id: "fav-no", title: "-| |-", kind: .contact(.normallyOpen, nil)),
        S7CatalogEntry(id: "fav-nc", title: "-|/|-", kind: .contact(.normallyClosed, nil)),
        S7CatalogEntry(id: "fav-coil", title: "-( )-", kind: .coil(.assign)),
        S7CatalogEntry(id: "fav-box", title: "??", kind: .box(.empty)),
        S7CatalogEntry(id: "fav-open", title: "Open branch", kind: .openBranch),
        S7CatalogEntry(id: "fav-close", title: "Close branch", kind: .closeBranch),
    ]

    static var basicInstructions: [S7CatalogFolder] {
        func box(_ instruction: S7Instruction) -> S7CatalogEntry {
            S7CatalogEntry(id: "box-" + instruction.rawValue, title: instruction.rawValue, kind: .box(instruction))
        }
        let bitLogic: [S7CatalogEntry] = [
            S7CatalogEntry(id: "no", title: "-| |-  Normally open contact", kind: .contact(.normallyOpen, nil)),
            S7CatalogEntry(id: "nc", title: "-|/|-  Normally closed contact", kind: .contact(.normallyClosed, nil)),
            S7CatalogEntry(id: "not", title: "-|NOT|-  Invert RLO", kind: .contact(.invert, nil)),
            S7CatalogEntry(id: "coil", title: "-( )-  Assignment", kind: .coil(.assign)),
            S7CatalogEntry(id: "ncoil", title: "-(/)-  Negate assignment", kind: .coil(.negate)),
            S7CatalogEntry(id: "set", title: "-(S)-  Set output", kind: .coil(.set)),
            S7CatalogEntry(id: "reset", title: "-(R)-  Reset output", kind: .coil(.reset)),
            S7CatalogEntry(id: "setbf", title: "SET_BF  Set bit field", kind: .coil(.setBitField)),
            S7CatalogEntry(id: "resetbf", title: "RESET_BF  Reset bit field", kind: .coil(.resetBitField)),
            box(.setReset), box(.resetSet),
            S7CatalogEntry(id: "p", title: "-|P|-  Scan operand for positive signal edge", kind: .contact(.positiveEdge, nil)),
            S7CatalogEntry(id: "n", title: "-|N|-  Scan operand for negative signal edge", kind: .contact(.negativeEdge, nil)),
            S7CatalogEntry(id: "pcoil", title: "-(P)-  Set operand on positive signal edge", kind: .coil(.positiveEdge)),
            S7CatalogEntry(id: "ncoilEdge", title: "-(N)-  Set operand on negative signal edge", kind: .coil(.negativeEdge)),
            box(.positiveEdgeBox), box(.negativeEdgeBox), box(.risingEdgeTrigger), box(.fallingEdgeTrigger),
        ]
        let timers: [S7CatalogEntry] = [
            box(.pulseTimer), box(.onDelayTimer), box(.offDelayTimer), box(.accumulatingTimer),
            S7CatalogEntry(id: "tpcoil", title: "-(TP)-  Start pulse timer", kind: .coil(.pulseTimer)),
            S7CatalogEntry(id: "toncoil", title: "-(TON)-  Start on-delay timer", kind: .coil(.onDelayTimer)),
            S7CatalogEntry(id: "tofcoil", title: "-(TOF)-  Start off-delay timer", kind: .coil(.offDelayTimer)),
            S7CatalogEntry(id: "tonrcoil", title: "-(TONR)-  Time accumulator", kind: .coil(.accumulatingTimer)),
            S7CatalogEntry(id: "rt", title: "-(RT)-  Reset timer", kind: .coil(.resetTimer)),
            S7CatalogEntry(id: "pt", title: "-(PT)-  Load time duration", kind: .coil(.presetTimer)),
        ]
        let comparators = S7Comparison.allCases.map {
            S7CatalogEntry(id: "cmp" + $0.rawValue, title: $0.label, kind: .contact(.compare, $0))
        } + [box(.inRange), box(.outOfRange)]
        let math: [S7Instruction] = [.calculate, .add, .subtract, .multiply, .divide, .modulo, .negate, .increment, .decrement,
                                     .absolute, .minimum, .maximum, .limit, .square, .squareRoot, .naturalLogarithm, .exponential,
                                     .sine, .cosine, .tangent, .arcSine, .arcCosine, .arcTangent, .fraction, .power]
        return [
            S7CatalogFolder(title: "Bit logic operations", entries: bitLogic),
            S7CatalogFolder(title: "Timer operations", entries: timers),
            S7CatalogFolder(title: "Counter operations", entries: [box(.countUp), box(.countDown), box(.countUpDown)]),
            S7CatalogFolder(title: "Comparator operations", entries: comparators),
            S7CatalogFolder(title: "Math functions", entries: math.map(box)),
            S7CatalogFolder(title: "Move operations", entries: [box(.move)]),
            S7CatalogFolder(title: "Conversion operations",
                            entries: [box(.convert), box(.round), box(.ceiling), box(.floor), box(.truncate), box(.scale), box(.normalize)]),
            S7CatalogFolder(title: "Word logic operations", entries: [box(.wordAnd), box(.wordOr), box(.wordXor), box(.invert)]),
            S7CatalogFolder(title: "Shift and rotate",
                            entries: [box(.shiftRight), box(.shiftLeft), box(.rotateRight), box(.rotateLeft)]),
        ]
    }

    /// An entry by id (drag and drop carries the id).
    static func entry(id: String) -> S7CatalogEntry? {
        (favorites + basicInstructions.flatMap(\.entries)).first { $0.id == id }
    }

    /// Entries whose title contains the search text.
    static func search(_ text: String) -> [S7CatalogEntry] {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return [] }
        return basicInstructions.flatMap(\.entries).filter { $0.title.lowercased().contains(key) }
    }

    /// The node an entry inserts; nil for the branch commands.
    static func command(for entry: S7CatalogEntry) -> S7EditorCommand {
        switch entry.kind {
        case let .contact(kind, _): return .insertContact(kind)
        case let .coil(kind): return .insertCoil(kind)
        case let .box(instruction): return instruction == .empty ? .insertEmptyBox : .insertBox(instruction)
        case .openBranch: return .openBranch
        case .closeBranch: return .closeBranch
        }
    }
}
