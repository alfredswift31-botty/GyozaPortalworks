import Foundation
import Testing
@testable import GyozaPortalworks

struct MelsecDeviceParsingTests {
    private let profile = MelsecCPUProfile.fx5u

    private func parse(_ text: String) throws -> MelsecOperand {
        try MelsecOperandParser.parse(text, profile: profile)
    }

    @Test func octalInputsAndOutputs() throws {
        #expect(try parse("X7") == .device(MelsecDevice(.input, 7), index: nil))
        #expect(try parse("X10") == .device(MelsecDevice(.input, 8), index: nil))
        #expect(try parse("Y17") == .device(MelsecDevice(.output, 15), index: nil))
        #expect(MelsecDevice(.input, 8).text(profile) == "X10")
        #expect(MelsecDevice(.input, 7).advanced(by: 1).text(profile) == "X10")
        #expect(throws: MelsecOperandError.self) { try parse("X8") }
        #expect(throws: MelsecOperandError.self) { try parse("Y19") }
        #expect(throws: MelsecOperandError.self) { try parse("X2000") }
        #expect(try parse("X1777") == .device(MelsecDevice(.input, 1023), index: nil))
    }

    @Test func decimalAndHexadecimalFamilies() throws {
        #expect(try parse("M100") == .device(MelsecDevice(.internalRelay, 100), index: nil))
        #expect(try parse("d7999") == .device(MelsecDevice(.dataRegister, 7999), index: nil))
        #expect(try parse("B1F") == .device(MelsecDevice(.linkRelay, 31), index: nil))
        #expect(try parse("W1FF").text(profile) == "W1FF")
        #expect(try parse("SM400") == .device(MelsecDevice(.specialRelay, 400), index: nil))
        #expect(try parse("SD6020") == .device(MelsecDevice(.specialRegister, 6020), index: nil))
        #expect(try parse("LZ1") == .device(MelsecDevice(.longIndexRegister, 1), index: nil))
    }

    @Test func outOfRangeErrorsNameTheRange() {
        do {
            _ = try parse("D8000")
            Issue.record("D8000 should be out of range")
        } catch let error as MelsecOperandError {
            #expect(error.message.contains("D0-D7999"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(throws: MelsecOperandError.self) { try parse("T512") }
        #expect(throws: MelsecOperandError.self) { try parse("ST16") }
        #expect(throws: MelsecOperandError.self) { try parse("N15") }
        #expect(throws: MelsecOperandError.self) { try parse("P4096") }
    }

    @Test func timerAndCounterParts() throws {
        #expect(try parse("T0") == .device(MelsecDevice(.timer, 0), index: nil))
        #expect(try parse("TS3") == .device(MelsecDevice(.timer, 3, facet: .contact), index: nil))
        #expect(try parse("TN3") == .device(MelsecDevice(.timer, 3, facet: .value), index: nil))
        #expect(try parse("STN1") == .device(MelsecDevice(.retentiveTimer, 1, facet: .value), index: nil))
        #expect(try parse("SN1") == .device(MelsecDevice(.retentiveTimer, 1, facet: .value), index: nil))
        #expect(try parse("CC2") == .device(MelsecDevice(.counter, 2, facet: .coil), index: nil))
        #expect(try parse("LCN0") == .device(MelsecDevice(.longCounter, 0, facet: .value), index: nil))
        #expect(try parse("LC5").text(profile) == "LC5")
    }

    @Test func constants() throws {
        #expect(try parse("K10") == .constant(.decimal(10)))
        #expect(try parse("K-5") == .constant(.decimal(-5)))
        #expect(try parse("H1F") == .constant(.hexadecimal(31)))
        #expect(try parse("E1.5") == .constant(.real(1.5)))
        #expect(try parse("E1.5+3") == .constant(.real(1500)))
        #expect(throws: MelsecOperandError.self) { try parse("H123456789") }
        #expect(MelsecConstant.hexadecimal(255).text == "HFF")
    }

    @Test func digitSpecificationAndWordBits() throws {
        #expect(try parse("K4Y0") == .digit(count: 4, start: MelsecDevice(.output, 0), index: nil))
        #expect(try parse("K1X10") == .digit(count: 1, start: MelsecDevice(.input, 8), index: nil))
        #expect(try parse("K8M0").text(profile) == "K8M0")
        #expect(throws: MelsecOperandError.self) { try parse("K9M0") }
        #expect(throws: MelsecOperandError.self) { try parse("K4D0") }
        #expect(try parse("D0.F") == .wordBit(MelsecDevice(.dataRegister, 0), bit: 15))
        #expect(try parse("D10.3").text(profile) == "D10.3")
        #expect(throws: MelsecOperandError.self) { try parse("M0.1") }
    }

    @Test func indexModificationLabelsPointersAndNesting() throws {
        #expect(try parse("D0Z1") == .device(MelsecDevice(.dataRegister, 0), index: 1))
        #expect(throws: MelsecOperandError.self) { try parse("D0Z20") }
        #expect(try parse("Start") == .label("Start"))
        #expect(try parse("tmDelay.N") == .label("tmDelay.N"))
        #expect(try parse("P10") == .pointer(10))
        #expect(try parse("N3") == .nesting(3))
        #expect(try parse("?") == .unspecified)
    }

    @Test func labelNamesThatLookLikeDevicesAreRejected() {
        #expect(MelsecLabelRules.problem(with: "Motor") == nil)
        #expect(MelsecLabelRules.problem(with: "StartButton") == nil)
        #expect(MelsecLabelRules.problem(with: "X0") != nil)
        #expect(MelsecLabelRules.problem(with: "M100") != nil)
        #expect(MelsecLabelRules.problem(with: "K4M0") != nil)
        #expect(MelsecLabelRules.problem(with: "BAD") != nil)
        #expect(MelsecLabelRules.problem(with: "MOV") != nil)
        #expect(MelsecLabelRules.problem(with: "IF") != nil)
        #expect(MelsecLabelRules.problem(with: "1abc") != nil)
        #expect(MelsecLabelRules.problem(with: "a__b") != nil)
    }

    @Test func labelDataTypesReadBothNotations() throws {
        #expect(MelsecLabelDataType(text: "Bit") == .bit)
        #expect(MelsecLabelDataType(text: "INT") == .wordSigned)
        #expect(MelsecLabelDataType(text: "Double Word [Signed]") == .doubleWordSigned)
        #expect(MelsecLabelDataType(text: "FLOAT [Single Precision]")?.elementaryType == .real)
        #expect(MelsecLabelDataType(text: "Word [Unsigned]/Bit String [16-bit]")?.elementaryType == .uint)
        #expect(MelsecLabelDataType(text: "Bit(0..9)") == MelsecLabelDataType(.bit, arrayBounds: 0...9))
        #expect(MelsecLabelDataType(text: "ARRAY[1..5] OF INT") == MelsecLabelDataType(.wordSigned, arrayBounds: 1...5))
        #expect(MelsecLabelDataType(text: "Timer") == .timer)
        #expect(MelsecLabelDataType(.wordSigned, arrayBounds: 0...9).text == "Word [Signed](0..9)")
        let data = try JSONEncoder().encode(MelsecLabel(name: "Speed", dataType: .floatSingle))
        let decoded = try JSONDecoder().decode(MelsecLabel.self, from: data)
        #expect(decoded.dataType == .floatSingle)
        let old = try JSONDecoder().decode(MelsecLabel.self, from: Data(#"{"name":"Lamp"}"#.utf8))
        #expect(old.dataType == .bit && old.labelClass == .global)
    }
}

struct MelsecDeviceMemoryTests {
    private func operand(_ text: String) throws -> MelsecOperand {
        try MelsecOperandParser.parse(text, profile: .fx5u)
    }

    @Test func thirtyTwoBitValuesUseTwoWordsLowFirst() throws {
        let memory = MelsecDeviceMemory()
        try memory.writeInteger(try operand("D0"), width: .doubleWord, 0x0001_0002)
        #expect(memory.word(.dataRegister, 0) == 2)
        #expect(memory.word(.dataRegister, 1) == 1)
        #expect(try memory.readInteger(try operand("D0"), width: .doubleWord) == 0x0001_0002)
        try memory.writeInteger(try operand("D2"), width: .doubleWord, -1)
        #expect(try memory.readInteger(try operand("D2"), width: .word) == -1)
        #expect(throws: MelsecOperandError.self) { try memory.readInteger(try operand("D7999"), width: .doubleWord) }
    }

    @Test func floatIsSinglePrecisionInTwoWords() throws {
        let memory = MelsecDeviceMemory()
        try memory.writeReal(try operand("D10"), 1.5)
        #expect(memory.word(.dataRegister, 10) == 0x0000)
        #expect(memory.word(.dataRegister, 11) == 0x3FC0)
        #expect(try memory.readReal(try operand("D10")) == 1.5)
    }

    @Test func digitSpecificationAndWordBits() throws {
        let memory = MelsecDeviceMemory()
        try memory.writeInteger(try operand("K4Y0"), width: .word, 0x8001)
        #expect(memory.bit(.output, 0))
        #expect(memory.bit(.output, 15))
        #expect(!memory.bit(.output, 1))
        #expect(try memory.readInteger(try operand("K1Y0"), width: .word) == 1)
        try memory.writeBit(try operand("D5.F"), true)
        #expect(memory.word(.dataRegister, 5) == 0x8000)
        #expect(try memory.readBit(try operand("D5.F")))
    }

    @Test func indexModificationAndRuntimeRangeErrors() throws {
        let memory = MelsecDeviceMemory()
        memory.setWord(.indexRegister, 1, 5)
        try memory.writeInteger(try operand("D10Z1"), width: .word, 42)
        #expect(memory.word(.dataRegister, 15) == 42)
        memory.setWord(.indexRegister, 1, 7000)
        #expect(throws: MelsecOperandError.self) { try memory.writeInteger(try operand("D1000Z1"), width: .word, 1) }
    }

    @Test func placesForWatchWindowsAndST() throws {
        let memory = MelsecDeviceMemory()
        let d0 = try memory.place(for: try operand("D0"))
        d0.write(.int(1234))
        #expect(memory.word(.dataRegister, 0) == 1234)
        #expect(d0.elementaryType == .int)
        let bit = try memory.place(for: try operand("D0.2"))
        #expect(bit.elementaryType == .bool)
        #expect(bit.read() == .bool(false))
        let t0 = try memory.place(for: try operand("T0"), context: .bit)
        let tn0 = try memory.place(for: try operand("T0"))
        #expect(t0.elementaryType == .bool)
        #expect(tn0.elementaryType == .int)
        #expect(memory.owner(of: try #require(t0.node)) === memory.timerCounter(.timer, 0))
        #expect(try memory.place(for: try operand("K8M0")).elementaryType == .dint)
    }

    @Test func clearsRespectTheLatchRange() throws {
        let memory = MelsecDeviceMemory()
        memory.setBit(.internalRelay, 0, true)
        memory.setBit(.latchRelay, 0, true)
        memory.setWord(.dataRegister, 0, 7)
        memory.setBit(.specialRelay, 400, true)
        memory.clearAll()
        #expect(!memory.bit(.latchRelay, 0))
        #expect(memory.bit(.specialRelay, 400))
        memory.setBit(.internalRelay, 0, true)
        memory.setBit(.latchRelay, 0, true)
        memory.clearNonLatched()
        #expect(!memory.bit(.internalRelay, 0))
        #expect(memory.bit(.latchRelay, 0))
        #expect(memory.word(.dataRegister, 0) == 0)
    }
}
