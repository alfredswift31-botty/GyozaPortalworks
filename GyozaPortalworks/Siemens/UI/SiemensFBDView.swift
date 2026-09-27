import AppKit
import SwiftUI

/// A piece of an FBD rung: consecutive contacts become one "&" box.
nonisolated enum S7FBDSegment: Identifiable {
    case and([S7Contact])
    case node(S7Node)

    var id: UUID {
        switch self {
        case let .and(contacts): return contacts.first?.id ?? UUID()
        case let .node(node): return node.id
        }
    }

    /// Groups a path's elements the way FBD draws them.
    static func segments(of path: S7Path) -> [S7FBDSegment] {
        var result: [S7FBDSegment] = []
        var pending: [S7Contact] = []
        for node in path.items {
            if case let .contact(contact) = node, contact.kind != .compare {
                pending.append(contact)
                continue
            }
            if !pending.isEmpty {
                result.append(.and(pending))
                pending = []
            }
            result.append(.node(node))
        }
        if !pending.isEmpty { result.append(.and(pending)) }
        return result
    }
}

/// The FBD rendering of a path: & and >=1 boxes, negation circles, = / S / R boxes.
struct S7FBDPathView: View {
    let path: S7Path
    let context: S7LadderContext

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            S7FBDStart(pathID: path.id, context: context)
            ForEach(S7FBDSegment.segments(of: path)) { segment in
                S7FBDSegmentView(segment: segment, context: context)
            }
        }
    }
}

private struct S7FBDStart: View {
    let pathID: UUID
    let context: S7LadderContext

    var body: some View {
        Rectangle()
            .fill(context.isRailSelected(pathID) ? SiemensColors.theme.accent : Color.secondary.opacity(0.3))
            .frame(width: 6, height: 22)
            .contentShape(Rectangle())
            .onTapGesture { context.selectRail(pathID) }
            .padding(.trailing, 4)
            .help("Insertion point")
            .accessibilityLabel("Insertion point")
    }
}

private struct S7FBDSegmentView: View {
    let segment: S7FBDSegment
    let context: S7LadderContext

    var body: some View {
        HStack(spacing: 0) {
            switch segment {
            case let .and(contacts):
                S7FBDLogicBox(symbol: "&", context: context, output: contacts.last.flatMap { context.status($0.id)?.output }) {
                    ForEach(contacts) { contact in
                        S7FBDInputRow(contact: contact, context: context)
                    }
                }
            case let .node(node):
                S7FBDNodeView(node: node, context: context)
            }
            S7FBDLine(signal: nil)
        }
    }
}

private struct S7FBDNodeView: View {
    let node: S7Node
    let context: S7LadderContext

    var body: some View {
        switch node {
        case let .contact(contact):
            S7ContactView(contact: contact, context: context)
        case let .coil(coil):
            S7FBDAssignmentBox(coil: coil, context: context)
        case let .box(box):
            S7BoxView(box: box, context: context, showsRungWires: false)
        case let .parallel(group):
            S7FBDLogicBox(symbol: ">=1", context: context, output: context.status(group.id)?.output) {
                ForEach(group.branches) { branch in
                    HStack(spacing: 0) {
                        S7FBDPathView(path: branch, context: context)
                        S7FBDLine(signal: branch.items.last.flatMap { context.status($0.id)?.output })
                    }
                }
            }
            .modifier(S7ElementChrome(id: group.id, context: context, label: "OR box"))
        case let .fanOut(group):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.branches) { branch in
                    S7FBDPathView(path: branch, context: context)
                }
            }
            .padding(.leading, 4)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.primary).frame(width: 1.2)
            }
        }
    }
}

/// An & or >=1 box with its input rows.
private struct S7FBDLogicBox<Inputs: View>: View {
    let symbol: String
    let context: S7LadderContext
    let output: S7Signal?
    @ViewBuilder let inputs: Inputs

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .trailing, spacing: 4) {
                inputs
            }
            VStack {
                Text(symbol)
                    .font(.system(size: 12, weight: .bold))
                    .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .frame(width: 44)
            .frame(minHeight: 34)
            .overlay(Rectangle().stroke(output == .satisfied ? SiemensColors.satisfied : Color.primary, lineWidth: 1.2))
            S7FBDLine(signal: output)
        }
    }
}

/// One input of an & box: the operand, with a negation circle for -|/|-.
private struct S7FBDInputRow: View {
    let contact: S7Contact
    let context: S7LadderContext

    var body: some View {
        let status = context.status(contact.id)
        HStack(spacing: 0) {
            S7OperandLabel(target: context.target(contact.id, .slot(.operand)), text: contact.operand, placeholderBool: true,
                           context: context, alignment: .trailing)
                .frame(width: 110)
            if contact.kind == .positiveEdge || contact.kind == .negativeEdge {
                Text(contact.kind == .positiveEdge ? "P" : "N")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 3)
                    .overlay(Rectangle().stroke(Color.primary, lineWidth: 1))
            }
            S7FBDLine(signal: status?.state, width: 14)
            if contact.kind == .normallyClosed || contact.kind == .invert {
                Circle()
                    .stroke(Color.primary, lineWidth: 1.2)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(height: 22)
        .modifier(S7ElementChrome(id: contact.id, context: context, label: contact.kind.title))
        .contextMenu {
            Button("Negate input") {
                context.workspace.editNetwork(context.networkID, inBlock: context.blockID) { network in
                    let kind: S7ContactKind = contact.kind == .normallyClosed ? .normallyOpen : .normallyClosed
                    _ = network.setContactKind(kind, of: contact.id)
                }
            }
            S7CommonElementMenu(id: contact.id, context: context)
        }
    }
}

/// "=", "S", "R", "P", "N" boxes with the operand above.
private struct S7FBDAssignmentBox: View {
    let coil: S7Coil
    let context: S7LadderContext

    var body: some View {
        let status = context.status(coil.id)
        VStack(spacing: 2) {
            S7OperandLabel(target: context.target(coil.id, .slot(.operand)), text: coil.operand,
                           placeholderBool: !coil.kind.isTimerCoil, context: context)
                .frame(width: 110, height: 18)
            HStack(spacing: 0) {
                if coil.kind == .negate {
                    Circle().stroke(Color.primary, lineWidth: 1.2).frame(width: 7, height: 7)
                }
                Text(symbol)
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 54, height: 30)
                    .overlay(Rectangle().stroke(status?.state == .satisfied ? SiemensColors.satisfied : Color.primary, lineWidth: 1.2))
            }
            if coil.kind.hasSecondOperand {
                S7OperandLabel(target: context.target(coil.id, .slot(.second)), text: coil.secondOperand,
                               placeholderBool: coil.kind == .positiveEdge || coil.kind == .negativeEdge, context: context)
                    .frame(width: 110, height: 18)
            }
        }
        .modifier(S7ElementChrome(id: coil.id, context: context, label: coil.kind.title))
        .contextMenu {
            S7CommonElementMenu(id: coil.id, context: context)
        }
    }

    private var symbol: String {
        switch coil.kind {
        case .assign, .negate: return "="
        case .set: return "S"
        case .reset: return "R"
        case .setBitField: return "SET_BF"
        case .resetBitField: return "RESET_BF"
        case .positiveEdge: return "P="
        case .negativeEdge: return "N="
        case .pulseTimer: return "TP"
        case .onDelayTimer: return "TON"
        case .offDelayTimer: return "TOF"
        case .accumulatingTimer: return "TONR"
        case .resetTimer: return "RT"
        case .presetTimer: return "PT"
        }
    }
}

/// A connection line in FBD.
private struct S7FBDLine: View {
    var signal: S7Signal?
    var width: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(SiemensColors.wire(signal)), style: SiemensColors.stroke(signal))
        }
        .frame(width: width, height: 10)
        .accessibilityHidden(true)
    }
}
