import Foundation

nonisolated enum MelsecProgramLanguage: String, Codable, CaseIterable, Hashable, Sendable {
    case ladder = "Ladder"
    case structuredText = "ST"
}

/// Program execution type; v1 supports Scan only.
nonisolated enum MelsecExecutionType: String, Codable, CaseIterable, Hashable, Sendable {
    case scan = "Scan"
}

/// A program block in a program file (GX Works3: MAIN → ProgPou).
nonisolated struct MelsecProgram: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// The program file it belongs to ("MAIN").
    var fileName: String
    /// The program block ("ProgPou").
    var name: String
    var language: MelsecProgramLanguage
    var ladder: MelsecLadder
    var structuredText: String
    /// VAR / VAR_CONSTANT.
    var localLabels: [MelsecLabel]
    var executionType: MelsecExecutionType

    init(id: UUID = UUID(), fileName: String = "MAIN", name: String = "ProgPou", language: MelsecProgramLanguage = .ladder,
         ladder: MelsecLadder = MelsecLadder(), structuredText: String = "", localLabels: [MelsecLabel] = [],
         executionType: MelsecExecutionType = .scan) {
        self.id = id
        self.fileName = fileName
        self.name = name
        self.language = language
        self.ladder = ladder
        self.structuredText = structuredText
        self.localLabels = localLabels
        self.executionType = executionType
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, name, language, ladder, structuredText, localLabels, executionType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? "MAIN"
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "ProgPou"
        language = try container.decodeIfPresent(MelsecProgramLanguage.self, forKey: .language) ?? .ladder
        ladder = try container.decodeIfPresent(MelsecLadder.self, forKey: .ladder) ?? MelsecLadder()
        structuredText = try container.decodeIfPresent(String.self, forKey: .structuredText) ?? ""
        localLabels = try container.decodeIfPresent([MelsecLabel].self, forKey: .localLabels) ?? []
        executionType = try container.decodeIfPresent(MelsecExecutionType.self, forKey: .executionType) ?? .scan
    }
}

/// One of the four watch windows.
nonisolated struct MelsecWatchList: Codable, Hashable, Sendable {
    var name: String
    /// Devices or labels ("X0", "D100", "Speed").
    var entries: [String]

    init(name: String, entries: [String] = []) {
        self.name = name
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case name, entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Watch"
        entries = try container.decodeIfPresent([String].self, forKey: .entries) ?? []
    }
}

/// A GX Works3 project: CPU, programs in scan order, labels, device
/// comments and watch windows.
nonisolated struct MelsecProject: Codable, Hashable, Sendable {
    var name: String
    /// CPU series ("FX5U").
    var cpuSeries: String
    var modelName: String
    var programs: [MelsecProgram]
    var globalLabels: [MelsecLabel]
    /// Device comments by device text ("X0" → "Start").
    var deviceComments: [String: String]
    var watchLists: [MelsecWatchList]

    init(name: String, cpuSeries: String = "FX5U", modelName: String = MelsecCPUProfile.fx5u.modelName,
         programs: [MelsecProgram], globalLabels: [MelsecLabel] = [], deviceComments: [String: String] = [:],
         watchLists: [MelsecWatchList] = MelsecProject.defaultWatchLists) {
        self.name = name
        self.cpuSeries = cpuSeries
        self.modelName = modelName
        self.programs = programs
        self.globalLabels = globalLabels
        self.deviceComments = deviceComments
        self.watchLists = watchLists
    }

    static let defaultWatchLists = (1...4).map { MelsecWatchList(name: "Watch \($0)") }

    /// GX Works3's new project: program file MAIN with the ladder program
    /// block ProgPou, containing only END.
    static func newProject(name: String = "Project", language: MelsecProgramLanguage = .ladder) -> MelsecProject {
        MelsecProject(name: name, programs: [MelsecProgram(language: language)])
    }

    var profile: MelsecCPUProfile { MelsecCPUProfile.named(cpuSeries) ?? .fx5u }

    private enum CodingKeys: String, CodingKey {
        case name, cpuSeries, modelName, programs, globalLabels, deviceComments, watchLists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Project"
        cpuSeries = try container.decodeIfPresent(String.self, forKey: .cpuSeries) ?? "FX5U"
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? MelsecCPUProfile.fx5u.modelName
        programs = try container.decodeIfPresent([MelsecProgram].self, forKey: .programs) ?? [MelsecProgram()]
        globalLabels = try container.decodeIfPresent([MelsecLabel].self, forKey: .globalLabels) ?? []
        deviceComments = try container.decodeIfPresent([String: String].self, forKey: .deviceComments) ?? [:]
        var lists = try container.decodeIfPresent([MelsecWatchList].self, forKey: .watchLists) ?? []
        while lists.count < 4 {
            lists.append(MelsecWatchList(name: "Watch \(lists.count + 1)"))
        }
        watchLists = lists
    }

    /// The device text comments are keyed by: "x10" → "X10", "d0" → "D0".
    func commentKey(_ operandText: String) -> String? {
        guard let operand = try? MelsecOperandParser.parse(operandText, profile: profile) else { return nil }
        switch operand {
        case .device, .wordBit, .digit:
            return operand.text(profile)
        default:
            return nil
        }
    }

    /// The comment of a device, as the ladder shows it under the operand.
    func comment(for operandText: String) -> String? {
        guard let key = commentKey(operandText) else { return nil }
        return deviceComments[key]
    }

    /// Sets or (with an empty text) removes a device comment.
    mutating func setComment(_ text: String, for operandText: String) throws {
        guard let key = commentKey(operandText) else {
            throw MelsecOperandError(message: "'\(operandText)' is not a device.")
        }
        deviceComments[key] = text.isEmpty ? nil : text
    }
}

/// The result of Rebuild All: the CPU image when everything compiled, the
/// Output window's messages, each ladder's conversion and Program Check.
nonisolated struct MelsecCompileOutput {
    var image: MelsecCPUImage?
    var diagnostics: [Diagnostic]
    /// Conversion results of the ladder programs, by program id.
    var conversions: [UUID: MelsecConversionResult]
    /// Program Check findings (shown separately; they don't block writing).
    var findings: [MelsecCheckFinding]

    var succeeded: Bool { image != nil }
}

/// Builds a CPU image from a project: converts the ladders, compiles ST
/// through the injected compiler, and binds labels to storage.
nonisolated struct MelsecProjectCompiler {
    /// The ST compiler (STCompiler.compile wrapped by the app); nil means ST
    /// programs cannot be compiled.
    var compileST: ((String, SymbolResolver) -> (ExecutableBody?, [Diagnostic]))?

    init(compileST: ((String, SymbolResolver) -> (ExecutableBody?, [Diagnostic]))? = nil) {
        self.compileST = compileST
    }

    /// Compiles `project`. Pass the running CPU's `memory` to keep device
    /// values across Write to PLC; a fresh memory is used otherwise.
    func compile(_ project: MelsecProject, memory existing: MelsecDeviceMemory? = nil) -> MelsecCompileOutput {
        let profile = project.profile
        let memory = existing.flatMap { $0.profile == profile ? $0 : nil } ?? MelsecDeviceMemory(profile: profile)
        var diagnostics: [Diagnostic] = []
        var conversions: [UUID: MelsecConversionResult] = [:]
        var checked: [(name: String, program: MelsecILProgram)] = []

        func report(_ message: String, block: String?, line: Int? = nil, column: Int? = nil, network: Int? = nil) {
            var diagnostic = Diagnostic.error(message, line: line, column: column, network: network)
            diagnostic.block = block
            diagnostics.append(diagnostic)
        }

        for problem in MelsecLabelScope.problems(in: project.globalLabels, profile: profile) {
            report(problem, block: "Global Label")
        }
        for label in project.globalLabels where !label.labelClass.isGlobal {
            report("'\(label.name)': global labels must be VAR_GLOBAL or VAR_GLOBAL_CONSTANT.", block: "Global Label")
        }
        let globals = MelsecLabelStorage(labels: project.globalLabels, memory: memory)
        var programs: [MelsecProgramImage] = []
        var names: Set<String> = []

        for (index, program) in project.programs.enumerated() {
            if !names.insert(program.name.lowercased()).inserted {
                report("The program name '\(program.name)' is used more than once.", block: program.name)
            }
            for problem in MelsecLabelScope.problems(in: program.localLabels, profile: profile) {
                report(problem, block: program.name)
            }
            for label in program.localLabels where label.labelClass.isGlobal {
                report("'\(label.name)': local labels must be VAR or VAR_CONSTANT.", block: program.name)
            }
            let members = program.localLabels.map { label in
                PLCMember(label.name, label.dataType.plcType,
                          section: label.labelClass.isConstant ? .constant : .staticVar,
                          initialValue: label.dataType.elementaryType == nil ? nil : label.startValue)
            }
            let block = BlockHandle(name: program.name, kind: .organizationBlock, number: index + 1, members: members)
            let instance = block.makeInstanceArea()
            let storage = MelsecLabelStorage(labels: program.localLabels, memory: memory, parent: globals, instance: instance)

            switch program.language {
            case .ladder:
                let scope = MelsecLabelScope(locals: program.localLabels, globals: project.globalLabels)
                let conversion = MelsecConverter.convert(program.ladder, scope: scope, profile: profile)
                conversions[program.id] = conversion
                for failure in conversion.errors {
                    report(failure.message, block: program.name, line: failure.row + 1, column: failure.column + 1, network: failure.block + 1)
                }
                guard conversion.succeeded else { continue }
                checked.append((program.name, conversion.program))
                do {
                    let runtime = try MelsecLadderRuntime(name: program.name, program: conversion.program, storage: storage)
                    programs.append(MelsecProgramImage(name: program.name, block: block, instance: instance, labels: storage, code: .ladder(runtime)))
                } catch let failure as MelsecOperationError {
                    report(failure.message, block: program.name)
                } catch {
                    report("\(program.name) could not be loaded.", block: program.name)
                }
            case .structuredText:
                guard let compileST else {
                    report("The ST compiler is not available.", block: program.name)
                    continue
                }
                let resolver = MelsecSymbolResolver(block: block, labels: storage)
                let (body, messages) = compileST(program.structuredText, resolver)
                for message in messages {
                    var tagged = message
                    if tagged.block == nil { tagged.block = program.name }
                    diagnostics.append(tagged)
                }
                guard let body, !messages.contains(where: { $0.severity == .error }) else {
                    if body == nil, !messages.contains(where: { $0.severity == .error }) {
                        report("\(program.name) could not be compiled.", block: program.name)
                    }
                    continue
                }
                block.body = body
                programs.append(MelsecProgramImage(name: program.name, block: block, instance: instance, labels: storage, code: .structuredText(body)))
            }
        }

        let findings = MelsecProgramCheck.check(checked, profile: profile)
        let failed = diagnostics.contains { $0.severity == .error }
        let image = failed ? nil : MelsecCPUImage(memory: memory, globals: globals, programs: programs)
        return MelsecCompileOutput(image: image, diagnostics: diagnostics, conversions: conversions, findings: findings)
    }
}
