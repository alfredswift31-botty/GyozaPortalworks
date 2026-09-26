import Foundation
import Testing
@testable import GyozaPortalworks

struct MelsecSequenceInstructionTests {
    @Test func selfHoldWithStopWinning() throws {
        let rig = try MelsecRig(il: "LD X0\nOR Y0\nANI X1\nOUT Y0")
        rig.scan()
        #expect(!rig.cpu.digitalOutput(0))
        rig.set("X0"); rig.scan()
        #expect(rig.cpu.digitalOutput(0))
        rig.set("X0", false); rig.scan(3)
        #expect(rig.cpu.digitalOutput(0), "held after release")
        rig.set("X0"); rig.set("X1"); rig.scan()
        #expect(!rig.cpu.digitalOutput(0), "stop wins")
    }

    @Test func setAndResetLastWriteWins() throws {
        let rig = try MelsecRig(il: "LD X0 SET M0\nLD X1 RST M0\nLD X1 SET M1\nLD X0 RST M1")
        rig.set("X0"); rig.set("X1"); rig.scan()
        #expect(!rig.bit("M0"))
        #expect(!rig.bit("M1"))
        rig.set("X1", false); rig.scan()
        #expect(rig.bit("M0"))
        rig.set("X0", false); rig.scan()
        #expect(rig.bit("M0"), "SET keeps the device ON")
        rig.set("X1"); rig.scan()
        #expect(!rig.bit("M0"))
        #expect(rig.bit("M1"))
    }

    @Test func forwardReverseInterlock() throws {
        let rig = try MelsecRig(il: """
        LD X0 OR Y0 ANI X2 ANI Y1 OUT Y0
        LD X1 OR Y1 ANI X2 ANI Y0 OUT Y1
        """)
        rig.set("X0"); rig.scan(); rig.set("X0", false)
        rig.set("X1"); rig.scan(2)
        #expect(rig.cpu.digitalOutput(0))
        #expect(!rig.cpu.digitalOutput(1))
        rig.set("X1", false); rig.set("X2"); rig.scan()
        #expect(!rig.cpu.digitalOutput(0))
    }

    @Test func blockInstructionsAndStack() throws {
        let rig = try MelsecRig(il: """
        LD X0 AND X1 LD X2 AND X3 ORB OUT Y0
        LD X0 LD X1 OR X2 ANB OUT Y1
        LD X4 MPS AND X5 OUT Y2 MRD AND X6 OUT Y3 MPP ANI X5 OUT Y4
        LD X7 INV OUT Y5
        """)
        rig.set("X2"); rig.set("X3"); rig.scan()
        #expect(rig.cpu.digitalOutput(0))
        #expect(!rig.cpu.digitalOutput(1))
        rig.set("X0"); rig.scan()
        #expect(rig.cpu.digitalOutput(1))
        rig.set("X4"); rig.set("X6"); rig.scan()
        #expect(!rig.cpu.digitalOutput(2))
        #expect(rig.cpu.digitalOutput(3))
        #expect(rig.cpu.digitalOutput(4))
        #expect(rig.cpu.digitalOutput(5))
        rig.set("X7"); rig.scan()
        #expect(!rig.cpu.digitalOutput(5))
    }

    @Test func pulseContactsAndPulseInstructionsFireOnce() throws {
        let rig = try MelsecRig(il: """
        LDP X0 INC D0
        LD X1 INCP D1
        LDF X2 INC D2
        LD X3 PLS M0
        LD M0 INC D3
        LD X3 MEP INC D4
        LD X3 FF M1
        LD X4 ALTP M2
        """)
        rig.set("X0"); rig.set("X1"); rig.set("X2"); rig.set("X3"); rig.set("X4")
        rig.scan(5)
        #expect(rig.int("D0") == 1)
        #expect(rig.int("D1") == 1)
        #expect(rig.int("D2") == 0)
        #expect(rig.int("D3") == 1, "PLS is ON for exactly one scan")
        #expect(rig.int("D4") == 1)
        #expect(rig.bit("M1"))
        #expect(rig.bit("M2"))
        rig.set("X0", false); rig.set("X1", false); rig.set("X2", false); rig.set("X3", false); rig.set("X4", false)
        rig.scan(2)
        #expect(rig.int("D2") == 1)
        rig.set("X0"); rig.set("X3"); rig.set("X4"); rig.scan()
        #expect(rig.int("D0") == 2)
        #expect(!rig.bit("M1"))
        #expect(!rig.bit("M2"))
    }

    @Test func masterControlDropsCoilsAndResetsTimers() throws {
        let rig = try MelsecRig(il: """
        LD X5 MC N0 M50
        LD X0 OUT Y0
        LD X1 OUT T0 K20
        LD X1 OUT ST0 K100
        LD X0 SET M1
        MCR N0
        LD X0 OUT Y1
        """)
        rig.set("X0"); rig.set("X1"); rig.scan()
        #expect(!rig.cpu.digitalOutput(0))
        #expect(rig.cpu.digitalOutput(1), "outside the zone")
        #expect(!rig.bit("M1"))
        rig.set("X5"); rig.run(1_000)
        #expect(rig.cpu.digitalOutput(0))
        #expect(rig.bit("M50"))
        #expect(rig.bit("M1"))
        #expect(rig.int("TN0") ?? 0 > 0)
        let retentive = rig.int("STN0") ?? 0
        rig.set("X5", false); rig.scan()
        #expect(!rig.cpu.digitalOutput(0))
        #expect(rig.int("TN0") == 0)
        #expect(rig.int("STN0") == retentive, "retentive timers keep their value")
        #expect(rig.bit("M1"), "SET devices stay ON")
    }

    @Test func conditionalJumpSkipsInstructions() throws {
        let rig = try MelsecRig(il: """
        LD X0
        CJ P0
        LD SM400
        INC D0
        P0
        LD SM400
        INC D1
        """)
        rig.scan(3)
        #expect(rig.int("D0") == 3)
        rig.set("X0"); rig.scan(3)
        #expect(rig.int("D0") == 3)
        #expect(rig.int("D1") == 6)
    }

    @Test func subroutineCall() throws {
        let rig = try MelsecRig(il: """
        LD X0 CALL P1
        LD SM400 INC D1
        FEND
        P1
        LD SM400 INC D0
        RET
        """)
        rig.scan(2)
        #expect(rig.int("D0") == 0)
        rig.set("X0"); rig.scan(2)
        #expect(rig.int("D0") == 2)
        #expect(rig.int("D1") == 4)
    }
}

struct MelsecTimerCounterTests {
    @Test func timerResolutions() throws {
        let rig = try MelsecRig(il: """
        LD X0 OUT T0 K50
        LD X0 OUTH T1 K500
        LD X0 OUTHS T2 K5000
        LD SM400 MOV K50 D10
        LD X0 OUT T3 D10
        LD T0 OUT Y0
        """)
        rig.set("X0"); rig.scan()
        rig.run(4_990)
        for timer in ["TS0", "TS1", "TS2", "TS3"] {
            #expect(!rig.bit(timer), "\(timer) not yet")
        }
        #expect(rig.int("TN0") == 49)
        #expect(rig.int("TN1") == 499)
        #expect(rig.int("TN2") == 4990)
        rig.scan()
        for timer in ["TS0", "TS1", "TS2", "TS3"] {
            #expect(rig.bit(timer), "\(timer) after 5 s")
        }
        #expect(rig.cpu.digitalOutput(0))
        rig.run(1_000)
        #expect(rig.int("TN0") == 50, "stops at the set value")
        rig.set("X0", false); rig.scan()
        #expect(!rig.bit("TS0"))
        #expect(rig.int("TN0") == 0)
    }

    @Test func retentiveTimerKeepsItsValue() throws {
        let rig = try MelsecRig(il: "LD X1 OUT ST0 K20\nLD X2 RST ST0")
        rig.set("X1"); rig.scan(); rig.run(1_000)
        rig.set("X1", false); rig.run(3_000)
        #expect(rig.int("STN0") == 10)
        rig.set("X1"); rig.scan(); rig.run(1_000)
        #expect(rig.bit("STS0"))
        rig.set("X1", false); rig.scan()
        #expect(rig.bit("STS0"), "the contact stays ON until RST")
        rig.set("X2"); rig.scan()
        #expect(!rig.bit("STS0"))
        #expect(rig.int("STN0") == 0)
    }

    @Test func countersCountRisingEdgesAndReset() throws {
        let rig = try MelsecRig(il: "LD X0 OUT C0 K3\nLD X1 RST C0\nLD C0 OUT Y0\nLD X0 OUT LC0 K2")
        for _ in 0..<2 {
            rig.set("X0"); rig.scan(2); rig.set("X0", false); rig.scan(2)
        }
        #expect(rig.int("CN0") == 2)
        #expect(!rig.cpu.digitalOutput(0))
        #expect(rig.bit("LCS0"))
        rig.set("X0"); rig.scan(5)
        #expect(rig.int("CN0") == 3)
        #expect(rig.cpu.digitalOutput(0))
        rig.set("X1"); rig.scan()
        #expect(rig.int("CN0") == 0)
        #expect(!rig.cpu.digitalOutput(0))
        rig.set("X1", false); rig.scan(3)
        #expect(rig.int("CN0") == 0, "an input that is still ON doesn't count again")
    }

    @Test func timerLabels() throws {
        let labels = [MelsecLabel(name: "tmDelay", dataType: .timer), MelsecLabel(name: "Lamp", dataType: .bit, device: "Y3")]
        let rig = try MelsecRig(il: "LD X0 OUT tmDelay K10\nLD tmDelay.S OUT Lamp", labels: labels)
        rig.set("X0"); rig.scan(); rig.run(990)
        #expect(!rig.cpu.digitalOutput(3))
        rig.scan()
        #expect(rig.cpu.digitalOutput(3))
        #expect(rig.cpu.readOperand("tmDelay.N") == .int(10))
    }
}

struct MelsecDataInstructionTests {
    @Test func comparisonContactsIncluding32BitAndFloat() throws {
        let rig = try MelsecRig(il: """
        LD SM400 MOV K5 D0
        LD SM400 DMOV K80000 D2
        LD SM400 EMOV E1.25 D4
        LD= D0 K5 OUT Y0
        LDD> D2 K70000 OUT Y1
        LDE< D4 E1.5 OUT Y2
        LD<> D0 K5 OUT Y3
        LD SM400 AND<= D0 K4 OUT Y4
        LD SM401 OR>= D0 K5 OUT Y5
        """)
        rig.scan()
        #expect(rig.cpu.digitalOutput(0))
        #expect(rig.cpu.digitalOutput(1))
        #expect(rig.cpu.digitalOutput(2))
        #expect(!rig.cpu.digitalOutput(3))
        #expect(!rig.cpu.digitalOutput(4))
        #expect(rig.cpu.digitalOutput(5))
    }

    @Test func arithmeticWrapsAndUsesWideResults() throws {
        let rig = try MelsecRig(il: """
        LD SM402 MOV K32767 D0
        LD SM402 + K1 D0
        LD SM402 MOV K300 D1
        LD SM402 * D1 D1 D10
        LD SM402 DMOV K100000 D20
        LD SM402 D* D20 D20 D30
        LD SM402 / K7 K2 D40
        LD SM402 / K-7 K2 D42
        LD SM402 D/ K100000 K7 D50
        LD SM402 - K10 K20 D60
        LD SM402 ADD K1 K2 D61
        LD SM402 E/ E1 E4 D62
        LD SM402 INT2FLT K3 D64
        LD SM402 EMOV E2.5 D66
        LD SM402 FLT2INT D66 D68
        LD SM402 MOV K-1 D69
        LD SM402 INC D69
        LD SM402 MOV K5 D70
        LD SM402 NEG D70
        """)
        rig.scan()
        #expect(rig.int("D0") == -32768)
        #expect(try rig.dword("D10") == 90_000)
        #expect(try rig.dword("D30") == Int64(Int32(truncatingIfNeeded: 10_000_000_000 & 0xFFFF_FFFF)))
        #expect(try rig.dword("D32") == 2)
        #expect(rig.int("D40") == 3)
        #expect(rig.int("D41") == 1)
        #expect(rig.int("D42") == -3)
        #expect(rig.int("D43") == -1)
        #expect(try rig.dword("D50") == 14285)
        #expect(try rig.dword("D52") == 5)
        #expect(rig.int("D60") == -10)
        #expect(rig.int("D61") == 3)
        #expect(try rig.real("D62") == 0.25)
        #expect(try rig.real("D64") == 3)
        #expect(rig.int("D68") == 3, "FLT2INT rounds half away from zero")
        #expect(rig.int("D69") == 0)
        #expect(rig.int("D70") == -5)
    }

    @Test func divisionByZeroStopsTheCPU() throws {
        let rig = try MelsecRig(il: "LD X0 / D0 D1 D2\nLD SM400 OUT Y0")
        rig.scan()
        #expect(rig.cpu.digitalOutput(0))
        rig.set("X0"); rig.scan()
        #expect(rig.cpu.mode == .stop)
        #expect(!rig.cpu.digitalOutput(0))
        let message = try #require(rig.cpu.errorMessage)
        #expect(message.contains("Division by 0"))
        #expect(message.contains("step"))
        #expect(rig.cpu.diagnostics.last?.isError == true)
        #expect(rig.bit("SM0"))
    }

    @Test func bcdConversionAndItsErrors() throws {
        let rig = try MelsecRig(il: "LD SM400 BCD D0 D1\nLD SM400 BIN D2 D3")
        try rig.cpu.writeOperand("D0", value: "1234")
        try rig.cpu.writeOperand("D2", value: "H0987")
        rig.scan()
        #expect(rig.int("D1") == 0x1234)
        #expect(rig.int("D3") == 987)
        try rig.cpu.writeOperand("D0", value: "10000")
        rig.scan()
        #expect(rig.cpu.mode == .stop)
        #expect(rig.cpu.errorMessage?.contains("BCD") == true)

        let second = try MelsecRig(il: "LD SM400 BIN D2 D3")
        try second.cpu.writeOperand("D2", value: "H12A4")
        second.scan()
        #expect(second.cpu.mode == .stop)
        #expect(second.cpu.errorMessage?.contains("BCD") == true)
    }

    @Test func rotationsSetTheCarryFlag() throws {
        let rig = try MelsecRig(il: """
        LD SM402 MOV H8001 D0
        LD SM402 ROL D0 K1
        LD SM402 MOV H0001 D1
        LD SM402 ROR D1 K1
        LD SM402 MOV H8000 D2
        LD SM402 RST SM700
        LD SM402 RCL D2 K1
        LD SM402 MOV H1 D3
        LD SM402 ROL D3 K17
        """)
        rig.scan()
        #expect(rig.int("D0") == 0x0003)
        #expect(rig.int("D1") == -32768)
        #expect(rig.int("D2") == 0)
        #expect(rig.bit("SM700"), "RCL moved b15 into the carry")
        #expect(rig.int("D3") == 2, "n is taken modulo 16")
    }

    @Test func logicTransfersShiftsAndZoneInstructions() throws {
        let rig = try MelsecRig(il: """
        LD SM402 MOV HFF0F D0
        LD SM402 WAND H0FF0 D0 D1
        LD SM402 WOR H000F D1
        LD SM402 WXOR K-1 D0 D2
        LD SM402 FMOV K7 D10 K3
        LD SM402 BMOV D10 D20 K3
        LD SM402 MOV K9 D13
        LD SM402 ZRST D10 D11
        LD SM402 CMP K5 K3 M0
        LD SM402 ZCP K10 K20 K15 M10
        LD SM402 SET M100
        LD SM402 SFTL M100 M200 K4 K1
        LD SM402 MOV K3 Z0
        LD SM402 MOV K99 D30Z0
        LD SM402 MOV K2 D40
        LD SM402 MOV D40 K1Y10
        """)
        rig.scan()
        #expect(rig.int("D1") == 0x0F0F)
        #expect(rig.int("D2") == 0x00F0)
        #expect(rig.int("D10") == 0)
        #expect(rig.int("D11") == 0)
        #expect(rig.int("D12") == 7)
        #expect(rig.int("D13") == 9)
        #expect(rig.int("D20") == 7 && rig.int("D22") == 7)
        #expect(rig.bit("M0") && !rig.bit("M1") && !rig.bit("M2"))
        #expect(!rig.bit("M10") && rig.bit("M11") && !rig.bit("M12"))
        #expect(rig.bit("M200") && !rig.bit("M201"))
        #expect(rig.int("D33") == 99)
        #expect(rig.bit("Y11") && !rig.bit("Y10"))
    }

    @Test func indexOutsideTheDeviceRangeIsAnOperationError() throws {
        let rig = try MelsecRig(il: "LD SM400 MOV K5 Z0\nLD SM400 MOV K1 D7998Z0")
        rig.scan()
        #expect(rig.cpu.mode == .stop)
        #expect(rig.cpu.errorMessage?.contains("D0-D7999") == true)
    }

    @Test func watchdogStopsAnEndlessLoop() throws {
        let rig = try MelsecRig(il: "P0\nLD SM400 CJ P0")
        rig.scan()
        #expect(rig.cpu.mode == .stop)
        #expect(rig.cpu.errorMessage?.contains("Watchdog") == true)
    }
}
