import Foundation
import Testing
@testable import GyozaPortalworks

nonisolated struct SiemensBenchError: Error, CustomStringConvertible {
    var description: String
}

/// A project, compiler and CPU wired together, with a 10 ms scan clock.
nonisolated final class SiemensBench {
    var project: SiemensProject
    let cpu = SiemensCPU()
    var compileSCL: ((String, SymbolResolver) -> (ExecutableBody?, [Diagnostic]))?
    private(set) var clock: Int64 = 0

    /// Starts from a finished project, such as an exercise's reference solution.
    init(project: SiemensProject) {
        self.project = project
    }

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
