import SwiftUI

/// An exercise's reference solution drawn with the GX Works3 ladder
/// renderer: rung statements, device comments, step numbers and END, then
/// the conversion result (step and code). Display only.
struct MelsecReferenceView: View {
    let exercise: Exercise
    let ladder: MelsecLadder

    /// Fits the ladder's 12 columns into the Exercises window, like the editor pane.
    private static let width: CGFloat = 700

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReferenceSection(title: "ProgPou · Ladder", detail: "Statements (;) say what each rung does. Comments under a device come from the wiring.") {
                ScrollView(.horizontal) {
                    MelsecLadderCanvas(drawing: drawing, accent: VendorTheme.gxWorks3.accent)
                }
                .background(VendorTheme.gxWorks3.editorBackground)
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
            }
            ReferenceSection(title: "Conversion result", detail: "The instruction list Convert (F4) turns the ladder into, step by step.") {
                listing
            }
        }
    }

    private var listing: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
            GridRow {
                Text("Step").font(.system(size: 11, weight: .semibold))
                Text("Code").font(.system(size: 11, weight: .semibold))
            }
            ForEach(Array(MelsecConverter.convert(ladder).listing(.fx5u).enumerated()), id: \.offset) { _, line in
                GridRow {
                    Text("\(line.step)").foregroundStyle(.secondary)
                    Text(line.code)
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VendorTheme.gxWorks3.editorBackground)
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
    }

    private var drawing: MelsecLadderDrawing {
        let conversion = MelsecConverter.convert(ladder)
        var blockSteps: [Int: Int] = [:]
        for block in conversion.blockSteps {
            blockSteps[block.rows.lowerBound] = block.step
        }
        return MelsecLadderDrawing(
            ladder: ladder, layout: MelsecLadderLayout(ladder: ladder, availableWidth: Self.width),
            cursor: MelsecCellRef(row: 0, column: 0), isFocused: false, isMonitoring: false, errorCells: [], energized: [],
            values: [:], coilValues: [:], comments: comments, labels: [], blockSteps: blockSteps,
            endStep: conversion.succeeded ? conversion.endStep : nil, showsCursor: false)
    }

    /// The exercise's wiring as device comments: X0 "Start", Y0 "Motor".
    private var comments: [String: String] {
        var comments: [String: String] = [:]
        for assignment in exercise.io {
            comments[BoardAddressing.name(assignment.point, in: .gxWorks3)] = assignment.label
        }
        return comments
    }
}
