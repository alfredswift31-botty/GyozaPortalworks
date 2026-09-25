import Foundation

/// The operand each training-board point is wired to. Both CPUs name their
/// board I/O with this, so exercises, the trainer and the CPUs agree.
nonisolated enum BoardAddressing {
    /// CPU 1214C DC/DC/DC: 14 DI, 10 DQ, 2 AI onboard, plus one AQ on an SB 1232 signal board.
    static let siemensCounts = (digitalInputs: 14, digitalOutputs: 10, analogInputs: 2, analogOutputs: 1)
    /// FX5U-32MR/ES: 16 DI, 16 DO, 2 AI and 1 AO built in.
    static let melsecCounts = (digitalInputs: 16, digitalOutputs: 16, analogInputs: 2, analogOutputs: 1)

    static func name(_ point: IOAssignment.Point, in environment: PracticeEnvironment) -> String {
        switch (environment, point) {
        case let (.tiaPortal, .digitalInput(index)):
            return "%I\(index / 8).\(index % 8)"
        case let (.tiaPortal, .digitalOutput(index)):
            return "%Q\(index / 8).\(index % 8)"
        case let (.tiaPortal, .analogInput(channel)):
            return "%IW\(64 + 2 * channel)"
        case let (.tiaPortal, .analogOutput(channel)):
            return "%QW\(80 + 2 * channel)"
        case let (.gxWorks3, .digitalInput(index)):
            return "X" + String(index, radix: 8)
        case let (.gxWorks3, .digitalOutput(index)):
            return "Y" + String(index, radix: 8)
        case let (.gxWorks3, .analogInput(channel)):
            return channel == 0 ? "SD6020" : "SD6060"
        case (.gxWorks3, .analogOutput):
            return "SD6180"
        }
    }
}
