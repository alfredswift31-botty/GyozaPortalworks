import Foundation

/// A MELSEC device family: the letters typed in front of the device number.
nonisolated enum MelsecDeviceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case input = "X"
    case output = "Y"
    case internalRelay = "M"
    case latchRelay = "L"
    case linkRelay = "B"
    case annunciator = "F"
    case linkSpecialRelay = "SB"
    case stepRelay = "S"
    case specialRelay = "SM"
    case timer = "T"
    case retentiveTimer = "ST"
    case counter = "C"
    case longCounter = "LC"
    case dataRegister = "D"
    case linkRegister = "W"
    case linkSpecialRegister = "SW"
    case specialRegister = "SD"
    case fileRegister = "R"
    case indexRegister = "Z"
    case longIndexRegister = "LZ"

    /// How the family is stored and addressed.
    var category: MelsecDeviceCategory {
        switch self {
        case .input, .output, .internalRelay, .latchRelay, .linkRelay, .annunciator,
             .linkSpecialRelay, .stepRelay, .specialRelay:
            return .bit
        case .timer, .retentiveTimer, .counter, .longCounter:
            return .timerCounter
        case .dataRegister, .linkRegister, .linkSpecialRegister, .specialRegister, .fileRegister, .indexRegister:
            return .word
        case .longIndexRegister:
            return .doubleWord
        }
    }

    var isBitDevice: Bool { category == .bit }
    /// 16-bit registers (D, W, SW, SD, R, Z).
    var isWordDevice: Bool { category == .word }
    var isTimerOrCounter: Bool { category == .timerCounter }
    var isTimer: Bool { self == .timer || self == .retentiveTimer }
    var isCounter: Bool { self == .counter || self == .longCounter }
    /// Word devices whose bits can be addressed as `D0.F`.
    var allowsBitSpecification: Bool {
        switch self {
        case .dataRegister, .linkRegister, .linkSpecialRegister, .specialRegister, .fileRegister: return true
        default: return false
        }
    }

    /// The name GX Works3 uses for the family in its device lists.
    var displayName: String {
        switch self {
        case .input: return "Input"
        case .output: return "Output"
        case .internalRelay: return "Internal relay"
        case .latchRelay: return "Latch relay"
        case .linkRelay: return "Link relay"
        case .annunciator: return "Annunciator"
        case .linkSpecialRelay: return "Link special relay"
        case .stepRelay: return "Step relay"
        case .specialRelay: return "Special relay"
        case .timer: return "Timer"
        case .retentiveTimer: return "Retentive timer"
        case .counter: return "Counter"
        case .longCounter: return "Long counter"
        case .dataRegister: return "Data register"
        case .linkRegister: return "Link register"
        case .linkSpecialRegister: return "Link special register"
        case .specialRegister: return "Special register"
        case .fileRegister: return "File register"
        case .indexRegister: return "Index register"
        case .longIndexRegister: return "Long index register"
        }
    }
}

nonisolated enum MelsecDeviceCategory: Hashable, Sendable {
    case bit
    case word
    case doubleWord
    case timerCounter
}

/// How a family's device numbers are written.
nonisolated enum MelsecNumbering: Int, Hashable, Sendable {
    case decimal = 10
    case octal = 8
    case hexadecimal = 16
}

/// What one CPU model provides: device ranges and numbering, latch
/// defaults, and the built-in I/O the training board wires to. Only the
/// FX5U exists for now; an iQ-R profile (hexadecimal X/Y) can be added
/// without touching the rest of the engine.
nonisolated struct MelsecCPUProfile: Hashable, Sendable {
    /// Series shown in GX Works3's project settings ("FX5U").
    var series: String
    /// Default model for new projects ("FX5U-32MR/ES").
    var modelName: String
    /// Points per device family.
    var deviceCounts: [MelsecDeviceKind: Int]
    /// Numbering per family; families not listed are decimal.
    var numberings: [MelsecDeviceKind: MelsecNumbering]
    /// Ranges kept through RESET and power-off by default ("latch (1)").
    var latchedRanges: [MelsecDeviceKind: Range<Int>]
    /// P0 … P(pointerCount - 1).
    var pointerCount: Int
    /// MC/MCR nesting N0 … N(nestingLevels - 1).
    var nestingLevels: Int
    /// Board wiring: inputs X0…, outputs Y0….
    var digitalInputCount: Int
    var digitalOutputCount: Int
    /// Built-in analog input channels (CH1, CH2) and output channel (CH1),
    /// as the special registers the CPU refreshes.
    var analogInputRegisters: [Int]
    var analogOutputRegisters: [Int]
    var analogRange: ClosedRange<Int>

    func count(_ kind: MelsecDeviceKind) -> Int {
        deviceCounts[kind] ?? 0
    }

    func numbering(for kind: MelsecDeviceKind) -> MelsecNumbering {
        numberings[kind] ?? .decimal
    }

    func contains(_ kind: MelsecDeviceKind, _ number: Int) -> Bool {
        number >= 0 && number < count(kind)
    }

    /// A device number as written in this family's base: 15 → "17" for X.
    func format(_ number: Int, for kind: MelsecDeviceKind) -> String {
        switch numbering(for: kind) {
        case .decimal: return String(number)
        case .octal: return String(number, radix: 8)
        case .hexadecimal: return String(number, radix: 16, uppercase: true)
        }
    }

    /// The whole range as GX Works3 lists it: "X0-X1777", "D0-D7999".
    func rangeText(_ kind: MelsecDeviceKind) -> String {
        let last = max(0, count(kind) - 1)
        return "\(kind.rawValue)0-\(kind.rawValue)\(format(last, for: kind))"
    }

    func isLatched(_ kind: MelsecDeviceKind, _ number: Int) -> Bool {
        latchedRanges[kind]?.contains(number) ?? false
    }

    /// FX5U (MELSEC iQ-F) default device allocation. Latch defaults: only the
    /// latch relay L is latched out of the box; everything else is cleared by
    /// RESET/power-on until a latch range is set in the CPU parameters.
    static let fx5u = MelsecCPUProfile(
        series: "FX5U",
        modelName: "FX5U-32MR/ES",
        deviceCounts: [
            .input: 1024, .output: 1024, .internalRelay: 7680, .latchRelay: 7680,
            .linkRelay: 256, .annunciator: 128, .linkSpecialRelay: 512, .stepRelay: 4096,
            .specialRelay: 10000, .timer: 512, .retentiveTimer: 16, .counter: 256,
            .longCounter: 64, .dataRegister: 8000, .linkRegister: 512, .linkSpecialRegister: 512,
            .specialRegister: 12000, .fileRegister: 32768, .indexRegister: 20, .longIndexRegister: 2,
        ],
        numberings: [
            .input: .octal, .output: .octal,
            .linkRelay: .hexadecimal, .linkSpecialRelay: .hexadecimal,
            .linkRegister: .hexadecimal, .linkSpecialRegister: .hexadecimal,
        ],
        latchedRanges: [.latchRelay: 0..<7680],
        pointerCount: 4096,
        nestingLevels: 15,
        digitalInputCount: BoardAddressing.melsecCounts.digitalInputs,
        digitalOutputCount: BoardAddressing.melsecCounts.digitalOutputs,
        analogInputRegisters: [6020, 6060],
        analogOutputRegisters: [6180],
        analogRange: 0...4000
    )

    /// Profiles by series name, for opening saved projects.
    static func named(_ name: String) -> MelsecCPUProfile? {
        let key = name.uppercased()
        if key.hasPrefix("FX5U") { return .fx5u }
        return nil
    }
}

/// Special relays and registers the simulated CPU maintains.
nonisolated enum MelsecSpecialDevices {
    /// SM0/SM1: latest self-diagnostic error; SD0: its error code.
    static let latestErrorRelay = 0
    static let latestErrorRelayNoAnnunciator = 1
    static let latestErrorCodeRegister = 0
    static let alwaysOn = 400
    static let alwaysOff = 401
    static let firstScanOn = 402
    static let firstScanOff = 403
    /// SM409 0.01 s, SM410 0.1 s, SM411 0.2 s, SM412 1 s, SM413 2 s clocks.
    static let clocks: [(relay: Int, period: Int64)] = [(409, 10), (410, 100), (411, 200), (412, 1_000), (413, 2_000)]
    /// SM700: carry flag used by RCR/RCL and set by the rotate instructions.
    static let carryFlag = 700
    /// FX3-compatible aliases kept by the FX5: SM8000 RUN monitor (NO),
    /// SM8001 RUN monitor (NC), SM8002 initial pulse (NO), SM8003 initial
    /// pulse (NC), SM8011 10 ms, SM8012 100 ms, SM8013 1 s, SM8014 1 min clocks.
    static let runMonitorOn = 8000
    static let runMonitorOff = 8001
    static let initialPulseOn = 8002
    static let initialPulseOff = 8003
    static let compatibleClocks: [(relay: Int, period: Int64)] = [(8011, 10), (8012, 100), (8013, 1_000), (8014, 60_000)]
    /// SM8067: operation error (FX3-compatible flag).
    static let operationErrorRelay = 8067
    /// SD520 current scan time (ms), SD521 (µs part), SD522/SD523 minimum,
    /// SD524/SD525 maximum.
    static let scanTimeRegisters = 520
    /// SD8010 current, SD8011 minimum, SD8012 maximum scan time (0.1 ms units).
    static let compatibleScanTimeRegisters = 8010
}
