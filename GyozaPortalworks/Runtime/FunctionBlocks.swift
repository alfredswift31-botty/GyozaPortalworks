import Foundation

/// The IEC 61131-3 standard function blocks.
nonisolated enum BuiltInFunctionBlock: String, CaseIterable, Hashable, Sendable {
    case ton = "TON"
    case tof = "TOF"
    case tp = "TP"
    case tonr = "TONR"
    case ctu = "CTU"
    case ctd = "CTD"
    case ctud = "CTUD"
    case risingEdge = "R_TRIG"
    case fallingEdge = "F_TRIG"
    case setDominant = "SR"
    case resetDominant = "RS"
    /// TIA Portal's IEC_TIMER instance: each call picks TON, TOF, TP or TONR,
    /// as in `"IEC_Timer_0_DB".TON(IN := …, PT := …)`.
    case iecTimer = "IEC_TIMER"
    /// TIA Portal's IEC_COUNTER family: each call picks CTU, CTD or CTUD.
    case iecCounter = "IEC_COUNTER"

    var isTimer: Bool {
        switch self {
        case .ton, .tof, .tp, .tonr, .iecTimer: return true
        default: return false
        }
    }

    var isCounter: Bool {
        switch self {
        case .ctu, .ctd, .ctud, .iecCounter: return true
        default: return false
        }
    }

    /// The operations a generic instance accepts at a call; empty for the rest.
    var operations: [BuiltInFunctionBlock] {
        switch self {
        case .iecTimer: return [.ton, .tof, .tp, .tonr]
        case .iecCounter: return [.ctu, .ctd, .ctud]
        default: return []
        }
    }
}

/// Instance types, call signatures and behaviour of the built-in blocks.
nonisolated enum FunctionBlockLibrary {
    private static let counterValueTypes: [(suffix: String, generic: String, type: PLCDataType)] = [
        ("SINT", "IEC_SCOUNTER", .sint),
        ("INT", "IEC_COUNTER", .int),
        ("DINT", "IEC_DCOUNTER", .dint),
        ("USINT", "IEC_USCOUNTER", .usint),
        ("UINT", "IEC_UCOUNTER", .uint),
        ("UDINT", "IEC_UDCOUNTER", .udint),
    ]

    /// The instance type for a data type name as typed in an interface or label
    /// list. TIA: TON_TIME, TOF_TIME, TP_TIME, TONR_TIME, IEC_TIMER, CTU_INT,
    /// CTD_DINT, CTUD_UINT…, IEC_COUNTER / IEC_DCOUNTER…, R_TRIG, F_TRIG (a bare
    /// TON or CTU becomes TON_TIME or CTU_INT, as TIA does). GX Works: TON, TOF,
    /// TP, TONR, CTU, CTD, CTUD, R_TRIG, F_TRIG, SR, RS.
    static func type(named rawName: String, dialect: LanguageDialect) -> FunctionBlockType? {
        let name = rawName.trimmingCharacters(in: .whitespaces).uppercased()
        switch dialect {
        case .siemens:
            switch name {
            case "TON", "TON_TIME": return timer(.ton, name: "TON_TIME")
            case "TOF", "TOF_TIME": return timer(.tof, name: "TOF_TIME")
            case "TP", "TP_TIME": return timer(.tp, name: "TP_TIME")
            case "TONR", "TONR_TIME": return timer(.tonr, name: "TONR_TIME")
            case "IEC_TIMER": return timer(.iecTimer, name: "IEC_TIMER")
            case "R_TRIG": return edge(.risingEdge)
            case "F_TRIG": return edge(.fallingEdge)
            case "CTU": return counter(.ctu, valueType: .int, name: "CTU_INT")
            case "CTD": return counter(.ctd, valueType: .int, name: "CTD_INT")
            case "CTUD": return counter(.ctud, valueType: .int, name: "CTUD_INT")
            default:
                for entry in counterValueTypes {
                    if name == entry.generic {
                        return counter(.iecCounter, valueType: entry.type, name: entry.generic)
                    }
                    for kind in [BuiltInFunctionBlock.ctu, .ctd, .ctud] where name == "\(kind.rawValue)_\(entry.suffix)" {
                        return counter(kind, valueType: entry.type, name: name)
                    }
                }
                return nil
            }
        case .melsec:
            switch name {
            case "TON": return timer(.ton, name: "TON")
            case "TOF": return timer(.tof, name: "TOF")
            case "TP": return timer(.tp, name: "TP")
            case "TONR": return timer(.tonr, name: "TONR")
            case "CTU": return counter(.ctu, valueType: .int, name: "CTU")
            case "CTD": return counter(.ctd, valueType: .int, name: "CTD")
            case "CTUD": return counter(.ctud, valueType: .int, name: "CTUD")
            case "R_TRIG": return edge(.risingEdge)
            case "F_TRIG": return edge(.fallingEdge)
            case "SR": return flipFlop(.setDominant)
            case "RS": return flipFlop(.resetDominant)
            default: return nil
            }
        }
    }

    static func timer(_ kind: BuiltInFunctionBlock, name: String) -> FunctionBlockType {
        var members = [PLCMember("IN", .elementary(.bool), section: .input)]
        if kind == .tonr || kind == .iecTimer {
            members.append(PLCMember("R", .elementary(.bool), section: .input))
        }
        members += [
            PLCMember("PT", .elementary(.time), section: .input),
            PLCMember("Q", .elementary(.bool), section: .output),
            PLCMember("ET", .elementary(.time), section: .output),
        ]
        return FunctionBlockType(name: name, members: members, builtIn: kind)
    }

    static func counter(_ kind: BuiltInFunctionBlock, valueType: PLCDataType, name: String) -> FunctionBlockType {
        let bool = PLCType.elementary(.bool)
        let value = PLCType.elementary(valueType)
        let members: [PLCMember]
        switch kind {
        case .ctu:
            members = [
                PLCMember("CU", bool, section: .input), PLCMember("R", bool, section: .input),
                PLCMember("PV", value, section: .input), PLCMember("Q", bool, section: .output),
                PLCMember("CV", value, section: .output),
            ]
        case .ctd:
            members = [
                PLCMember("CD", bool, section: .input), PLCMember("LD", bool, section: .input),
                PLCMember("PV", value, section: .input), PLCMember("Q", bool, section: .output),
                PLCMember("CV", value, section: .output),
            ]
        default:
            members = [
                PLCMember("CU", bool, section: .input), PLCMember("CD", bool, section: .input),
                PLCMember("R", bool, section: .input), PLCMember("LD", bool, section: .input),
                PLCMember("PV", value, section: .input), PLCMember("QU", bool, section: .output),
                PLCMember("QD", bool, section: .output), PLCMember("CV", value, section: .output),
            ]
        }
        return FunctionBlockType(name: name, members: members, builtIn: kind)
    }

    static func edge(_ kind: BuiltInFunctionBlock) -> FunctionBlockType {
        FunctionBlockType(name: kind.rawValue, members: [
            PLCMember("CLK", .elementary(.bool), section: .input),
            PLCMember("Q", .elementary(.bool), section: .output),
        ], builtIn: kind)
    }

    static func flipFlop(_ kind: BuiltInFunctionBlock) -> FunctionBlockType {
        let names = kind == .setDominant ? ["S1", "R"] : ["S", "R1"]
        return FunctionBlockType(name: kind.rawValue, members: [
            PLCMember(names[0], .elementary(.bool), section: .input),
            PLCMember(names[1], .elementary(.bool), section: .input),
            PLCMember("Q1", .elementary(.bool), section: .output),
        ], builtIn: kind)
    }

    /// The parameters a call may assign. Generic instances (IEC_TIMER,
    /// IEC_COUNTER) need the call's `operation`; a generic counter's `Q` maps
    /// to QU for CTU and QD for CTD. Returns [] for a generic instance without
    /// an operation. User blocks list their Input, InOut and Output members.
    static func callParameters(of type: FunctionBlockType, operation: BuiltInFunctionBlock? = nil) -> [CallParameter] {
        guard let builtIn = type.builtIn else {
            var parameters: [CallParameter] = []
            for (index, member) in type.members.enumerated() where member.section.isParameter {
                parameters.append(CallParameter(name: member.name, section: member.section, type: member.type, memberIndex: index))
            }
            return parameters
        }
        let effective = operation ?? builtIn
        let names: [String]
        switch effective {
        case .ton, .tof, .tp: names = ["IN", "PT", "Q", "ET"]
        case .tonr: names = ["IN", "R", "PT", "Q", "ET"]
        case .ctu: names = ["CU", "R", "PV", "Q", "CV"]
        case .ctd: names = ["CD", "LD", "PV", "Q", "CV"]
        case .ctud: names = ["CU", "CD", "R", "LD", "PV", "QU", "QD", "CV"]
        case .risingEdge, .fallingEdge: names = ["CLK", "Q"]
        case .setDominant: names = ["S1", "R", "Q1"]
        case .resetDominant: names = ["S", "R1", "Q1"]
        case .iecTimer, .iecCounter: names = []
        }
        var parameters: [CallParameter] = []
        for name in names {
            var memberName = name
            if builtIn == .iecCounter && name == "Q" {
                memberName = effective == .ctd ? "QD" : "QU"
            }
            guard let index = type.memberIndex(memberName) else { continue }
            let member = type.members[index]
            parameters.append(CallParameter(name: name, section: member.section, type: member.type, memberIndex: index))
        }
        return parameters
    }

    /// Runs one call of a built-in block on its instance data; the caller has
    /// written the inputs. `now` is the CPU clock in milliseconds.
    static func execute(_ type: FunctionBlockType, operation: BuiltInFunctionBlock? = nil, instance: DataNode, now: Int64) {
        guard let builtIn = type.builtIn, let memory = instance.memory else { return }
        let kind = operation ?? builtIn
        let io = InstanceIO(node: instance)
        switch kind {
        case .ton: onDelay(io, memory, now: now)
        case .tof: offDelay(io, memory, now: now)
        case .tp: pulse(io, memory, now: now)
        case .tonr: retentiveOnDelay(io, memory, now: now)
        case .ctu, .ctd, .ctud: count(kind, io, memory, generic: builtIn == .iecCounter)
        case .risingEdge:
            let clock = io.bool("CLK")
            io.set("Q", clock && !memory.previousInput)
            memory.previousInput = clock
        case .fallingEdge:
            let clock = io.bool("CLK")
            io.set("Q", !clock && memory.previousInput)
            memory.previousInput = clock
        case .setDominant:
            io.set("Q1", io.bool("S1") || (!io.bool("R") && io.bool("Q1")))
        case .resetDominant:
            io.set("Q1", !io.bool("R1") && (io.bool("S") || io.bool("Q1")))
        case .iecTimer, .iecCounter:
            break
        }
    }

    /// TON: Q turns on once IN has been on for PT; ET counts up to PT.
    private static func onDelay(_ io: InstanceIO, _ memory: FunctionBlockMemory, now: Int64) {
        let preset = max(0, io.int("PT"))
        if io.bool("IN") {
            if !memory.isRunning {
                memory.isRunning = true
                memory.startTime = now
            }
            let elapsed = now - memory.startTime
            io.setTime("ET", min(elapsed, preset))
            io.set("Q", elapsed >= preset)
        } else {
            memory.isRunning = false
            io.set("Q", false)
            io.setTime("ET", 0)
        }
    }

    /// TOF: Q follows IN on, and stays on for PT after IN turns off.
    private static func offDelay(_ io: InstanceIO, _ memory: FunctionBlockMemory, now: Int64) {
        let input = io.bool("IN")
        let preset = max(0, io.int("PT"))
        if input {
            memory.isRunning = false
            io.set("Q", true)
            io.setTime("ET", 0)
        } else {
            if memory.previousInput {
                memory.isRunning = true
                memory.startTime = now
            }
            if memory.isRunning {
                let elapsed = now - memory.startTime
                if elapsed >= preset {
                    memory.isRunning = false
                    io.set("Q", false)
                    io.setTime("ET", preset)
                } else {
                    io.set("Q", true)
                    io.setTime("ET", elapsed)
                }
            }
        }
        memory.previousInput = input
    }

    /// TP: a rising edge on IN starts a pulse of exactly PT, whatever IN does
    /// meanwhile. ET holds at PT until IN is off.
    private static func pulse(_ io: InstanceIO, _ memory: FunctionBlockMemory, now: Int64) {
        let input = io.bool("IN")
        let preset = max(0, io.int("PT"))
        if !memory.isRunning && input && !memory.previousInput {
            memory.isRunning = true
            memory.startTime = now
        }
        if memory.isRunning {
            let elapsed = now - memory.startTime
            if elapsed >= preset {
                memory.isRunning = false
                io.set("Q", false)
                io.setTime("ET", preset)
            } else {
                io.set("Q", true)
                io.setTime("ET", elapsed)
            }
        }
        if !memory.isRunning && !input {
            io.setTime("ET", 0)
        }
        memory.previousInput = input
    }

    /// TONR: accumulates on-time across interruptions; only R clears it.
    private static func retentiveOnDelay(_ io: InstanceIO, _ memory: FunctionBlockMemory, now: Int64) {
        let preset = max(0, io.int("PT"))
        if io.bool("R") {
            memory.isRunning = false
            memory.accumulated = 0
            io.set("Q", false)
            io.setTime("ET", 0)
        } else if io.bool("IN") {
            if !memory.isRunning {
                memory.isRunning = true
                memory.startTime = now
            }
            let total = memory.accumulated + (now - memory.startTime)
            io.setTime("ET", min(total, preset))
            io.set("Q", total >= preset)
        } else {
            if memory.isRunning {
                memory.accumulated = min(memory.accumulated + (now - memory.startTime), preset)
                memory.isRunning = false
            }
            io.setTime("ET", min(memory.accumulated, preset))
        }
    }

    /// CTU / CTD / CTUD: count rising edges; R (reset) beats LD (load).
    private static func count(_ kind: BuiltInFunctionBlock, _ io: InstanceIO, _ memory: FunctionBlockMemory, generic: Bool) {
        let range = io.type("CV").integerRange ?? (-32_768...32_767)
        var value = io.int("CV")
        let preset = io.int("PV")
        let up = kind != .ctd && io.bool("CU")
        let down = kind != .ctu && io.bool("CD")
        let reset = kind != .ctd && io.bool("R")
        let load = kind != .ctu && io.bool("LD")
        let upEdge = up && !memory.previousInput
        let downEdge = down && !memory.previousSecondInput
        if reset {
            value = 0
        } else if load {
            value = preset
        } else if upEdge && downEdge {
            // Both edges in one call cancel out (TIA CTUD).
        } else if upEdge && value < range.upperBound {
            value += 1
        } else if downEdge && value > range.lowerBound {
            value -= 1
        }
        io.set("CV", integer: value)
        switch kind {
        case .ctu: io.set(generic ? "QU" : "Q", value >= preset)
        case .ctd: io.set(generic ? "QD" : "Q", value <= 0)
        default:
            io.set("QU", value >= preset)
            io.set("QD", value <= 0)
        }
        memory.previousInput = up
        memory.previousSecondInput = down
    }
}

/// Member access on an instance by name.
nonisolated private struct InstanceIO {
    let node: DataNode

    func bool(_ name: String) -> Bool { node.member(name)?.read().boolValue ?? false }
    func int(_ name: String) -> Int64 { node.member(name)?.read().intValue ?? 0 }
    func type(_ name: String) -> PLCDataType { node.member(name)?.elementaryType ?? .int }
    func set(_ name: String, _ value: Bool) { node.member(name)?.write(.bool(value)) }
    func set(_ name: String, integer value: Int64) { node.member(name)?.write(.int(value)) }
    func setTime(_ name: String, _ milliseconds: Int64) { node.member(name)?.write(.time(milliseconds)) }
}
