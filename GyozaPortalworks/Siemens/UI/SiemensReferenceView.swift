import SwiftUI

/// An exercise's reference solution drawn with the LAD editor's own rung
/// views: the tags to declare, any SCL block, then Main [OB1]'s networks
/// with their titles and comments. Display only: nothing here can be edited.
struct SiemensReferenceView: View {
    let project: SiemensProject
    /// The rung views read tags and blocks through a workspace; this one
    /// holds the reference project and is never shown or saved.
    @State private var workspace: SiemensWorkspace

    init(project: SiemensProject) {
        self.project = project
        let workspace = SiemensWorkspace(project: project, store: nil)
        workspace.startsSessionTimer = false
        _workspace = State(initialValue: workspace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReferenceSection(title: "PLC tags", detail: "Add these to the Default tag table first.") {
                tagTable
            }
            ForEach(project.blocks.filter { $0.language == .scl }) { block in
                ReferenceSection(title: "\(block.displayName) · SCL", detail: "Add new block › Function block, language SCL.") {
                    sclBlock(block)
                }
            }
            if let main = project.blocks.first(where: { $0.kind == .organizationBlock }) {
                ReferenceSection(title: "\(main.displayName) · LAD", detail: "One network per step, as in the LAD editor.") {
                    networks(of: main)
                }
            }
        }
    }

    // MARK: Tags

    private var tagTable: some View {
        let tags = SiemensReferenceSolutions.declaredTags(in: project)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                header("Name")
                header("Data type")
                header("Address")
            }
            ForEach(tags) { tag in
                GridRow {
                    cell(tag.name, monospaced: false)
                    cell(tag.dataType.rawValue, monospaced: false)
                    cell(tag.address, monospaced: true)
                }
            }
        }
        .font(.system(size: 11))
        .background(SiemensColors.theme.editorBackground)
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 150, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(SiemensColors.theme.paneHeader)
            .foregroundStyle(SiemensColors.theme.paneHeaderText)
    }

    private func cell(_ text: String, monospaced: Bool) -> some View {
        Text(text)
            .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 11))
            .frame(width: 150, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1) }
    }

    // MARK: SCL

    private func sclBlock(_ block: SiemensBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(interfaceSummary(block))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(block.source)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SiemensColors.theme.editorBackground)
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
        }
    }

    private func interfaceSummary(_ block: SiemensBlock) -> String {
        let sections: [(String, [SiemensVariable])] = [
            ("Input", block.interface.input), ("Output", block.interface.output),
            ("Static", block.interface.staticVariables), ("Temp", block.interface.temp),
        ]
        return sections.filter { !$0.1.isEmpty }.map { name, variables in
            "\(name): " + variables.map { "\($0.name) : \($0.dataType)" }.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    // MARK: Networks

    private func networks(of block: SiemensBlock) -> some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(block.networks.enumerated()), id: \.element.id) { index, network in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Network \(index + 1):")
                                .font(.system(size: 11, weight: .bold))
                            Text(network.title)
                                .font(.system(size: 11))
                        }
                        if !network.comment.isEmpty {
                            Text(network.comment)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 600, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SiemensRungs(network: network, isFBD: false,
                                     context: S7LadderContext(workspace: workspace, blockID: block.id, networkID: network.id, monitor: nil))
                    }
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.25)))
                }
            }
            .padding(10)
            .allowsHitTesting(false)
        }
        .background(SiemensColors.theme.editorBackground)
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
    }
}

/// A titled part of a reference solution.
struct ReferenceSection<Content: View>: View {
    let title: String
    var detail = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }
}
