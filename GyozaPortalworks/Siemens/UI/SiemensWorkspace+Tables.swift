import Foundation

/// Tag table, interface, data block, watch and force table commands.
extension SiemensWorkspace {
    // MARK: Tags

    /// "<Add new>" in a tag table.
    func addTag(toTable id: UUID) {
        guard let index = project.tagTables.firstIndex(where: { $0.id == id }) else { return }
        edit { project in _ = project.addNewTag(toTable: index) }
    }

    func addConstant(toTable id: UUID) {
        guard let index = project.tagTables.firstIndex(where: { $0.id == id }) else { return }
        edit { project in
            let name = SiemensTagRules.uniqueName("Constant_1", in: project.tagTables)
            project.addConstant(SiemensUserConstant(name, .int, "0"), toTable: index)
        }
    }

    /// Edits a tag wherever it is; a new name that's taken gets "(1)".
    func updateTag(_ id: UUID, _ change: (inout SiemensTag) -> Void) {
        edit { project in
            for table in project.tagTables.indices {
                guard let index = project.tagTables[table].tags.firstIndex(where: { $0.id == id }) else { continue }
                var tag = project.tagTables[table].tags[index]
                let oldName = tag.name
                change(&tag)
                tag.address = SiemensTagRules.normalizedAddress(tag.address)
                project.tagTables[table].tags[index] = tag
                if tag.name != oldName { project.rename(row: id, to: tag.name) }
            }
        }
    }

    func updateConstant(_ id: UUID, _ change: (inout SiemensUserConstant) -> Void) {
        edit { project in
            for table in project.tagTables.indices {
                guard let index = project.tagTables[table].constants.firstIndex(where: { $0.id == id }) else { continue }
                var constant = project.tagTables[table].constants[index]
                let oldName = constant.name
                change(&constant)
                project.tagTables[table].constants[index] = constant
                if constant.name != oldName { project.rename(row: id, to: constant.name) }
            }
        }
    }

    func deleteTagRow(_ id: UUID) {
        edit { project in
            for table in project.tagTables.indices {
                project.tagTables[table].tags.removeAll { $0.id == id }
                project.tagTables[table].constants.removeAll { $0.id == id }
            }
        }
    }

    func setRetain(_ retain: Bool, forTag id: UUID) {
        edit { project in project.setRetain(retain, forTag: id) }
    }

    /// Monitor value of a tag while online.
    func monitorValue(ofOperand operand: String) -> String? {
        guard isOnline, let cpu else { return nil }
        switch cpu.monitorValue(operand) {
        case let .success(text): return text
        case .failure: return nil
        }
    }

    // MARK: Variables (interfaces, global DBs, PLC data types)

    /// Where a list of declarations lives.
    nonisolated enum VariableOwner: Hashable {
        case interface(block: UUID, section: VariableSection)
        case dataBlock(UUID)
        case dataType(UUID)
    }

    func variables(of owner: VariableOwner) -> [SiemensVariable] {
        switch owner {
        case let .interface(id, section): return block(id)?.interface.variables(in: section) ?? []
        case let .dataBlock(id): return project.dataBlocks.first { $0.id == id }?.members ?? []
        case let .dataType(id): return project.dataTypes.first { $0.id == id }?.members ?? []
        }
    }

    func updateVariables(of owner: VariableOwner, _ change: (inout [SiemensVariable]) -> Void) {
        edit { project in
            switch owner {
            case let .interface(id, section):
                guard let index = project.blocks.firstIndex(where: { $0.id == id }) else { return }
                var list = project.blocks[index].interface.variables(in: section)
                change(&list)
                project.blocks[index].interface.setVariables(list, in: section)
            case let .dataBlock(id):
                guard let index = project.dataBlocks.firstIndex(where: { $0.id == id }) else { return }
                change(&project.dataBlocks[index].members)
            case let .dataType(id):
                guard let index = project.dataTypes.firstIndex(where: { $0.id == id }) else { return }
                change(&project.dataTypes[index].members)
            }
        }
    }

    /// "<Add new>" in an interface section, DB or UDT: Tag_1… with Bool (TIA's default).
    func addVariable(to owner: VariableOwner) {
        let existing = variables(of: owner).map(\.name)
        let name = SiemensNaming.unique("Tag_1", among: existing, style: .counting)
        updateVariables(of: owner) { list in list.append(SiemensVariable(name, "Bool")) }
    }

    func updateVariable(_ id: UUID, of owner: VariableOwner, _ change: (inout SiemensVariable) -> Void) {
        updateVariables(of: owner) { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            let others = list.filter { $0.id != id }.map(\.name)
            change(&list[index])
            list[index].name = SiemensNaming.unique(list[index].name, among: others, style: .parenthesis)
        }
    }

    func deleteVariable(_ id: UUID, of owner: VariableOwner) {
        updateVariables(of: owner) { list in list.removeAll { $0.id == id } }
    }

    /// An FC's Return type.
    func setReturnType(_ type: String, ofBlock id: UUID) {
        editBlock(id) { block in block.interface.returnType = type }
    }

    // MARK: Watch table

    func updateWatchTable(_ id: UUID, _ change: (inout SiemensWatchTable) -> Void) {
        edit { project in
            guard let index = project.watchTables.firstIndex(where: { $0.id == id }) else { return }
            change(&project.watchTables[index])
        }
    }

    /// "<Add new>": a row; text starting with "//" makes a comment line.
    func addWatchRow(_ operand: String, to table: UUID) {
        let trimmed = operand.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        updateWatchTable(table) { table in
            if trimmed.hasPrefix("//") {
                table.rows.append(SiemensWatchRow("", comment: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                                                  isCommentLine: true))
            } else {
                table.rows.append(SiemensWatchRow(trimmed))
            }
        }
    }

    func updateWatchRow(_ row: UUID, in table: UUID, _ change: (inout SiemensWatchRow) -> Void) {
        updateWatchTable(table) { table in
            guard let index = table.rows.firstIndex(where: { $0.id == row }) else { return }
            change(&table.rows[index])
        }
    }

    func deleteWatchRow(_ row: UUID, in table: UUID) {
        updateWatchTable(table) { table in table.rows.removeAll { $0.id == row } }
    }

    // MARK: Force table

    func addForceRow(_ operand: String) {
        let trimmed = operand.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit { project in project.forceTable.append(SiemensForceRow(trimmed)) }
    }

    func updateForceRow(_ row: UUID, _ change: (inout SiemensForceRow) -> Void) {
        edit { project in
            guard let index = project.forceTable.firstIndex(where: { $0.id == row }) else { return }
            change(&project.forceTable[index])
        }
    }

    func deleteForceRow(_ row: UUID) {
        edit { project in project.forceTable.removeAll { $0.id == row } }
    }

    // MARK: Device

    func updateDevice(_ change: (inout SiemensProject) -> Void) {
        edit(change)
    }
}
