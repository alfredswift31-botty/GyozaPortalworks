import Foundation
import Testing
@testable import GyozaPortalworks

/// Every TIA Portal exercise, programmed the way the reference solution
/// describes it, compiled by the project compiler and checked on the CPU.
struct SiemensExerciseTests {
    static let compileSCL: (String, SymbolResolver) -> (ExecutableBody?, [Diagnostic]) = { source, resolver in
        let result = STCompiler.compile(source, resolver: resolver)
        let body: ExecutableBody? = result.program
        return (body, result.diagnostics)
    }

    /// The reference project the Exercises window draws, with the SCL compiler.
    private func referenceBench(_ id: String) throws -> SiemensBench {
        let project = try #require(SiemensReferenceSolutions.project(for: id), "No reference solution for \(id)")
        let bench = SiemensBench(project: project)
        bench.compileSCL = Self.compileSCL
        return bench
    }

    private func check(_ id: String, _ bench: SiemensBench) throws {
        let exercise = try #require(ExerciseLibrary.exercises(for: .tiaPortal).first { $0.id == id })
        try bench.load()
        let report = ExerciseChecker.run(exercise, on: bench.cpu)
        #expect(report.passed, "\(id): \(report.firstFailure?.text ?? "no checks ran")")
    }

    @Test func everyExerciseHasAReferenceProject() {
        for exercise in ExerciseLibrary.exercises(for: .tiaPortal) {
            #expect(SiemensReferenceSolutions.project(for: exercise.id) != nil, "\(exercise.id)")
        }
    }

    /// Every reference solution shown in the Exercises window passes its exercise.
    @Test(arguments: ExerciseLibrary.exercises(for: .tiaPortal).map(\.id))
    func referenceSolutionPasses(_ id: String) throws {
        try check(id, referenceBench(id))
    }

    private func trafficLightBench() throws -> SiemensBench {
        try referenceBench("tia-10-scl-traffic-light")
    }

    @Test func sclFunctionBlockRunsEndToEnd() throws {
        let bench = try trafficLightBench()
        let result = try bench.load()
        #expect(result.succeeded, "\(result.messageTexts)")
        #expect(result.messages.contains { $0.path == "TrafficLight (FB1)" && $0.text == S7Messages.blockCompiled })
        bench.cpu.setMode(.run)
        bench.input("%I0.1", true, scans: 5)
        #expect(bench.int("\"TrafficLight_DB\".state") == 0)
        bench.pulse("%I0.0")
        #expect(bench.int("\"TrafficLight_DB\".state") == 1)
        #expect(bench.cpu.digitalOutput(0))
        bench.wait(3_000)
        #expect(bench.value("\"TrafficLight_DB\".timer.ET").map { $0.intValue >= 2_900 } == true)
        bench.wait(2_100)
        #expect(bench.int("\"TrafficLight_DB\".state") == 2)
        #expect(bench.cpu.digitalOutput(2) && !bench.cpu.digitalOutput(0))
        bench.input("%I0.1", false)
        #expect(bench.int("\"TrafficLight_DB\".state") == 0)
        #expect(!bench.cpu.digitalOutput(0) && !bench.cpu.digitalOutput(1) && !bench.cpu.digitalOutput(2))

        // An error in the SCL source is reported against the FB with its line.
        let broken = try trafficLightBench()
        broken.project.blocks[1].source = "#state := #nothing;"
        let failed = broken.compile()
        #expect(!failed.succeeded)
        #expect(failed.diagnostics.contains { $0.block == "TrafficLight [FB1]" && $0.line == 1 })
    }
}
