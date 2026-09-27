import Foundation
import Testing
@testable import GyozaPortalworks

/// Builds LAD networks tersely in tests.
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

nonisolated struct SiemensBenchError: Error, CustomStringConvertible {
    var description: String
}

/// A project, compiler and CPU wired together, with a 10 ms scan clock.
nonisolated final class SiemensBench {
    var project: SiemensProject
    let cpu = SiemensCPU()
    var compileSCL: ((String, SymbolResolver) -> (ExecutableBody?, [Diagnostic]))?
    private(set) var clock: Int64 = 0

    init(_ networks: [S7Network] = [], tags: [SiemensTag] = [], configure: (inout SiemensProject) -> Void = { _ in }) {
        project = SiemensProject.newProject()
        for tag in tags { project.addTag(tag) }
        project.blocks[0].networks = networks
        configure(&project)
    }

    func compile() -> SiemensCompileResult {
        SiemensProjectCompiler(compileSCL: compileSCL).compile(project)
    }

    /// Compiles and downloads; throws with the compiler's messages on errors.
    @discardableResult
    func load(reinitialize: Bool = false) throws -> SiemensCompileResult {
        let result = compile()
        guard let image = result.image else {
            throw SiemensBenchError(description: result.diagnostics.map { "\($0.block ?? ""): \($0.message)" }.joined(separator: "\n"))
        }
        project = result.project
        cpu.load(image, reinitialize: reinitialize)
        return result
    }

    /// Downloads, switches to RUN and runs the first cycle.
    func run() throws {
        try load()
        cpu.setMode(.run)
        scan()
    }

    func scan(_ count: Int = 1) {
        for _ in 0..<count {
            clock += 10
            cpu.scan(clock: clock)
        }
    }

    func wait(_ milliseconds: Int) {
        scan(max(1, milliseconds / 10))
    }

    /// Sets a board input by its address ("%I0.3") and runs a cycle.
    func input(_ address: String, _ value: Bool, scans: Int = 1) {
        guard let parsed = try? S7Address.parse(address) else { return }
        cpu.setDigitalInput(parsed.byteOffset * 8 + parsed.bitNumber, value)
        scan(scans)
    }

    /// A rising and falling edge on a board input.
    func pulse(_ address: String) {
        input(address, true, scans: 2)
        input(address, false, scans: 2)
    }

    func value(_ operand: String) -> PLCValue? { cpu.readOperand(operand) }
    func bool(_ operand: String) -> Bool { cpu.readOperand(operand)?.boolValue ?? false }
    func int(_ operand: String) -> Int64? { cpu.readOperand(operand)?.intValue }
    func real(_ operand: String) -> Double? { cpu.readOperand(operand)?.doubleValue }

    func modify(_ operand: String, _ value: String) throws {
        try cpu.modify(operand, to: value)
    }
}

nonisolated extension SiemensCompileResult {
    var messageTexts: [String] { diagnostics.map(\.message) }

    func has(_ text: String) -> Bool {
        diagnostics.contains { $0.message == text }
    }

    func mentions(_ fragment: String) -> Bool {
        diagnostics.contains { $0.message.contains(fragment) }
    }
}
