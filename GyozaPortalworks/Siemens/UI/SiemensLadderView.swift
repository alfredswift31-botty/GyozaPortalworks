import AppKit
import SwiftUI

/// Sizes of the LAD drawing. Every element puts the rung line at `lineY`
/// from its top, so elements in a row line up with top alignment.
nonisolated enum S7LadderMetrics {
    static let lineY: CGFloat = 32
    static let elementWidth: CGFloat = 86
    static let elementHeight: CGFloat = 60
    static let railStopWidth: CGFloat = 12
    static let boxWidth: CGFloat = 108
    static let pinColumnWidth: CGFloat = 96
    static let boxHeaderHeight: CGFloat = 20
    static let boxTitleHeight: CGFloat = 24
    static let boxTypeHeight: CGFloat = 16
    static let pinRowHeight: CGFloat = 22
}

/// What every element view needs: the workspace, where it is, and monitoring.
struct S7LadderContext {
    let workspace: SiemensWorkspace
    let blockID: UUID
    let networkID: UUID
    let monitor: S7BlockMonitor?
    /// The simulation's refresh counter. `monitor` is one object the CPU
    /// updates in place, so without a value that changes SwiftUI sees the
    /// same inputs and skips redrawing the networks while the CPU runs.
    var frame = 0

    var block: SiemensBlock? { workspace.block(blockID) }

    func status(_ id: UUID) -> S7ElementStatus? {
        monitor?.status(of: id)
    }

    func isSelected(_ id: UUID) -> Bool {
        workspace.selections[blockID] == .element(network: networkID, id: id)
    }

    func isRailSelected(_ path: UUID) -> Bool {
        workspace.selections[blockID] == .rail(network: networkID, path: path)
    }

    func select(_ id: UUID) {
        workspace.select(.element(network: networkID, id: id), inBlock: blockID)
    }

    func selectRail(_ path: UUID) {
        workspace.select(.rail(network: networkID, path: path), inBlock: blockID)
    }

    func target(_ element: UUID, _ field: S7OperandField) -> S7OperandTarget {
        S7OperandTarget(network: networkID, element: element, field: field)
    }
}

/// A rung line segment drawn at the rung height.
struct S7Wire: View {
    var signal: S7Signal?
    var width: CGFloat?

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: S7LadderMetrics.lineY))
            path.addLine(to: CGPoint(x: size.width, y: S7LadderMetrics.lineY))
            context.stroke(path, with: .color(SiemensColors.wire(signal)), style: SiemensColors.stroke(signal))
        }
        .frame(width: width, height: S7LadderMetrics.lineY + 4)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// A series of elements (a rung or a branch), starting with its cursor stop.
struct S7PathView: View {
    let path: S7Path
    let context: S7LadderContext
    var incoming: S7Signal?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            S7RailStop(pathID: path.id, context: context, signal: incoming)
            ForEach(path.items, id: \.id) { node in
                S7NodeView(node: node, context: context)
            }
        }
    }
}

/// The cursor stop at the start of a path: where Shift+F2 inserts in an empty rung or branch.
struct S7RailStop: View {
    let pathID: UUID
    let context: S7LadderContext
    var signal: S7Signal?

    var body: some View {
        S7Wire(signal: signal, width: S7LadderMetrics.railStopWidth)
            .frame(height: S7LadderMetrics.elementHeight, alignment: .top)
            .background(context.isRailSelected(pathID) ? SiemensColors.theme.selection : Color.clear)
            .overlay(alignment: .top) {
                if context.isRailSelected(pathID) {
                    Rectangle()
                        .stroke(SiemensColors.theme.accent, lineWidth: 1)
                        .frame(height: S7LadderMetrics.elementHeight)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { context.selectRail(pathID) }
            .accessibilityLabel("Insertion point")
            .accessibilityAddTraits(.isButton)
    }
}

/// One element of a path.
struct S7NodeView: View {
    let node: S7Node
    let context: S7LadderContext

    var body: some View {
        switch node {
        case let .contact(contact):
            S7ContactView(contact: contact, context: context)
        case let .coil(coil):
            S7CoilView(coil: coil, context: context)
        case let .box(box):
            S7BoxView(box: box, context: context, showsRungWires: true)
        case let .parallel(group):
            S7BranchGroupView(group: group, closed: true, context: context)
        case let .fanOut(group):
            S7BranchGroupView(group: group, closed: false, context: context)
        }
    }
}

/// Parallel (closed) or open branches, drawn with vertical connectors.
struct S7BranchGroupView: View {
    let group: S7Branches
    let closed: Bool
    let context: S7LadderContext

    var body: some View {
        let status = context.status(group.id)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(group.branches.enumerated()), id: \.element.id) { index, branch in
                S7BranchRow(branch: branch, index: index, count: group.branches.count, closed: closed,
                            context: context, signal: status?.input)
            }
        }
        .fixedSize()
        .background(context.isSelected(group.id) ? SiemensColors.theme.selection : Color.clear)
        .contextMenu {
            Button("Select branch group") { context.select(group.id) }
        }
    }
}

private struct S7BranchRow: View {
    let branch: S7Path
    let index: Int
    let count: Int
    let closed: Bool
    let context: S7LadderContext
    var signal: S7Signal?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            S7PathView(path: branch, context: context, incoming: signal)
            if closed {
                S7Wire(signal: branch.items.last.flatMap { context.status($0.id)?.output })
                    .frame(minWidth: 8)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            S7Connector(first: index == 0, last: index == count - 1, trailing: false, signal: signal)
        }
        .overlay(alignment: .trailing) {
            if closed {
                S7Connector(first: index == 0, last: index == count - 1, trailing: true, signal: signal)
            }
        }
    }
}

/// The vertical line joining branches.
private struct S7Connector: View {
    let first: Bool
    let last: Bool
    let trailing: Bool
    var signal: S7Signal?

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let x: CGFloat = trailing ? geometry.size.width - 0.75 : 0.75
                path.move(to: CGPoint(x: x, y: first ? S7LadderMetrics.lineY : 0))
                path.addLine(to: CGPoint(x: x, y: last ? S7LadderMetrics.lineY : geometry.size.height))
            }
            .stroke(SiemensColors.wire(signal), style: StrokeStyle(lineWidth: 1.5))
        }
        .frame(width: 2)
        .allowsHitTesting(false)
    }
}

/// A contact: -| |-, -|/|-, -|NOT|-, -|P|-, -|N|- or a comparator.
struct S7ContactView: View {
    let contact: S7Contact
    let context: S7LadderContext

    var body: some View {
        let status = context.status(contact.id)
        VStack(spacing: 0) {
            S7OperandLabel(target: context.target(contact.id, .slot(.operand)), text: contact.operand,
                           placeholderBool: contact.kind != .compare, context: context,
                           value: contact.kind == .compare ? status?.values["IN1"] : nil)
                .frame(height: 20)
                .opacity(contact.kind == .invert ? 0 : 1)
            S7ContactSymbol(contact: contact, status: status)
                .frame(width: S7LadderMetrics.elementWidth, height: 24)
            if contact.kind == .compare || contact.kind == .positiveEdge || contact.kind == .negativeEdge {
                S7OperandLabel(target: context.target(contact.id, .slot(.second)), text: contact.secondOperand,
                               placeholderBool: contact.kind != .compare, context: context,
                               value: contact.kind == .compare ? status?.values["IN2"] : nil)
                    .frame(height: 18)
            }
        }
        .frame(width: S7LadderMetrics.elementWidth, height: S7LadderMetrics.elementHeight, alignment: .top)
        .modifier(S7ElementChrome(id: contact.id, context: context, label: contact.kind.title))
        .contextMenu {
            S7ContactMenu(contact: contact, context: context)
        }
    }
}

/// The drawn symbol of a contact; the rung line crosses at mid-height (lineY).
private struct S7ContactSymbol: View {
    let contact: S7Contact
    let status: S7ElementStatus?

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            let left = size.width / 2 - 9
            let right = size.width / 2 + 9
            let inColor = SiemensColors.wire(status?.input)
            let outColor = SiemensColors.wire(status?.output)
            var incoming = Path()
            incoming.move(to: CGPoint(x: 0, y: y))
            incoming.addLine(to: CGPoint(x: left, y: y))
            context.stroke(incoming, with: .color(inColor), style: SiemensColors.stroke(status?.input))
            var outgoing = Path()
            outgoing.move(to: CGPoint(x: right, y: y))
            outgoing.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(outgoing, with: .color(outColor), style: SiemensColors.stroke(status?.output))
            let stateColor = status?.state == .satisfied ? SiemensColors.satisfied : Color.primary
            if contact.kind == .compare {
                let rect = CGRect(x: left - 8, y: 1, width: right - left + 16, height: size.height - 2)
                context.stroke(Path(rect), with: .color(stateColor), lineWidth: 1.2)
                return
            }
            var plates = Path()
            plates.move(to: CGPoint(x: left, y: 3))
            plates.addLine(to: CGPoint(x: left, y: size.height - 3))
            plates.move(to: CGPoint(x: right, y: 3))
            plates.addLine(to: CGPoint(x: right, y: size.height - 3))
            if contact.kind == .normallyClosed {
                plates.move(to: CGPoint(x: left + 3, y: size.height - 4))
                plates.addLine(to: CGPoint(x: right - 3, y: 4))
            }
            context.stroke(plates, with: .color(stateColor), lineWidth: 1.6)
        }
        .overlay {
            Text(symbolText)
                .font(.system(size: contact.kind == .compare ? 9 : 10, weight: .semibold))
        }
    }

    private var symbolText: String {
        switch contact.kind {
        case .normallyOpen, .normallyClosed: return ""
        case .invert: return "NOT"
        case .positiveEdge: return "P"
        case .negativeEdge: return "N"
        case .compare: return contact.comparison.rawValue + "\n" + (contact.dataType?.rawValue ?? "???")
        }
    }
}

private struct S7ContactMenu: View {
    let contact: S7Contact
    let context: S7LadderContext

    var body: some View {
        Menu("Contact type") {
            ForEach([S7ContactKind.normallyOpen, .normallyClosed, .positiveEdge, .negativeEdge, .invert], id: \.self) { kind in
                Button(kind.title) {
                    context.workspace.editNetwork(context.networkID, inBlock: context.blockID) { network in
                        _ = network.setContactKind(kind, of: contact.id)
                    }
                }
            }
        }
        if contact.kind == .compare {
            Menu("Comparison") {
                ForEach(S7Comparison.allCases, id: \.self) { comparison in
                    Button(comparison.label) {
                        context.workspace.editNetwork(context.networkID, inBlock: context.blockID) { network in
                            _ = network.setContactKind(.compare, comparison: comparison, of: contact.id)
                        }
                    }
                }
            }
            S7TypeMenu(title: "Data type", types: PLCDataType.allCases, element: contact.id, context: context)
        }
        S7CommonElementMenu(id: contact.id, context: context)
    }
}

/// A coil: -( )-, -(/)-, -(S)-, -(R)-, edge, bit field and timer coils.
struct S7CoilView: View {
    let coil: S7Coil
    let context: S7LadderContext

    var body: some View {
        let status = context.status(coil.id)
        VStack(spacing: 0) {
            S7OperandLabel(target: context.target(coil.id, .slot(.operand)), text: coil.operand,
                           placeholderBool: !coil.kind.isTimerCoil, context: context, value: status?.values["ET"])
                .frame(height: 20)
            S7CoilSymbol(coil: coil, status: status)
                .frame(width: S7LadderMetrics.elementWidth, height: 24)
            if coil.kind.hasSecondOperand {
                S7OperandLabel(target: context.target(coil.id, .slot(.second)), text: coil.secondOperand,
                               placeholderBool: coil.kind == .positiveEdge || coil.kind == .negativeEdge, context: context)
                    .frame(height: 18)
            }
        }
        .frame(width: S7LadderMetrics.elementWidth, height: S7LadderMetrics.elementHeight, alignment: .top)
        .modifier(S7ElementChrome(id: coil.id, context: context, label: coil.kind.title))
        .contextMenu {
            Menu("Coil type") {
                ForEach(S7CoilKind.allCases, id: \.self) { kind in
                    Button(kind.rawValue + "  " + kind.title) {
                        context.workspace.editNetwork(context.networkID, inBlock: context.blockID) { network in
                            _ = network.setCoilKind(kind, of: coil.id)
                        }
                    }
                }
            }
            S7CommonElementMenu(id: coil.id, context: context)
        }
    }
}

private struct S7CoilSymbol: View {
    let coil: S7Coil
    let status: S7ElementStatus?

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            let left = size.width / 2 - 13
            let right = size.width / 2 + 13
            var incoming = Path()
            incoming.move(to: CGPoint(x: 0, y: y))
            incoming.addLine(to: CGPoint(x: left, y: y))
            context.stroke(incoming, with: .color(SiemensColors.wire(status?.input)), style: SiemensColors.stroke(status?.input))
            var outgoing = Path()
            outgoing.move(to: CGPoint(x: right, y: y))
            outgoing.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(outgoing, with: .color(SiemensColors.wire(status?.output)), style: SiemensColors.stroke(status?.output))
            let color = status?.state == .satisfied ? SiemensColors.satisfied : Color.primary
            var arcs = Path()
            arcs.addArc(center: CGPoint(x: left + 11, y: y), radius: 11, startAngle: .degrees(140), endAngle: .degrees(220), clockwise: false)
            arcs.move(to: CGPoint(x: right - 11 + 11 * cos(Double.pi * 40 / 180), y: y - 11 * sin(Double.pi * 40 / 180)))
            arcs.addArc(center: CGPoint(x: right - 11, y: y), radius: 11, startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
            context.stroke(arcs, with: .color(color), lineWidth: 1.6)
        }
        .overlay {
            Text(letter)
                .font(.system(size: letter.count > 2 ? 8 : 10, weight: .semibold))
        }
    }

    private var letter: String {
        switch coil.kind {
        case .assign: return ""
        case .negate: return "/"
        case .set: return "S"
        case .reset: return "R"
        case .setBitField: return "SET_BF"
        case .resetBitField: return "RESET_BF"
        case .positiveEdge: return "P"
        case .negativeEdge: return "N"
        case .pulseTimer: return "TP"
        case .onDelayTimer: return "TON"
        case .offDelayTimer: return "TOF"
        case .accumulatingTimer: return "TONR"
        case .resetTimer: return "RT"
        case .presetTimer: return "PT"
        }
    }
}

/// Selection outline, tap and double-tap handling shared by all elements.
struct S7ElementChrome: ViewModifier {
    let id: UUID
    let context: S7LadderContext
    let label: String

    func body(content: Content) -> some View {
        content
            .background(context.isSelected(id) ? SiemensColors.theme.selection : Color.clear)
            .overlay {
                if context.isSelected(id) {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(SiemensColors.theme.accent, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                context.select(id)
                context.workspace.beginEditingSelection(inBlock: context.blockID)
            }
            .onTapGesture { context.select(id) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
    }
}

/// Menu items every element has.
struct S7CommonElementMenu: View {
    let id: UUID
    let context: S7LadderContext

    var body: some View {
        Divider()
        Button("Edit operand    F2") {
            context.select(id)
            context.workspace.beginEditingSelection(inBlock: context.blockID)
        }
        if context.monitor != nil {
            Menu("Modify") {
                Button("Modify to 1    Ctrl+Shift+1") {
                    context.select(id)
                    context.workspace.modifySelection(to: true)
                }
                Button("Modify to 0    Ctrl+Shift+9") {
                    context.select(id)
                    context.workspace.modifySelection(to: false)
                }
            }
        }
        Button("Delete    Del") {
            context.select(id)
            context.workspace.perform(.delete, inBlock: context.blockID)
        }
    }
}

/// Picks a data type for a box or comparator ("???" → Int).
struct S7TypeMenu: View {
    let title: String
    let types: [PLCDataType]
    let element: UUID
    let context: S7LadderContext
    var second = false

    var body: some View {
        Menu(title) {
            ForEach(types, id: \.self) { type in
                Button(type.rawValue) {
                    if second {
                        let first = currentFirst
                        context.workspace.setDataType(first, second: type, element: element, network: context.networkID, inBlock: context.blockID)
                    } else {
                        context.workspace.setDataType(type, element: element, network: context.networkID, inBlock: context.blockID)
                    }
                }
            }
        }
    }

    private var currentFirst: PLCDataType? {
        guard let network = context.block?.networks.first(where: { $0.id == context.networkID }),
              case let .box(box)? = network.element(element)
        else { return nil }
        return box.dataType
    }
}
