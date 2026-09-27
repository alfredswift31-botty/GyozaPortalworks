import Foundation

/// A monitored signal, as the LAD/FBD editor colours it: green solid
/// (satisfied), blue dashed (not satisfied) or gray (unknown / not executed).
nonisolated enum S7Signal: String, Hashable, Sendable {
    case satisfied
    case notSatisfied
    case unknown

    init(_ flag: Bool) {
        self = flag ? .satisfied : .notSatisfied
    }
}

/// What monitoring shows for one element of a network.
nonisolated struct S7ElementStatus: Hashable, Sendable {
    /// Power flow into the element (the wire on its left).
    var input: S7Signal = .unknown
    /// Power flow out of the element (the wire on its right).
    var output: S7Signal = .unknown
    /// The element's own state: a contact that conducts, a coil whose operand
    /// is TRUE, a box whose ENO / Q is TRUE.
    var state: S7Signal = .unknown
    /// Current values of operands and pins: "operand", "IN1", "PT", "ET"…
    var values: [String: PLCValue] = [:]
}

/// Monitoring information for one LAD/FBD block, refreshed each time the
/// block runs while it is monitored. Elements the last run didn't reach stay unknown.
nonisolated final class S7BlockMonitor {
    private(set) var statuses: [UUID: S7ElementStatus] = [:]
    /// CPU scan of the last monitored run; -1 before the first.
    private(set) var lastScan: Int64 = -1

    init() {}

    func status(of id: UUID) -> S7ElementStatus {
        statuses[id] ?? S7ElementStatus()
    }

    /// Clears everything (monitoring switched off, block changed).
    func reset() {
        statuses = [:]
        lastScan = -1
    }

    func begin(scan: Int64) {
        if scan != lastScan { statuses = [:] }
        lastScan = scan
    }

    func record(_ id: UUID, input: Bool, output: Bool, state: Bool? = nil, values: [String: PLCValue] = [:]) {
        var status = statuses[id] ?? S7ElementStatus()
        status.input = S7Signal(input)
        status.output = S7Signal(output)
        if let state { status.state = S7Signal(state) }
        for (key, value) in values { status.values[key] = value }
        statuses[id] = status
    }
}

/// One run of a LAD/FBD block: the frame plus the monitor when it is monitored.
nonisolated final class S7Run {
    let frame: Frame
    let monitor: S7BlockMonitor?

    init(frame: Frame, monitor: S7BlockMonitor?) {
        self.frame = frame
        self.monitor = monitor
    }

    var clock: Int64 { frame.context.clock }

    func note(_ id: UUID, input: Bool, output: Bool, state: Bool? = nil, values: [String: PLCValue] = [:]) {
        monitor?.record(id, input: input, output: output, state: state, values: values)
    }
}

/// A compiled piece of a rung: takes the power flowing in, returns the power flowing out.
typealias S7Flow = (S7Run, Bool) throws -> Bool

/// A compiled network.
nonisolated struct S7CompiledNetwork {
    /// 1-based, as TIA numbers networks.
    let number: Int
    let rungs: [S7Flow]
}

/// The executable code of a LAD/FBD block.
nonisolated final class S7NetworkBody: ExecutableBody {
    let networks: [S7CompiledNetwork]
    let monitor: S7BlockMonitor

    init(networks: [S7CompiledNetwork], monitor: S7BlockMonitor = S7BlockMonitor()) {
        self.networks = networks
        self.monitor = monitor
    }

    func execute(_ frame: Frame) throws {
        let monitored = frame.isMonitored
        if monitored { monitor.begin(scan: frame.context.scanCount) }
        let run = S7Run(frame: frame, monitor: monitored ? monitor : nil)
        for network in networks {
            do {
                for rung in network.rungs {
                    _ = try rung(run, true)
                }
            } catch var fault as RuntimeFault {
                if fault.block == nil { fault.block = frame.block.displayName }
                if fault.location == nil { fault.location = "Network \(network.number)" }
                throw fault
            }
        }
    }
}

/// Wraps a block's code to remember the ENO of its last call, which a call
/// box passes on (ExecutionContext.run doesn't return the callee's ENO).
nonisolated final class S7TrackedBody: ExecutableBody {
    let inner: ExecutableBody
    private(set) var lastEnableOutput = true

    init(_ inner: ExecutableBody) {
        self.inner = inner
    }

    func execute(_ frame: Frame) throws {
        lastEnableOutput = true
        try inner.execute(frame)
        lastEnableOutput = frame.enableOutput
    }

    /// The LAD/FBD monitor of the wrapped code, if it is LAD/FBD.
    var monitor: S7BlockMonitor? { (inner as? S7NetworkBody)?.monitor }
}
