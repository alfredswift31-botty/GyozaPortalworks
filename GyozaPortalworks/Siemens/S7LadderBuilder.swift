import Foundation

/// Builds LAD networks tersely: the exercises' reference solutions and the tests.
nonisolated enum LAD {
    static func no(_ operand: String) -> S7Node { .contact(S7Contact(.normallyOpen, operand)) }
    static func nc(_ operand: String) -> S7Node { .contact(S7Contact(.normallyClosed, operand)) }
    static func not() -> S7Node { .contact(S7Contact(.invert)) }

    static func edge(_ operand: String, memory: String, rising: Bool = true) -> S7Node {
        .contact(S7Contact(rising ? .positiveEdge : .negativeEdge, operand, secondOperand: memory))
    }

    static func cmp(_ left: String, _ comparison: S7Comparison, _ right: String, _ type: PLCDataType? = nil) -> S7Node {
        .contact(S7Contact(.compare, left, secondOperand: right, comparison: comparison, dataType: type))
    }

    static func coil(_ operand: String, _ kind: S7CoilKind = .assign, _ second: String = "") -> S7Node {
        .coil(S7Coil(kind, operand, secondOperand: second))
    }

    static func par(_ branches: [S7Node]...) -> S7Node {
        .parallel(S7Branches(branches.map { S7Path($0) }))
    }

    static func fan(_ branches: [S7Node]...) -> S7Node {
        .fanOut(S7Branches(branches.map { S7Path($0) }))
    }

    private static let outputNames: Set<String> = ["Q", "QU", "QD", "ET", "CV", "ENO", "RET_VAL", "OUT"]

    /// A box with pins given by name; unknown names become inputs, except OUTn and the usual outputs.
    static func box(_ instruction: S7Instruction, instance: String = "", operand: String = "", type: PLCDataType? = nil,
                    to second: PLCDataType? = nil, expression: String = "", _ pins: KeyValuePairs<String, String> = [:],
                    branches: KeyValuePairs<String, [S7Node]> = [:]) -> S7Node {
        var box = S7Box(instruction, dataType: type, secondDataType: second, instance: instance, operand: operand, expression: expression)
        for (name, text) in pins { assign(&box, name, .operand(text)) }
        for (name, items) in branches { assign(&box, name, .branch(S7Path(items))) }
        return .box(box)
    }

    static func call(_ block: SiemensBlock, instance: String = "", _ pins: KeyValuePairs<String, String> = [:]) -> S7Node {
        var box = S7Box.call(block, instance: instance)
        for (name, text) in pins { assign(&box, name, .operand(text)) }
        return .box(box)
    }

    private static func assign(_ box: inout S7Box, _ name: String, _ source: S7PinSource) {
        if let index = box.inputs.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            box.inputs[index].source = source
        } else if let index = box.outputs.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            box.outputs[index].source = source
        } else if outputNames.contains(name.uppercased()) || name.uppercased().hasPrefix("OUT") {
            box.outputs.append(S7Pin(name, source))
        } else {
            box.inputs.append(S7Pin(name, source))
        }
    }

    static func rung(_ items: S7Node...) -> S7Path { S7Path(items) }

    static func network(_ rungs: S7Path...) -> S7Network { S7Network(rungs: rungs) }

    /// A one-rung network.
    static func net(_ items: S7Node...) -> S7Network { S7Network(rungs: [S7Path(items)]) }
}
