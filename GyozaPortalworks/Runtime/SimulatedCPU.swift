import Foundation

nonisolated enum CPUMode: String, Codable, Hashable, Sendable {
    case stop = "STOP"
    case run = "RUN"
}

/// An entry in a CPU's diagnostic buffer (TIA) / error history (GX Works).
nonisolated struct DiagnosticEvent: Hashable, Sendable, Identifiable {
    var id = UUID()
    /// CPU clock (ms since power-on) when it happened.
    var time: Int64
    var message: String
    var isError: Bool
}

/// The machine side of a simulated PLC: what the training board wires to.
/// Point n is the board's n-th switch or lamp; each environment maps it to
/// its own operands (TIA: %I0.0…%I1.7 and %Q0.0…%Q1.7; GX Works FX5U: X0…X17
/// and Y0…Y17, numbered in octal).
nonisolated protocol ProcessIO: AnyObject {
    var digitalInputCount: Int { get }
    var digitalOutputCount: Int { get }
    var analogInputCount: Int { get }
    var analogOutputCount: Int { get }
    /// Raw analog range: 0…27648 on an S7-1200, 0…4000 on an FX5U.
    var analogRange: ClosedRange<Int> { get }

    func setDigitalInput(_ index: Int, _ value: Bool)
    func digitalInput(_ index: Int) -> Bool
    func digitalOutput(_ index: Int) -> Bool
    func setAnalogInput(_ channel: Int, _ value: Int)
    func analogInput(_ channel: Int) -> Int
    func analogOutput(_ channel: Int) -> Int

    /// Operand text for board labels: "%I0.0", "X0", "%IW64", "SD6020".
    func digitalInputName(_ index: Int) -> String
    func digitalOutputName(_ index: Int) -> String
    func analogInputName(_ channel: Int) -> String
    func analogOutputName(_ channel: Int) -> String
}

/// A simulated CPU the shared tools (training board, exercise checker) drive.
/// Implementations are plain classes used from the main thread.
nonisolated protocol SimulatedCPU: ProcessIO {
    var mode: CPUMode { get }
    /// CPU clock in milliseconds, advanced by `scan(clock:)`.
    var clock: Int64 { get }
    var diagnostics: [DiagnosticEvent] { get }

    /// Switches to RUN (runs startup processing on the next scan) or STOP.
    func setMode(_ mode: CPUMode)
    /// One complete cycle at `clock` (monotonic milliseconds): read inputs,
    /// run the program, write outputs. Does nothing in STOP.
    func scan(clock: Int64)
    /// Reads any operand by the text a user would type in a watch table:
    /// "%Q0.0", "\"Motor\".Speed", "Y0", "D100", "T0". nil if it doesn't resolve.
    func readOperand(_ text: String) -> PLCValue?
}
