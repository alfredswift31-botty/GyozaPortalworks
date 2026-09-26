import Foundation

/// One line of Program Check's result.
nonisolated struct MelsecCheckFinding: Hashable, Sendable {
    nonisolated enum Severity: String, Hashable, Sendable {
        case error, warning
    }

    var severity: Severity
    var program: String
    /// Step number; nil for findings about the whole program.
    var step: Int?
    var message: String
}

/// Tool > Check Program: duplicated coils, MC/MCR pairing, jump and call
/// destinations, and device ranges that conversion alone doesn't catch.
nonisolated enum MelsecProgramCheck {
    static func check(_ programs: [(name: String, program: MelsecILProgram)],
                      profile: MelsecCPUProfile = .fx5u) -> [MelsecCheckFinding] {
        var findings: [MelsecCheckFinding] = []
        var coils: [String: [(program: String, step: Int)]] = [:]
        var coilOrder: [String] = []
        for (name, program) in programs {
            let steps = program.stepNumbers
            for (index, instruction) in program.instructions.enumerated() where instruction.definition.kind == .output {
                guard let target = instruction.operands.first else { continue }
                let key = target.text(profile).uppercased()
                if coils[key] == nil { coilOrder.append(key) }
                coils[key, default: []].append((name, steps[index]))
            }
            findings += checkMasterControl(name, program)
            findings += checkPointers(name, program, profile: profile)
            findings += checkRanges(name, program, profile: profile)
        }
        for key in coilOrder {
            guard let uses = coils[key], uses.count > 1, let first = uses.first else { continue }
            let places = uses.map { "\($0.program) step \($0.step)" }.joined(separator: ", ")
            findings.append(MelsecCheckFinding(severity: .warning, program: first.program, step: first.step,
                                               message: "Duplicated coil: \(key) is output more than once (\(places)). The last OUT executed wins."))
        }
        return findings
    }

    private static func checkMasterControl(_ name: String, _ program: MelsecILProgram) -> [MelsecCheckFinding] {
        var findings: [MelsecCheckFinding] = []
        let steps = program.stepNumbers
        var openZones: [(level: Int, step: Int)] = []
        for (index, instruction) in program.instructions.enumerated() {
            guard case let .nesting(level)? = instruction.operands.first else { continue }
            switch instruction.definition.kind {
            case .masterControl:
                if openZones.contains(where: { $0.level == level }) {
                    findings.append(MelsecCheckFinding(severity: .error, program: name, step: steps[index],
                                                       message: "MC N\(level) is used again before MCR N\(level)."))
                } else if let last = openZones.last, level < last.level {
                    findings.append(MelsecCheckFinding(severity: .error, program: name, step: steps[index],
                                                       message: "MC N\(level) is nested inside MC N\(last.level): nesting numbers must increase (N0, N1, …)."))
                }
                openZones.append((level, steps[index]))
            case .masterControlReset:
                guard openZones.contains(where: { $0.level == level }) else {
                    findings.append(MelsecCheckFinding(severity: .error, program: name, step: steps[index],
                                                       message: "MCR N\(level) has no matching MC N\(level)."))
                    continue
                }
                openZones.removeAll { $0.level >= level }
            default:
                break
            }
        }
        for entry in openZones {
            findings.append(MelsecCheckFinding(severity: .error, program: name, step: entry.step,
                                               message: "MC N\(entry.level) has no matching MCR N\(entry.level)."))
        }
        return findings
    }

    private static func checkPointers(_ name: String, _ program: MelsecILProgram, profile: MelsecCPUProfile) -> [MelsecCheckFinding] {
        var findings: [MelsecCheckFinding] = []
        let steps = program.stepNumbers
        var labels: [Int: Int] = [:]
        let fend = program.instructions.firstIndex { $0.definition.kind == .mainProgramEnd }
        for (index, instruction) in program.instructions.enumerated() where instruction.definition.kind == .pointerLabel {
            guard case let .pointer(number)? = instruction.operands.first else { continue }
            if labels[number] != nil {
                findings.append(MelsecCheckFinding(severity: .error, program: name, step: steps[index],
                                                   message: "The pointer P\(number) is used more than once."))
            } else {
                labels[number] = index
            }
        }
        for (index, instruction) in program.instructions.enumerated() {
            let kind = instruction.definition.kind
            guard kind == .jump || kind == .call, case let .pointer(number)? = instruction.operands.first else { continue }
            guard let target = labels[number] else {
                findings.append(MelsecCheckFinding(severity: .error, program: name, step: steps[index],
                                                   message: "\(instruction.mnemonic) P\(number): the pointer P\(number) does not exist."))
                continue
            }
            if kind == .call {
                guard let fend, target > fend else {
                    findings.append(MelsecCheckFinding(severity: .error, program: name, step: steps[index],
                                                       message: "\(instruction.mnemonic) P\(number): a subroutine must come after FEND."))
                    continue
                }
            } else if let fend, (index < fend) != (target < fend) {
                findings.append(MelsecCheckFinding(severity: .error, program: name, step: steps[index],
                                                   message: "CJ P\(number) jumps across FEND."))
            }
        }
        if let fend {
            let subroutine = program.instructions[(fend + 1)...]
            if !subroutine.isEmpty, !subroutine.contains(where: { $0.definition.kind == .subroutineReturn }),
               subroutine.contains(where: { $0.definition.kind != .end && $0.definition.kind != .pointerLabel }) {
                findings.append(MelsecCheckFinding(severity: .error, program: name, step: steps[fend],
                                                   message: "The subroutines after FEND have no RET."))
            }
        }
        return findings
    }

    /// Device ranges that depend on several operands: block transfers,
    /// multi-word results and bit arrays.
    private static func checkRanges(_ name: String, _ program: MelsecILProgram, profile: MelsecCPUProfile) -> [MelsecCheckFinding] {
        var findings: [MelsecCheckFinding] = []
        let steps = program.stepNumbers
        func constant(_ operand: MelsecOperand) -> Int? {
            if case let .constant(.decimal(value)) = operand { return Int(value) }
            if case let .constant(.hexadecimal(value)) = operand { return Int(value) }
            return nil
        }
        func beyond(_ operand: MelsecOperand, _ count: Int, words: Bool) -> String? {
            guard count > 0, case let .device(device, nil) = operand else { return nil }
            let last = device.number + count - 1
            guard !profile.contains(device.kind, last) else { return nil }
            return "\(operand.text(profile)) + \(count) \(words ? "words" : "bits") reaches beyond \(profile.rangeText(device.kind))."
        }
        for (index, instruction) in program.instructions.enumerated() {
            guard case let .data(operation) = instruction.definition.kind else { continue }
            let operands = instruction.operands
            var problems: [String?] = []
            switch operation {
            case .blockMove, .fillMove:
                if operands.count == 3, let count = constant(operands[2]) {
                    if operation == .blockMove { problems.append(beyond(operands[0], count, words: true)) }
                    problems.append(beyond(operands[1], count, words: true))
                }
            case .compare, .zoneCompare:
                if let last = operands.last { problems.append(beyond(last, 3, words: false)) }
            case .shiftBits:
                if operands.count == 4, let length = constant(operands[2]), let shift = constant(operands[3]) {
                    problems.append(beyond(operands[1], length, words: false))
                    problems.append(beyond(operands[0], shift, words: false))
                    if shift > length {
                        problems.append("n2 (\(shift)) is larger than n1 (\(length)).")
                    }
                }
            case .zoneReset:
                if operands.count == 2, case let .device(first, _) = operands[0], case let .device(last, _) = operands[1],
                   first.kind != last.kind {
                    problems.append("ZRST needs two devices of the same type.")
                }
            default:
                break
            }
            for problem in problems.compactMap({ $0 }) {
                findings.append(MelsecCheckFinding(severity: .error, program: name, step: steps[index],
                                                   message: "\(instruction.text(profile)): \(problem)"))
            }
        }
        return findings
    }
}
