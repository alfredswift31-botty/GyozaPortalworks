import Foundation

/// How a statement finished.
nonisolated enum STFlow: Hashable, Sendable {
    case normal
    case exitLoop
    case continueLoop
    case returnBlock
}

/// Per-call state of a running program.
nonisolated final class STRunState {
    let frame: Frame
    /// Set only when the block is monitored.
    let trace: STTrace?

    init(frame: Frame, trace: STTrace?) {
        self.frame = frame
        self.trace = trace
    }
}

/// Compiled code: evaluates a value, finds a storage location, or runs a statement.
typealias STEvaluator = (STRunState) throws -> PLCValue
typealias STLocator = (STRunState) throws -> Place
typealias STExecutor = (STRunState) throws -> STFlow

/// A compiled SCL / ST block body.
nonisolated final class STProgram: ExecutableBody {
    /// What the last monitored execution did; the editor reads it after each scan.
    let trace: STTrace
    private let body: STExecutor

    init(body: @escaping STExecutor, trace: STTrace) {
        self.body = body
        self.trace = trace
    }

    func execute(_ frame: Frame) throws {
        let monitored = frame.isMonitored
        if monitored {
            trace.executedLines.removeAll()
        }
        let state = STRunState(frame: frame, trace: monitored ? trace : nil)
        do {
            _ = try body(state)
        } catch let fault as RuntimeFault {
            throw STProgram.locate(fault, in: frame, location: nil)
        }
    }

    /// Fills in where a fault happened unless an inner block already did.
    static func locate(_ fault: RuntimeFault, in frame: Frame, location: String?) -> RuntimeFault {
        guard fault.block == nil else { return fault }
        var located = fault
        located.block = frame.block.displayName
        if located.location == nil {
            located.location = location
        }
        return located
    }
}
