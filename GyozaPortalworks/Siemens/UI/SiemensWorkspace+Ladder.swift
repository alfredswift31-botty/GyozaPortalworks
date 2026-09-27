import Foundation

/// LAD/FBD editor commands of the workspace.
extension SiemensWorkspace {
    func selection(inBlock id: UUID) -> S7Selection? {
        selections[id]
    }

    func select(_ selection: S7Selection?, inBlock id: UUID) {
        selections[id] = selection
        if let editing = editingOperand, editing.network != selection?.networkID {
            editingOperand = nil
        }
    }

    /// Runs an editor command on the block in the selected tab.
    func perform(_ command: S7EditorCommand) {
        guard let block = currentBlock else { return }
        perform(command, inBlock: block.id)
    }

    func perform(_ command: S7EditorCommand, inBlock id: UUID) {
        guard let block = block(id) else { return }
        switch command {
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            selections[id] = S7LadderEditing.move(selections[id], command, in: block)
            editingOperand = nil
        case .editOperand:
            beginEditingSelection(inBlock: id)
        default:
            guard block.language.usesNetworks || command == .insertNetwork else {
                lastMessage = "This command is only available in LAD and FBD."
                return
            }
            var result = S7EditResult(selection: selections[id], created: nil, changed: false)
            edit { project in
                guard let index = project.blocks.firstIndex(where: { $0.id == id }) else { return }
                result = S7LadderEditing.apply(command, to: &project.blocks[index], at: selections[id])
            }
            selections[id] = result.selection
            editingOperand = nil
            if !result.changed, command != .delete {
                lastMessage = "The instruction can't be inserted here."
            }
            if let created = result.created { afterInsert(created, inBlock: id) }
        }
    }

    /// After a box is placed: Call options for instances, then operand entry.
    private func afterInsert(_ element: UUID, inBlock id: UUID) {
        guard let block = block(id), case let .element(networkID, _)? = selections[id],
              let network = block.networks.first(where: { $0.id == networkID }), let node = network.element(element)
        else { return }
        switch node {
        case let .box(box):
            if let options = SiemensCallOptions.proposal(for: box, in: block, network: networkID, project: project) {
                callOptions = options
            }
        case .contact, .coil:
            editingOperand = S7OperandTarget(network: networkID, element: element, field: .slot(.operand))
        default:
            break
        }
    }

    /// Double-click an instruction in the Instructions task card.
    func insert(_ entry: S7CatalogEntry) {
        guard let block = currentBlock, block.language.usesNetworks else {
            lastMessage = "Open a LAD or FBD block to insert instructions."
            return
        }
        perform(S7InstructionCatalog.command(for: entry), inBlock: block.id)
        if case let .contact(.compare, comparison?) = entry.kind, case let .element(networkID, element)? = selections[block.id] {
            edit { project in
                guard let blockIndex = project.blocks.firstIndex(where: { $0.id == block.id }),
                      let networkIndex = project.blocks[blockIndex].networks.firstIndex(where: { $0.id == networkID })
                else { return }
                project.blocks[blockIndex].networks[networkIndex].setContactKind(.compare, comparison: comparison, of: element)
            }
        }
    }

    // MARK: Operands

    /// Enter / F2 / double-click: edit the selected element's main operand.
    func beginEditingSelection(inBlock id: UUID) {
        guard let block = block(id), case let .element(networkID, element)? = selections[id],
              let network = block.networks.first(where: { $0.id == networkID }), let node = network.element(element)
        else { return }
        let field: S7OperandField
        switch node {
        case .contact, .coil:
            field = .slot(.operand)
        case let .box(box):
            if box.instruction == .empty {
                field = .slot(.operand)
            } else if box.instruction.needsInstance || box.instruction == .call {
                field = .slot(.instance)
            } else if box.instruction.needsBitOperand {
                field = .slot(.operand)
            } else {
                field = .pin(box.inputs.first?.name ?? "EN")
            }
        default:
            return
        }
        editingOperand = S7OperandTarget(network: networkID, element: element, field: field)
    }

    func beginEditing(_ target: S7OperandTarget, inBlock id: UUID) {
        selections[id] = .element(network: target.network, id: target.element)
        editingOperand = target
    }

    func cancelOperandEditing() {
        editingOperand = nil
    }

    /// The text currently stored in an operand field.
    func operandText(_ target: S7OperandTarget, inBlock id: UUID) -> String {
        guard let network = block(id)?.networks.first(where: { $0.id == target.network }),
              let node = network.element(target.element)
        else { return "" }
        switch (node, target.field) {
        case let (.contact(contact), .slot(slot)): return slot == .second ? contact.secondOperand : contact.operand
        case let (.coil(coil), .slot(slot)): return slot == .second ? coil.secondOperand : coil.operand
        case let (.box(box), .slot(slot)):
            if box.instruction == .empty { return "" }
            return slot == .instance ? box.instance : box.operand
        case let (.box(box), .pin(name)):
            return (box.input(name) ?? box.output(name))?.source.operandText ?? ""
        default:
            return ""
        }
    }

    /// Enter in an operand field. Addresses become tags (a new "Tag_n" when
    /// none exists), names get their "#" or quotes; "??" boxes take an
    /// instruction or block name.
    func commitOperand(_ text: String, target: S7OperandTarget, inBlock id: UUID) {
        editingOperand = nil
        guard let block = block(id), let network = block.networks.first(where: { $0.id == target.network }),
              let node = network.element(target.element)
        else { return }
        if case let .box(box) = node, box.instruction == .empty {
            setInstruction(named: text, box: target.element, network: target.network, inBlock: id)
            return
        }
        edit { project in
            guard let blockIndex = project.blocks.firstIndex(where: { $0.id == id }),
                  let networkIndex = project.blocks[blockIndex].networks.firstIndex(where: { $0.id == target.network })
            else { return }
            let current = project.blocks[blockIndex]
            let isInstance = target.field == .slot(.instance)
            let resolved = isInstance ? Self.instanceText(text) : SiemensOperandEntry.resolve(text, block: current, project: &project)
            switch target.field {
            case let .slot(slot):
                project.blocks[blockIndex].networks[networkIndex].setOperand(resolved, of: target.element, slot: slot)
            case let .pin(name):
                project.blocks[blockIndex].networks[networkIndex].setPin(name, to: resolved, of: target.element)
            }
        }
    }

    /// Instance names are data blocks ("IEC_Timer_0_DB") or multi-instances (#Timer).
    private static func instanceText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("\"") { return trimmed }
        return "\"\(trimmed)\""
    }

    /// Typing a name into "??": an instruction (TON, ADD, CONVERT…) or a user FC/FB.
    func setInstruction(named rawName: String, box: UUID, network: UUID, inBlock id: UUID) {
        let name = rawName.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if let instruction = S7Instruction.named(name) {
            setInstruction(instruction, box: box, network: network, inBlock: id)
        } else if let called = project.block(named: name), called.kind != .organizationBlock {
            setCall(called, box: box, network: network, inBlock: id)
        } else if !name.isEmpty {
            alertMessage = "\"\(name)\" is not an instruction or block."
        }
    }

    func setInstruction(_ instruction: S7Instruction, box: UUID, network: UUID, inBlock id: UUID) {
        edit { project in
            guard let blockIndex = project.blocks.firstIndex(where: { $0.id == id }),
                  let networkIndex = project.blocks[blockIndex].networks.firstIndex(where: { $0.id == network })
            else { return }
            project.blocks[blockIndex].networks[networkIndex].setInstruction(instruction, of: box)
        }
        proposeCallOptions(box: box, network: network, inBlock: id)
    }

    func setCall(_ called: SiemensBlock, box: UUID, network: UUID, inBlock id: UUID) {
        edit { project in
            guard let blockIndex = project.blocks.firstIndex(where: { $0.id == id }),
                  let networkIndex = project.blocks[blockIndex].networks.firstIndex(where: { $0.id == network })
            else { return }
            project.blocks[blockIndex].networks[networkIndex].setCall(called, of: box)
        }
        proposeCallOptions(box: box, network: network, inBlock: id)
    }

    private func proposeCallOptions(box: UUID, network: UUID, inBlock id: UUID) {
        guard let block = block(id), let networkModel = block.networks.first(where: { $0.id == network }),
              case let .box(model)? = networkModel.element(box), model.instance.isEmpty
        else { return }
        callOptions = SiemensCallOptions.proposal(for: model, in: block, network: network, project: project)
    }

    /// OK in Call options.
    func confirmCallOptions(_ options: SiemensCallOptions) {
        guard let block = block(options.blockID) else {
            callOptions = nil
            return
        }
        if let problem = options.problem(in: project, block: block) {
            alertMessage = problem
            return
        }
        edit { project in _ = options.apply(to: &project) }
        callOptions = nil
    }

    func cancelCallOptions() {
        callOptions = nil
    }

    /// Picks a box's or comparator's data type ("???" → Int).
    func setDataType(_ type: PLCDataType?, second: PLCDataType? = nil, element: UUID, network: UUID, inBlock id: UUID) {
        edit { project in
            guard let blockIndex = project.blocks.firstIndex(where: { $0.id == id }),
                  let networkIndex = project.blocks[blockIndex].networks.firstIndex(where: { $0.id == network })
            else { return }
            project.blocks[blockIndex].networks[networkIndex].setDataType(type, second: second, of: element)
        }
    }

    /// Changes an element in place: contact type, coil type, comparison, expression…
    func editNetwork(_ network: UUID, inBlock id: UUID, _ change: (inout S7Network) -> Void) {
        edit { project in
            guard let blockIndex = project.blocks.firstIndex(where: { $0.id == id }),
                  let networkIndex = project.blocks[blockIndex].networks.firstIndex(where: { $0.id == network })
            else { return }
            change(&project.blocks[blockIndex].networks[networkIndex])
        }
    }

    /// Changes the block itself: properties, interface.
    func editBlock(_ id: UUID, _ change: (inout SiemensBlock) -> Void) {
        edit { project in
            guard let index = project.blocks.firstIndex(where: { $0.id == id }) else { return }
            change(&project.blocks[index])
        }
    }

    /// Block properties › General › Language. LAD↔FBD only; SCL can't switch.
    func setLanguage(_ language: SiemensLanguage, ofBlock id: UUID) {
        guard let block = block(id), block.language != language else { return }
        guard block.language.usesNetworks, language.usesNetworks else {
            alertMessage = "The programming language can only be switched between LAD and FBD."
            return
        }
        editBlock(id) { block in _ = block.switchLanguage(to: language) }
    }

    /// Whether the block's monitoring is on.
    func isMonitoring(_ id: UUID) -> Bool {
        monitoredBlocks.contains(id)
    }

    /// The LAD/FBD monitor of a block while it's monitored.
    func monitor(ofBlock id: UUID) -> S7BlockMonitor? {
        guard monitoredBlocks.contains(id), let name = block(id)?.name else { return nil }
        return cpu?.monitor(ofBlock: name)
    }

    /// The SCL trace of a block while it's monitored.
    func trace(ofBlock id: UUID) -> STTrace? {
        guard monitoredBlocks.contains(id), let name = block(id)?.name,
              let tracked = cpu?.image?.block(named: name)?.body as? S7TrackedBody
        else { return nil }
        return (tracked.inner as? STProgram)?.trace
    }
}
