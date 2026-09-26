import Foundation

/// What a resolver can additionally tell the Siemens compilers about tags and
/// absolute operands: the address behind them and direct I/O access (":P").
nonisolated protocol S7AddressResolving: AnyObject {
    /// The address and type of a PLC tag or an absolute operand; nil for anything else.
    func address(of name: SymbolName) -> (address: S7Address, type: PLCDataType)?
    /// `"Tag":P` or `%I0.0:P`: the tag's or address's I/O. nil when the name isn't a tag.
    func resolvePeripheral(_ name: SymbolName) throws -> GlobalSymbol?
    /// A cell for any absolute address (SET_BF/RESET_BF walk bit by bit).
    func cell(for address: S7Address, type: PLCDataType) -> Cell?
}

/// Operand text split into its parts: `"Motor_DB".Speed`, `#values[#i]`,
/// `%I0.0:P`, `"Word".%X3`.
nonisolated struct S7OperandPath: Hashable, Sendable {
    nonisolated indirect enum Index: Hashable, Sendable {
        case constant(Int)
        case operand(S7OperandPath)
    }

    nonisolated enum Accessor: Hashable, Sendable {
        case member(String)
        case index(Index)
        /// `.%X3`, `.%B1`, `.%W0`, `.%D0`.
        case slice(width: Int, index: Int)
    }

    var root: SymbolName
    var accessors: [Accessor]
    var isPeripheral: Bool

    /// Normalized text, as TIA shows the operand: `"Motor".Speed`, `#x[3]`.
    var text: String {
        var result: String
        switch root {
        case let .local(name): result = "#" + S7OperandPath.quotedIfNeeded(name)
        case let .global(name): result = "\"\(name)\""
        case let .plain(name): result = S7Address.looksLikeAddress(name) ? "%" + name.uppercased() : "\"\(name)\""
        case let .absolute(name): result = name.uppercased()
        }
        for accessor in accessors {
            switch accessor {
            case let .member(name): result += "." + S7OperandPath.quotedIfNeeded(name)
            case let .index(.constant(value)): result += "[\(value)]"
            case let .index(.operand(path)): result += "[\(path.text)]"
            case let .slice(width, index):
                let letter = width == 1 ? "X" : width == 8 ? "B" : width == 16 ? "W" : "D"
                result += ".%\(letter)\(index)"
            }
        }
        if isPeripheral { result += ":P" }
        return result
    }

    private static func quotedIfNeeded(_ name: String) -> String {
        let plain = name.first.map { $0.isLetter || $0 == "_" } ?? false
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return plain ? name : "\"\(name)\""
    }
}

/// Parses LAD/FBD operand text.
nonisolated enum S7OperandParser {
    /// A literal (TRUE, 5, T#5S, 16#FF, 2.5, INT#5) as opposed to a tag or address.
    static func isLiteral(_ rawText: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return false }
        let upper = text.uppercased()
        if upper == "TRUE" || upper == "FALSE" { return true }
        if first.isNumber || first == "+" || first == "-" { return true }
        if let hash = upper.firstIndex(of: "#") {
            let prefix = String(upper[..<hash])
            let known = ["T", "TIME", "LT", "LTIME", "S5T", "S5TIME", "D", "DATE", "TOD", "TIME_OF_DAY", "DT", "C", "B", "W", "DW"]
            return known.contains(prefix) || PLCDataType.named(prefix) != nil
        }
        return false
    }

    static func parse(_ rawText: String) throws -> S7OperandPath {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        var cursor = Cursor(Array(text), original: text)
        let path = try cursor.operand()
        guard cursor.isAtEnd else { throw ResolveError(message: S7Messages.invalidOperand(text)) }
        return path
    }

    private struct Cursor {
        let characters: [Character]
        let original: String
        var position = 0

        init(_ characters: [Character], original: String) {
            self.characters = characters
            self.original = original
        }

        var isAtEnd: Bool { position >= characters.count }
        var current: Character? { position < characters.count ? characters[position] : nil }

        func peek(_ offset: Int) -> Character? {
            position + offset < characters.count ? characters[position + offset] : nil
        }

        func invalid() -> ResolveError {
            ResolveError(message: S7Messages.invalidOperand(original))
        }

        mutating func identifier() -> String {
            var name = ""
            while let character = current, character.isLetter || character.isNumber || character == "_" {
                name.append(character)
                position += 1
            }
            return name
        }

        mutating func quoted() throws -> String {
            position += 1
            var name = ""
            while let character = current, character != "\"" {
                name.append(character)
                position += 1
            }
            guard current == "\"" else { throw invalid() }
            position += 1
            guard !name.isEmpty else { throw invalid() }
            return name
        }

        mutating func digits() -> String {
            var text = ""
            while let character = current, character.isASCIIDigitCharacter {
                text.append(character)
                position += 1
            }
            return text
        }

        mutating func operand() throws -> S7OperandPath {
            guard let first = current else { throw ResolveError(message: S7Messages.operandMissing) }
            let root: SymbolName
            switch first {
            case "#":
                position += 1
                if current == "\"" {
                    root = .local(try quoted())
                } else {
                    let name = identifier()
                    guard !name.isEmpty else { throw invalid() }
                    root = .local(name)
                }
            case "\"":
                root = .global(try quoted())
            case "%":
                position += 1
                var address = "%" + identifier()
                if current == ".", let next = peek(1), next.isASCIIDigitCharacter {
                    position += 1
                    address += "." + digits()
                }
                root = .absolute(address)
            default:
                guard first.isLetter || first == "_" else { throw invalid() }
                let name = identifier()
                if S7Address.looksLikeAddress(name) || looksLikeBitAddressStart(name) {
                    if current == ".", let next = peek(1), next.isASCIIDigitCharacter {
                        position += 1
                        root = .plain(name + "." + digits())
                    } else {
                        root = .plain(name)
                    }
                } else {
                    root = .plain(name)
                }
            }
            var accessors: [S7OperandPath.Accessor] = []
            var peripheral = false
            while let character = current {
                if character == ":" {
                    guard peek(1) == "P" || peek(1) == "p", position + 2 == characters.count else { throw invalid() }
                    position += 2
                    peripheral = true
                    break
                }
                if character == "." {
                    position += 1
                    guard let next = current else { throw invalid() }
                    if next == "%" {
                        position += 1
                        guard let letter = current?.uppercased().first else { throw invalid() }
                        position += 1
                        let number = digits()
                        guard let index = Int(number) else { throw invalid() }
                        let width: Int
                        switch letter {
                        case "X": width = 1
                        case "B": width = 8
                        case "W": width = 16
                        case "D": width = 32
                        default: throw invalid()
                        }
                        accessors.append(.slice(width: width, index: index))
                    } else if next == "\"" {
                        accessors.append(.member(try quoted()))
                    } else {
                        let name = identifier()
                        guard !name.isEmpty else { throw invalid() }
                        accessors.append(.member(name))
                    }
                    continue
                }
                if character == "[" {
                    position += 1
                    var depth = 1
                    var inner = ""
                    while let next = current {
                        if next == "[" { depth += 1 }
                        if next == "]" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        inner.append(next)
                        position += 1
                    }
                    guard current == "]" else { throw invalid() }
                    position += 1
                    let trimmed = inner.trimmingCharacters(in: .whitespaces)
                    if trimmed.contains(",") { throw ResolveError(message: S7Messages.multiDimensionalArray) }
                    if let value = Int(trimmed) {
                        accessors.append(.index(.constant(value)))
                    } else {
                        accessors.append(.index(.operand(try S7OperandParser.parse(trimmed))))
                    }
                    continue
                }
                throw invalid()
            }
            return S7OperandPath(root: root, accessors: accessors, isPeripheral: peripheral)
        }

        /// "I0", "M10", "QB4": the start of an address typed without "%".
        private func looksLikeBitAddressStart(_ name: String) -> Bool {
            S7Address.looksLikeAddress(name)
        }
    }
}

nonisolated private extension Character {
    var isASCIIDigitCharacter: Bool { ("0"..."9").contains(self) }
}

/// A compiled operand: where it lives at run time and what it holds.
nonisolated struct S7Operand {
    /// The operand as TIA shows it.
    let text: String
    let type: PLCType
    let isWritable: Bool
    /// Set for literals and constants.
    let constantValue: PLCValue?
    /// The location while a block runs.
    let locate: (Frame) throws -> Place
    /// Declared in the block's Temp section.
    var isTemporary = false
    /// The instance-DB or tag name at its root ("IEC_Timer_0_DB"), for consistency checks.
    var globalRoot: String?

    var elementary: PLCDataType? { type.elementary }

    func read(_ frame: Frame) throws -> PLCValue {
        if let constantValue { return constantValue }
        return try locate(frame).read()
    }

    func write(_ frame: Frame, _ value: PLCValue) throws {
        try locate(frame).write(value)
    }

    static func constant(_ value: PLCValue, type: PLCDataType, text: String) -> S7Operand {
        let stored = value.converted(to: type)
        return S7Operand(text: text, type: .elementary(type), isWritable: false, constantValue: stored,
                         locate: { _ in .cell(.constant(stored, type: type)) })
    }
}

/// How an instruction uses an operand; decides which checks apply.
nonisolated enum S7OperandUsage: Hashable, Sendable {
    case read
    case write
    case readWrite
}

/// Compiles operand text against a symbol resolver.
nonisolated final class S7OperandCompiler {
    let resolver: SymbolResolver
    /// Absolute addresses the compiled operands touch (tags included), for the
    /// "not configured in the hardware" check.
    private(set) var usedAddresses: [(address: S7Address, type: PLCDataType)] = []

    init(resolver: SymbolResolver) {
        self.resolver = resolver
    }

    /// Compiles `text`. `expected` types literals (a literal at an Auto pin
    /// gets the smallest fitting type).
    func compile(_ rawText: String, expected: PLCDataType?, usage: S7OperandUsage) throws -> S7Operand {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        if S7Placeholder.isPlaceholder(text) { throw ResolveError(message: S7Messages.operandMissing) }
        if S7OperandParser.isLiteral(text) {
            guard usage == .read else { throw ResolveError(message: S7Messages.constantNotWritable) }
            return try literal(text, expected: expected)
        }
        let path = try S7OperandParser.parse(text)
        return try compile(path, usage: usage)
    }

    /// A literal as a constant of `expected`, or of the type TIA would infer.
    func literal(_ text: String, expected: PLCDataType?) throws -> S7Operand {
        let upper = text.uppercased()
        let isTimeLiteral = upper.hasPrefix("T#") || upper.hasPrefix("TIME#") || upper.hasPrefix("-T#")
        guard let type = expected ?? S7OperandCompiler.inferredType(of: text) else {
            throw ResolveError(message: S7Messages.invalidConstant(text, "???"))
        }
        if type == .time && !isTimeLiteral {
            throw ResolveError(message: S7Messages.invalidConstant(text, type.rawValue))
        }
        if type != .time && isTimeLiteral {
            throw ResolveError(message: S7Messages.invalidConstant(text, type.rawValue))
        }
        let body = upper.hasPrefix("-T#") ? "T#-" + text.dropFirst(3) : text
        guard let value = ValueParser.parse(body, as: type) else {
            throw ResolveError(message: S7Messages.invalidConstant(text, type.rawValue))
        }
        return .constant(value, type: type, text: text)
    }

    /// The type TIA gives an untyped literal: TRUE → Bool, T#5S → Time,
    /// 2.5 → Real, 16#FF → Word, 5 → Int (DInt when it doesn't fit).
    static func inferredType(of text: String) -> PLCDataType? {
        let upper = text.trimmingCharacters(in: .whitespaces).uppercased()
        if upper == "TRUE" || upper == "FALSE" { return .bool }
        if upper.hasPrefix("T#") || upper.hasPrefix("TIME#") || upper.hasPrefix("-T#") { return .time }
        if let hash = upper.firstIndex(of: "#"), let type = PLCDataType.named(String(upper[..<hash])) { return type }
        if upper.hasPrefix("16#") || upper.hasPrefix("2#") || upper.hasPrefix("8#") {
            guard let value = ValueParser.integer(upper.replacingOccurrences(of: "_", with: "")) else { return nil }
            if value <= 0xFF && upper.hasPrefix("2#") { return .byte }
            return value <= 0xFFFF ? .word : .dword
        }
        if upper.contains(".") || (upper.contains("E") && Double(upper) != nil) { return .real }
        guard let value = Int64(upper.replacingOccurrences(of: "_", with: "")) else { return nil }
        if PLCDataType.int.contains(value) { return .int }
        if PLCDataType.dint.contains(value) { return .dint }
        return PLCDataType.udint.contains(value) ? .udint : nil
    }

    func compile(_ path: S7OperandPath, usage: S7OperandUsage) throws -> S7Operand {
        let shown = path.text
        var binding: SymbolBinding?
        if path.isPeripheral {
            binding = try peripheralBinding(path)
        } else {
            binding = try resolver.resolve(path.root)
            if binding == nil, case let .plain(name) = path.root, S7Address.looksLikeAddress(name) {
                binding = try resolver.resolve(.absolute("%" + name))
            }
        }
        guard let binding else {
            if case .absolute = path.root { throw ResolveError(message: S7Messages.notAnAddress(path.root.text)) }
            throw ResolveError(message: S7Messages.tagNotDefined(rootText(path.root)))
        }
        recordAddress(path)

        var type: PLCType
        let writable: Bool
        var locate: (Frame) throws -> Place
        switch binding {
        case let .constant(_, value, constantType):
            guard path.accessors.isEmpty else { throw ResolveError(message: S7Messages.tagNotDefined(shown)) }
            guard usage == .read else { throw ResolveError(message: S7Messages.readOnly) }
            return .constant(value, type: constantType, text: shown)
        case let .local(area, index, member):
            type = member.type
            writable = !(member.section == .input && resolver.block.kind != .functionBlock)
            locate = { frame in .node(frame.node(area, index)) }
        case let .global(symbol):
            type = symbol.place.type
            writable = symbol.isWritable
            let place = symbol.place
            locate = { _ in place }
        }

        var walked = rootText(path.root)
        for accessor in path.accessors {
            switch accessor {
            case let .member(name):
                walked += "." + name
                let members: [PLCMember]
                switch type {
                case let .structure(_, structureMembers): members = structureMembers
                case let .instance(block): members = block.members
                default: throw ResolveError(message: S7Messages.tagNotDefined(walked))
                }
                guard let member = members.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw ResolveError(message: S7Messages.tagNotDefined(walked))
                }
                type = member.type
                let base = locate
                let memberName = member.name
                locate = { frame in
                    guard let place = try base(frame).member(memberName) else {
                        throw RuntimeFault(.invalidOperation, "\(walked) is not available.")
                    }
                    return place
                }
            case let .index(index):
                guard case let .array(lower, upper, element) = type else {
                    throw ResolveError(message: S7Messages.tagNotDefined(walked + "[]"))
                }
                type = element
                let base = locate
                switch index {
                case let .constant(value):
                    walked += "[\(value)]"
                    guard value >= lower, value <= upper else {
                        throw ResolveError(message: "Index \(value) is outside the array limits [\(lower)..\(upper)] of \(rootText(path.root)).")
                    }
                    locate = { frame in
                        guard let place = try base(frame).element(value) else {
                            throw RuntimeFault(.indexOutOfRange, "Array index \(value) is out of range.")
                        }
                        return place
                    }
                case let .operand(indexPath):
                    walked += "[\(indexPath.text)]"
                    let indexOperand = try compile(indexPath, usage: .read)
                    guard let indexType = indexOperand.elementary, indexType.isInteger else {
                        throw ResolveError(message: S7Messages.dataTypeNotPermitted(indexOperand.type.displayName))
                    }
                    let shownArray = walked
                    locate = { frame in
                        let position = Int(truncatingIfNeeded: try indexOperand.read(frame).intValue)
                        guard let place = try base(frame).element(position) else {
                            throw RuntimeFault(.indexOutOfRange,
                                               "Array index \(position) is outside the limits [\(lower)..\(upper)] (\(shownArray)).")
                        }
                        return place
                    }
                }
            case let .slice(width, index):
                guard let base = type.elementary, base.isInteger, width < base.bitWidth, (index + 1) * width <= base.bitWidth else {
                    throw ResolveError(message: S7Messages.invalidOperand(shown))
                }
                type = .elementary(width == 1 ? .bool : width == 8 ? .byte : width == 16 ? .word : .dword)
                let parent = locate
                locate = { frame in
                    guard let place = try parent(frame).slice(width: width, index: index) else {
                        throw RuntimeFault(.invalidOperation, "\(shown) is not available.")
                    }
                    return place
                }
            }
        }

        if usage != .read && !writable {
            throw ResolveError(message: S7Messages.readOnly)
        }
        if usage != .write, path.isPeripheral, let address = try? S7Address.parse(peripheralAddressText(path)), address.area == .output {
            throw ResolveError(message: S7Messages.peripheralOutputRead)
        }
        var operand = S7Operand(text: shown, type: type, isWritable: writable, constantValue: nil, locate: locate)
        if case let .local(area, _, _) = binding, area == .temp { operand.isTemporary = true }
        switch path.root {
        case let .global(name), let .plain(name): operand.globalRoot = name
        default: break
        }
        return operand
    }

    private func rootText(_ root: SymbolName) -> String {
        switch root {
        case let .local(name): return "#" + name
        case let .global(name), let .plain(name): return "\"\(name)\""
        case let .absolute(text): return text
        }
    }

    private func peripheralBinding(_ path: S7OperandPath) throws -> SymbolBinding? {
        guard path.accessors.isEmpty else { throw ResolveError(message: S7Messages.peripheralOnlyForIO) }
        if case let .absolute(text) = path.root {
            return try resolver.resolve(.absolute(text + ":P"))
        }
        if case let .plain(name) = path.root, S7Address.looksLikeAddress(name) {
            return try resolver.resolve(.absolute("%" + name + ":P"))
        }
        guard let addressing = resolver as? S7AddressResolving else {
            throw ResolveError(message: S7Messages.peripheralOnlyForIO)
        }
        guard let symbol = try addressing.resolvePeripheral(path.root) else {
            if try resolver.resolve(path.root) != nil { throw ResolveError(message: S7Messages.peripheralOnlyForIO) }
            return nil
        }
        return .global(symbol)
    }

    /// The address text behind a ":P" operand, for the output-read check.
    private func peripheralAddressText(_ path: S7OperandPath) -> String {
        if case let .absolute(text) = path.root { return text }
        if let addressing = resolver as? S7AddressResolving, let found = addressing.address(of: path.root) {
            return found.address.description
        }
        if case let .plain(name) = path.root { return name }
        return ""
    }

    private func recordAddress(_ path: S7OperandPath) {
        if let addressing = resolver as? S7AddressResolving, let found = addressing.address(of: path.root) {
            usedAddresses.append(found)
        } else if case let .absolute(text) = path.root, let address = try? S7Address.parse(text) {
            usedAddresses.append((address, address.width.defaultType))
        }
    }
}
