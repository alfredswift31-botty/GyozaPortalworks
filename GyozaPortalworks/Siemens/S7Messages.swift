import Foundation

/// Every message text the Siemens engine shows, in one place.
///
/// Texts marked "TIA" were checked against real TIA Portal compile logs or
/// the TIA Portal V16 information system. The others are written in TIA's
/// style where the exact wording could not be verified.
nonisolated enum S7Messages {
    // MARK: Compiler (TIA)

    /// TIA: `Tag "Start" not defined.`, `Tag #x not defined.`, `Tag "DB".x not defined.`
    static func tagNotDefined(_ operand: String) -> String { "Tag \(operand) not defined." }
    /// TIA.
    static let missingInstanceDB = "Missing instance DB."
    /// TIA.
    static let selectDataType = "Please select a data type."
    /// TIA.
    static let readOnly = "The tag is read-only."
    /// TIA: "Data type Bool is not permitted here."
    static func dataTypeNotPermitted(_ type: String) -> String { "Data type \(type) is not permitted here." }
    /// TIA.
    static func parameterTypeMismatch(actual: String, formal: String) -> String {
        "The data type \(actual) of the actual parameter does not match the data type \(formal) of the formal parameter."
    }
    /// TIA.
    static let onlyInputsAsOperands = "Only the inputs of the instruction are permitted to be operands. Tags or constants are not permitted."
    /// TIA.
    static let blockCompiled = "Block was successfully compiled."
    /// TIA.
    static func compilingFinished(errors: Int, warnings: Int) -> String {
        "Compiling finished (errors: \(errors); warnings: \(warnings))"
    }
    /// TIA.
    static let ioNotConfigured = "Inputs or outputs are used that do not exist in the configured hardware."
    /// TIA (information system: "Absolute addressing is not possible for … tags in blocks with optimized access").
    static let absoluteDataBlockAccess = "Absolute addressing is not possible for tags in blocks with optimized access."
    static let absoluteLocalAccess = "Absolute addressing of local data is not possible in blocks with optimized access."
    /// TIA (information system: timers, counters and RLO edges "require a preceding logic operation").
    static let requiresPrecedingLogic = "The instruction requires a preceding logic operation."

    // MARK: Compiler (wording not verified)

    static let operandMissing = "Operand missing."
    static let networkIncomplete = "The network is incomplete."
    static func cannotTerminate(_ instruction: String) -> String {
        "The instruction \"\(instruction)\" cannot terminate a network."
    }
    static let onlyContactsInBranch = "Only contacts are permitted in a parallel branch that does not start at the power rail."
    static let shortCircuit = "Short-circuit: a parallel branch contains no instructions."
    static func mustBeLast(_ instruction: String) -> String {
        "The instruction \"\(instruction)\" must be the last element of the network."
    }
    static let selectInstruction = "Please select an instruction."
    static let constantAtContact = "Constants are not permitted as operands of contacts."
    static let constantNotWritable = "A constant cannot be written."
    static func invalidConstant(_ text: String, _ type: String) -> String {
        "Invalid constant \"\(text)\" for data type \(type)."
    }
    static let peripheralOutputRead = "I/O outputs (:P) can only be written, not read."
    static let peripheralOnlyForIO = "Direct I/O access (:P) is only possible for inputs and outputs."
    static func notAnAddress(_ text: String) -> String {
        "\"\(text)\" is not a valid address. Use I, Q or M, for example %I0.0, %QW80 or %MD20."
    }
    static func invalidOperand(_ text: String) -> String { "Invalid operand \"\(text)\"." }
    static func blockNotDefined(_ name: String) -> String { "Block \"\(name)\" not defined." }
    static let sclNotAvailable = "The SCL compiler is not available."
    static func invalidExpression(_ detail: String) -> String { "Invalid expression: \(detail)" }
    static let multiDimensionalArray = "Multi-dimensional arrays are not supported in this simulator."

    // MARK: Declarations

    static func dataTypeNotDefined(_ name: String) -> String { "Data type \"\(name)\" not defined." }
    static func dataTypeNotSupported(_ name: String) -> String {
        "Data type \(name) is not available in this simulator."
    }
    static func invalidStartValue(_ text: String, _ type: String) -> String {
        "Invalid value \"\(text)\" for data type \(type)."
    }
    static func recursiveType(_ name: String) -> String { "Data type \"\(name)\" contains itself." }
    static func nameUsedTwice(_ name: String) -> String { "The name \"\(name)\" is used more than once." }
    static let emptyName = "Enter a name."
    static let quotesInName = "Quotation marks are not permitted as a component of the tag name."
    static func addressUsedTwice(_ address: String) -> String {
        "The address \(address) is assigned to more than one tag."
    }
    static func addressDoesNotFit(_ address: String, _ type: String) -> String {
        "The address \(address) does not match the data type \(type)."
    }
    static let peripheralInTagTable = "\":P\" is not permitted in a tag address. Append it to the operand in the program instead, e.g. \"Start\":P."
    static func numberUsedTwice(_ block: String) -> String { "The block number of \(block) is already in use." }

    // MARK: Diagnostic buffer (style of TIA's S7-1200 entries)

    /// TIA (S7-1200/1500 diagnostic buffer).
    static let stopRequested = "Communication initiated request: STOP - CPU changes from RUN to STOP mode"
    static let warmRestartRequested = "Communication initiated request: WARM RESTART - CPU changes from STOP to STARTUP mode"
    static let startupToRun = "Follow-on operating mode change - CPU changes from STARTUP to RUN mode"
    static let memoryReset = "Communication initiated request: MEMORY RESET - memory reset executed"
    static let cycleTimeStop = "Maximum cycle time exceeded - CPU changes from RUN to STOP mode"
    static let downloaded = "Download: program loaded into the CPU"
    static let noProgram = "Startup inhibited: no program loaded - CPU remains in STOP mode"
    static func programmingError(_ fault: RuntimeFault) -> String {
        var text = "Programming error"
        if let block = fault.block { text += " in block \(block)" }
        if let location = fault.location { text += ", \(location)" }
        return text + ": " + fault.message
    }
}
