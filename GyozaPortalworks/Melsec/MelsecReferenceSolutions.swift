import Foundation

/// The GX Works3 exercises' reference solutions as real ladders, typed the
/// way a user would type them (Ladder Input), with a statement line on each
/// rung. The Exercises window draws them with the ladder editor's own
/// renderer, and MelsecExerciseTests converts and checks these same ladders,
/// so what is shown is a solution that passes.
nonisolated enum MelsecReferenceSolutions {
    /// A reference rung: its statement and the Ladder Input texts that draw it.
    nonisolated struct Rung: Sendable {
        let statement: String
        let inputs: [String]

        init(_ statement: String, _ inputs: [String]) {
            self.statement = statement
            self.inputs = inputs
        }
    }

    static let rungs: [String: [Rung]] = [
        "gx-01-self-hold": [
            Rung("Motor Y0: X0 starts it, the Y0 contact holds it on, X1 (ANI) stops it", ["LD X0", "ANI X1", "OUT Y0", "OR Y0"]),
        ],
        "gx-02-interlock": [
            Rung("Forward Y0 with self-hold. ANI Y1 is the interlock with reverse", ["LD X0", "ANI X2", "ANI Y1", "OUT Y0", "OR Y0"]),
            Rung("Reverse Y1 with self-hold. ANI Y0 is the interlock with forward", ["LD X1", "ANI X2", "ANI Y0", "OUT Y1", "OR Y1"]),
        ],
        "gx-03-on-delay": [
            Rung("Timer T0 counts while X0 is on: K50 x 100 ms = 5 s", ["LD X0", "OUT T0 K50"]),
            Rung("Lamp Y0 lights when T0 has timed out", ["LD T0", "OUT Y0"]),
        ],
        "gx-04-flicker": [
            Rung("T1: 1 s while X1 is on. T2 restarts the cycle", ["LD X1", "ANI T2", "OUT T1 K10"]),
            Rung("T2: 1 s after T1 has timed out", ["LD T1", "OUT T2 K10"]),
            Rung("Lamp Y1 is on while T1 is timing: 1 s on, 1 s off", ["LD X1", "ANI T1", "OUT Y1"]),
        ],
        "gx-05-traffic-light": [
            Rung("Run M0: X0 starts, M0 holds itself on, X1 stops", ["LD X0", "ANI X1", "OUT M0", "OR M0"]),
            Rung("Red phase T0: 5 s. T2 restarts the sequence", ["LD M0", "ANI T2", "OUT T0 K50"]),
            Rung("Green phase T1: 4 s after red", ["LD T0", "OUT T1 K40"]),
            Rung("Amber phase T2: 1 s after green", ["LD T1", "OUT T2 K10"]),
            Rung("Red lamp Y0", ["LD M0", "ANI T0", "OUT Y0"]),
            Rung("Green lamp Y2", ["LD T0", "ANI T1", "OUT Y2"]),
            Rung("Amber lamp Y1", ["LD T1", "ANI T2", "OUT Y1"]),
        ],
        "gx-06-counter": [
            Rung("Counter C0 counts each rising edge of X0, up to 5", ["LD X0", "OUT C0 K5"]),
            Rung("Batch done Y0 when C0 reaches 5", ["LD C0", "OUT Y0"]),
            Rung("X1 resets the counter", ["LD X1", "RST C0"]),
        ],
        "gx-07-parking": [
            Rung("Entry X0: add one car to D0 (once per edge)", ["LD X0", "INCP D0"]),
            Rung("Exit X1: take one car away", ["LD X1", "DECP D0"]),
            Rung("FULL Y0 when D0 >= 10", ["LD>= D0 K10", "OUT Y0"]),
            Rung("SPACES Y1 when D0 < 10", ["LD< D0 K10", "OUT Y1"]),
        ],
        "gx-08-mov-compare": [
            Rung("X0 loads 100 into D0", ["LD X0", "MOVP K100 D0"]),
            Rung("X1 loads 200 into D0", ["LD X1", "MOVP K200 D0"]),
            Rung("Each press of X2 adds 10 to D0", ["LD X2", "+P K10 D0"]),
            Rung("Y0 while D0 > 150", ["LD> D0 K150", "OUT Y0"]),
            Rung("Y1 while D0 = 200", ["LD= D0 K200", "OUT Y1"]),
        ],
        "gx-09-chaser": [
            Rung("First scan (SM402): start with one lit bit", ["LD SM402", "MOV H1 D0"]),
            Rung("Every second (SM412): move the bit one place", ["LD SM412", "ROLP D0 K1"]),
            Rung("Always (SM400): show D0's 16 bits on Y0 to Y17", ["LD SM400", "MOV D0 K4Y0"]),
        ],
        "gx-10-master-control": [
            Rung("X5 opens the master control zone N0", ["LD X5", "MC N0 M50"]),
            Rung("Inside the zone: Y0 follows X0", ["LD X0", "OUT Y0"]),
            Rung("Inside the zone: timer T0, 2 s", ["LD X1", "OUT T0 K20"]),
            Rung("Inside the zone: Y1 when T0 has timed out", ["LD T0", "OUT Y1"]),
            Rung("End of the zone", ["MCR N0"]),
        ],
    ]

    /// The Ladder Input texts of a reference, in typing order.
    static func inputs(for id: String) -> [String]? {
        rungs[id].map { $0.flatMap(\.inputs) }
    }

    /// The reference ladder of a GX Works3 exercise, with statements.
    static func ladder(for id: String) throws -> MelsecLadder? {
        guard let rungs = rungs[id] else { return nil }
        var ladder = try build(rungs.flatMap(\.inputs))
        for (block, rung) in zip(ladder.blocks(), rungs) where !rung.statement.isEmpty {
            ladder.rows[block.lowerBound].statement = rung.statement
        }
        // Shown as converted (white), not as freshly typed (grey).
        for index in ladder.rows.indices {
            ladder.rows[index].isUnconverted = false
        }
        return ladder
    }

    /// Builds a ladder by typing Ladder Input texts in order. After an OR
    /// entry the cursor moves to the next free row, ready for a new rung.
    static func build(_ inputs: [String]) throws -> MelsecLadder {
        var editor = MelsecLadderEditor()
        for input in inputs {
            try editor.enterLadderInput(input)
            if input.uppercased().hasPrefix("OR") {
                editor.moveCursor(to: MelsecCellRef(row: editor.ladder.endRow, column: 0))
            }
        }
        return editor.ladder
    }
}
