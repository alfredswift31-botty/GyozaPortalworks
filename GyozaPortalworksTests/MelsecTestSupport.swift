import Foundation
import Testing
@testable import GyozaPortalworks

/// An ExecutableBody built from a closure, standing in for compiled ST.
final class MelsecTestBody: ExecutableBody {
    let action: (Frame) throws -> Void

    init(_ action: @escaping (Frame) throws -> Void) {
        self.action = action
    }

    func execute(_ frame: Frame) throws {
        try action(frame)
    }
}

enum MelsecTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

/// A CPU running one program, driven scan by scan with a 10 ms scan time.
final class MelsecRig {
    let cpu: MelsecCPU
    private(set) var clock: Int64 = 0

    init(cpu: MelsecCPU) {
        self.cpu = cpu
    }

    /// Loads instruction-list text as ProgPou.
    convenience init(il text: String, labels: [MelsecLabel] = [], run: Bool = true) throws {
        let scope = MelsecLabelScope(globals: labels)
        let parsed = MelsecILParser.parse(text, scope: scope)
        guard parsed.errors.isEmpty else {
            throw MelsecTestError.failed(parsed.errors.map { "line \($0.line): \($0.message)" }.joined(separator: "; "))
        }
        try self.init(program: parsed.program, labels: labels, run: run)
    }

    convenience init(program: MelsecILProgram, labels: [MelsecLabel] = [], run: Bool = true) throws {
        let memory = MelsecDeviceMemory()
        let globals = MelsecLabelStorage(labels: labels, memory: memory)
        let block = BlockHandle(name: "ProgPou", kind: .organizationBlock, number: 1, members: [])
        let instance = block.makeInstanceArea()
        let storage = MelsecLabelStorage(labels: [], memory: memory, parent: globals, instance: instance)
        let runtime = try MelsecLadderRuntime(name: "ProgPou", program: program, storage: storage)
        let image = MelsecCPUImage(memory: memory, globals: globals,
                                   programs: [MelsecProgramImage(name: "ProgPou", block: block, instance: instance, labels: storage, code: .ladder(runtime))])
        let cpu = MelsecCPU()
        cpu.load(image)
        self.init(cpu: cpu)
        if run {
            cpu.setMode(.run)
        }
    }

    func scan(_ count: Int = 1) {
        for _ in 0..<count {
            clock += 10
            cpu.scan(clock: clock)
        }
    }

    /// Runs for `milliseconds` of simulated time.
    func run(_ milliseconds: Int) {
        scan(milliseconds / 10)
    }

    func set(_ device: String, _ value: Bool = true) {
        do {
            try cpu.writeOperand(device, value: value ? "TRUE" : "FALSE")
        } catch {
            Issue.record("Cannot set \(device): \(error)")
        }
    }

    func bit(_ device: String) -> Bool {
        cpu.readOperand(device)?.boolValue ?? false
    }

    func int(_ device: String) -> Int64? {
        cpu.readOperand(device)?.intValue
    }

    func dword(_ device: String) throws -> Int64 {
        let operand = try MelsecOperandParser.parse(device, profile: .fx5u)
        return try cpu.memory.readInteger(operand, width: .doubleWord)
    }

    func real(_ device: String) throws -> Double {
        let operand = try MelsecOperandParser.parse(device, profile: .fx5u)
        return try cpu.memory.readReal(operand)
    }
}

enum MelsecTestLadder {
    /// Builds a ladder by typing Ladder Input texts in order. After an OR
    /// entry the cursor moves to the next free row, ready for a new rung.
    static func build(_ inputs: [String]) throws -> MelsecLadder {
        var editor = MelsecLadderEditor()
        for input in inputs {
            try editor.enterLadderInput(input)
            if input.uppercased().hasPrefix("OR") {
                editor.moveCursor(to: MelsecCellRef(row: editor.ladder.endRow, column: 0))
            }
        }
        return editor.ladder
    }

    /// The Conversion Result code lines of a ladder.
    static func codes(_ ladder: MelsecLadder, labels: [MelsecLabel] = []) -> [String] {
        let result = MelsecConverter.convert(ladder, scope: MelsecLabelScope(globals: labels))
        if !result.succeeded {
            return result.errors.map { "ERROR r\($0.row) c\($0.column): \($0.message)" }
        }
        return result.listing(.fx5u).map(\.code)
    }

    static func codes(il text: String) -> [String] {
        MelsecILParser.parse(text).program.listing(.fx5u).map(\.code)
    }
}
