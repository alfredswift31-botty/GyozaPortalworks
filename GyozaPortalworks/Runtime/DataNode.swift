import Foundation

/// Internal state of a built-in function block instance that isn't part of
/// its interface: edge memories and the running timer.
nonisolated final class FunctionBlockMemory {
    var previousInput = false
    var previousSecondInput = false
    var isRunning = false
    var startTime: Int64 = 0
    var accumulated: Int64 = 0

    func reset() {
        previousInput = false
        previousSecondInput = false
        isRunning = false
        startTime = 0
        accumulated = 0
    }

    func copy(from other: FunctionBlockMemory) {
        previousInput = other.previousInput
        previousSecondInput = other.previousSecondInput
        isRunning = other.isRunning
        startTime = other.startTime
        accumulated = other.accumulated
    }
}

/// Symbolic storage for one variable of any type — how TIA Portal's optimized
/// blocks and GX Works labels hold data. Elementary nodes hold a value;
/// arrays, structures and function block instances hold child nodes.
nonisolated final class DataNode {
    let type: PLCType
    let isRetain: Bool
    /// Array elements, or structure / instance members in declaration order.
    let children: [DataNode]
    /// Set on built-in function block instances.
    let memory: FunctionBlockMemory?
    private(set) var value: PLCValue
    private let startValue: PLCValue
    private let memberIndices: [String: Int]

    init(type: PLCType, initialValue: PLCValue? = nil, isRetain: Bool = false) {
        var start = PLCValue.bool(false)
        var children: [DataNode] = []
        var indices: [String: Int] = [:]
        var memory: FunctionBlockMemory?
        switch type {
        case let .elementary(dataType):
            start = initialValue?.converted(to: dataType) ?? dataType.defaultValue
        case let .array(lower, upper, element):
            if lower <= upper {
                children = (lower...upper).map { _ in
                    DataNode(type: element, initialValue: initialValue, isRetain: isRetain)
                }
            }
        case let .structure(_, members):
            children = members.map {
                DataNode(type: $0.type, initialValue: $0.initialValue, isRetain: isRetain || $0.isRetain)
            }
            indices = DataNode.index(members)
        case let .instance(block):
            children = block.members.map {
                DataNode(type: $0.type, initialValue: $0.initialValue, isRetain: isRetain || $0.isRetain)
            }
            indices = DataNode.index(block.members)
            if block.builtIn != nil {
                memory = FunctionBlockMemory()
            }
        }
        self.type = type
        self.isRetain = isRetain
        self.children = children
        self.memory = memory
        self.value = start
        self.startValue = start
        self.memberIndices = indices
    }

    private static func index(_ members: [PLCMember]) -> [String: Int] {
        var indices: [String: Int] = [:]
        for (position, member) in members.enumerated() where indices[member.name.lowercased()] == nil {
            indices[member.name.lowercased()] = position
        }
        return indices
    }

    var elementaryType: PLCDataType? { type.elementary }

    func read() -> PLCValue { value }

    /// Stores `newValue` converted to this node's type. Ignored on
    /// non-elementary nodes (use `assign(from:)`).
    func write(_ newValue: PLCValue) {
        guard let dataType = type.elementary else { return }
        value = newValue.converted(to: dataType)
    }

    /// A structure or instance member, by case-insensitive name.
    func member(_ name: String) -> DataNode? {
        guard let position = memberIndices[name.lowercased()] else { return nil }
        return children[position]
    }

    func memberIndex(_ name: String) -> Int? {
        memberIndices[name.lowercased()]
    }

    /// An array element by its declared index (not its position); nil when out of range.
    func element(_ index: Int) -> DataNode? {
        guard case let .array(lower, upper, _) = type, index >= lower, index <= upper else { return nil }
        return children[index - lower]
    }

    /// Copies every value from a node of the same shape: structure and array
    /// assignment, InOut copy-in/copy-out.
    func assign(from source: DataNode) {
        guard source !== self else { return }
        if let dataType = type.elementary {
            value = source.value.converted(to: dataType)
            return
        }
        for (target, origin) in zip(children, source.children) {
            target.assign(from: origin)
        }
        if let memory, let other = source.memory {
            memory.copy(from: other)
        }
    }

    /// Restores start values. With `keepingRetain`, retentive data keeps its
    /// values — what a warm restart (STOP → RUN) does on an S7-1200.
    func reset(keepingRetain: Bool = false) {
        if keepingRetain && isRetain { return }
        value = startValue
        for child in children {
            child.reset(keepingRetain: keepingRetain)
        }
        memory?.reset()
    }

    /// Every elementary value under this node with its path, e.g. `speed`,
    /// `values[3]`, `Timer.ET` — for DB views and watch tables.
    func leaves(prefix: String = "") -> [(path: String, node: DataNode)] {
        switch type {
        case .elementary:
            return [(prefix, self)]
        case let .array(lower, _, _):
            var result: [(path: String, node: DataNode)] = []
            for (offset, child) in children.enumerated() {
                result += child.leaves(prefix: "\(prefix)[\(lower + offset)]")
            }
            return result
        case let .structure(_, members):
            return memberLeaves(names: members.map(\.name), prefix: prefix)
        case let .instance(block):
            return memberLeaves(names: block.members.map(\.name), prefix: prefix)
        }
    }

    private func memberLeaves(names: [String], prefix: String) -> [(path: String, node: DataNode)] {
        var result: [(path: String, node: DataNode)] = []
        for (name, child) in zip(names, children) {
            result += child.leaves(prefix: prefix.isEmpty ? name : "\(prefix).\(name)")
        }
        return result
    }
}

/// An elementary storage location outside symbolic storage: an absolute
/// address (%MW10, D100, X0), a device timer's current value, or a view such
/// as one bit of a word.
nonisolated struct Cell {
    let type: PLCDataType
    let read: () -> PLCValue
    let write: (PLCValue) -> Void

    init(type: PLCDataType, read: @escaping () -> PLCValue, write: @escaping (PLCValue) -> Void) {
        self.type = type
        self.read = read
        self.write = write
    }

    /// A read-only cell with a fixed value.
    static func constant(_ value: PLCValue, type: PLCDataType) -> Cell {
        let stored = value.converted(to: type)
        return Cell(type: type, read: { stored }, write: { _ in })
    }
}

/// A resolved storage location: symbolic data or an absolute cell.
nonisolated enum Place {
    case node(DataNode)
    case cell(Cell)

    var type: PLCType {
        switch self {
        case let .node(node): return node.type
        case let .cell(cell): return .elementary(cell.type)
        }
    }

    var elementaryType: PLCDataType? { type.elementary }

    var node: DataNode? {
        guard case let .node(node) = self else { return nil }
        return node
    }

    func read() -> PLCValue {
        switch self {
        case let .node(node): return node.read()
        case let .cell(cell): return cell.read()
        }
    }

    /// Stores `value` converted to the location's type (wrapping integers).
    func write(_ value: PLCValue) {
        switch self {
        case let .node(node): node.write(value)
        case let .cell(cell): cell.write(value.converted(to: cell.type))
        }
    }

    func member(_ name: String) -> Place? {
        guard let child = node?.member(name) else { return nil }
        return .node(child)
    }

    func element(_ index: Int) -> Place? {
        guard let child = node?.element(index) else { return nil }
        return .node(child)
    }

    /// Slice access: `width` bits (1, 8, 16 or 32) at position `index`,
    /// counted from the least significant end — TIA's `x.%X3`, `x.%B1`,
    /// `x.%W0` and GX Works' `D0.3`. nil when the slice doesn't fit.
    func slice(width: Int, index: Int) -> Place? {
        guard let baseType = elementaryType,
              baseType.isInteger,
              [1, 8, 16, 32].contains(width),
              width < baseType.bitWidth,
              index >= 0,
              (index + 1) * width <= baseType.bitWidth
        else { return nil }
        let sliceType: PLCDataType
        switch width {
        case 1: sliceType = .bool
        case 8: sliceType = .byte
        case 16: sliceType = .word
        default: sliceType = .dword
        }
        let shift = Int64(index * width)
        let mask = sliceType == .bool ? Int64(1) : sliceType.bitMask
        let base = self
        return .cell(Cell(type: sliceType, read: {
            let bits = ((base.read().intValue & baseType.bitMask) >> shift) & mask
            return sliceType == .bool ? .bool(bits != 0) : .int(bits)
        }, write: { newValue in
            let raw = base.read().intValue & baseType.bitMask
            let bits = (sliceType == .bool ? (newValue.boolValue ? 1 : 0) : newValue.intValue) & mask
            let updated = (raw & ~(mask << shift)) | (bits << shift)
            base.write(.int(baseType.wrap(updated)))
        }))
    }
}
