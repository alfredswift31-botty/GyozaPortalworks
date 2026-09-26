import Foundation

/// Where the editor inserts an element: at the start of a path (next to the
/// power rail, or at the start of a branch) or right after an element.
nonisolated enum S7InsertionPoint: Hashable, Sendable {
    case start(path: UUID)
    case after(element: UUID)
}

/// Which operand field of an element to edit.
nonisolated enum S7OperandSlot: Hashable, Sendable {
    /// Above a contact or coil; the bit of SR/RS; the edge bit of P_TRIG/N_TRIG.
    case operand
    /// Below a contact or coil: edge memory bit, duration, count, second compare operand.
    case second
    /// The instance above a timer, counter or FB box.
    case instance
}

// The editing operations of the LAD/FBD editor. They keep the network well
// formed (open branches last in their path, no one-branch groups); TIA's
// placement rules are left for the compiler to report, as TIA does.
nonisolated extension S7Network {
    // MARK: Inserting (Shift+F2, Shift+F3, Shift+F5, Shift+F7)

    /// Shift+F2 (normally open) / Shift+F3 (normally closed). Returns the new element.
    @discardableResult
    mutating func insertContact(_ kind: S7ContactKind = .normallyOpen, operand: String = "", at point: S7InsertionPoint) -> UUID? {
        let contact = S7Contact(kind, operand)
        return insert(.contact(contact), at: point) ? contact.id : nil
    }

    /// Shift+F7: an assignment coil (or any other coil).
    @discardableResult
    mutating func insertCoil(_ kind: S7CoilKind = .assign, operand: String = "", at point: S7InsertionPoint) -> UUID? {
        let coil = S7Coil(kind, operand)
        return insert(.coil(coil), at: point) ? coil.id : nil
    }

    /// Shift+F5: the empty box "??".
    @discardableResult
    mutating func insertEmptyBox(at point: S7InsertionPoint) -> UUID? {
        insertBox(S7Box(.empty), at: point)
    }

    @discardableResult
    mutating func insertBox(_ box: S7Box, at point: S7InsertionPoint) -> UUID? {
        insert(.box(box), at: point) ? box.id : nil
    }

    /// Inserts any element. After an open branch nothing can follow, so
    /// inserting there fails.
    @discardableResult
    mutating func insert(_ node: S7Node, at point: S7InsertionPoint) -> Bool {
        if rungs.isEmpty { rungs = [S7Path()] }
        return editPaths { path in
            switch point {
            case let .start(pathID):
                guard path.id == pathID else { return false }
                path.items.insert(node, at: 0)
                return true
            case let .after(elementID):
                guard let index = path.items.firstIndex(where: { $0.id == elementID }) else { return false }
                if case .fanOut = path.items[index] { return false }
                path.items.insert(node, at: index + 1)
                return true
            }
        }
    }

    // MARK: Branches (Shift+F8, Shift+F9)

    /// Shift+F8: opens a branch at the insertion point. Whatever followed the
    /// point stays on the main branch; returns the new, empty branch.
    @discardableResult
    mutating func openBranch(at point: S7InsertionPoint) -> UUID? {
        let branch = S7Path()
        let done = editPaths { path in
            let index: Int
            switch point {
            case let .start(pathID):
                guard path.id == pathID else { return false }
                index = 0
            case let .after(elementID):
                guard let found = path.items.firstIndex(where: { $0.id == elementID }) else { return false }
                index = found + 1
            }
            if index < path.items.count, case var .fanOut(group) = path.items[index], index == path.items.count - 1 {
                group.branches.append(branch)
                path.items[index] = .fanOut(group)
                return true
            }
            let rest = S7Path(Array(path.items[index...]))
            path.items.removeSubrange(index...)
            path.items.append(.fanOut(S7Branches([rest, branch])))
            return true
        }
        return done ? branch.id : nil
    }

    /// Shift+F9: closes an open branch onto an element of the main branch, so
    /// the branch runs in parallel with everything from the split up to and
    /// including that element (a seal-in contact around the start button).
    @discardableResult
    mutating func closeBranch(_ branchID: UUID, onto elementID: UUID) -> Bool {
        editPaths { path in
            guard let index = path.items.indices.last, case let .fanOut(group) = path.items[index],
                  group.branches.count >= 2,
                  let branchIndex = group.branches.firstIndex(where: { $0.id == branchID }), branchIndex > 0,
                  let target = group.branches[0].items.firstIndex(where: { $0.id == elementID })
            else { return false }
            let main = group.branches[0]
            let branch = group.branches[branchIndex]
            guard !branch.items.contains(where: { if case .fanOut = $0 { return true } else { return false } }) else { return false }
            let bridged = S7Path(Array(main.items[...target]), id: main.id)
            let parallel = S7Node.parallel(S7Branches([bridged, S7Path(branch.items, id: branch.id)]))
            var continuation = [parallel] + Array(main.items[(target + 1)...])
            var others = group.branches
            others.remove(at: branchIndex)
            others.removeFirst()
            path.items.removeLast()
            if others.isEmpty {
                path.items += continuation
            } else {
                continuation = [S7Node.fanOut(S7Branches([S7Path(continuation)] + others, id: group.id))]
                path.items += continuation
            }
            return true
        }
    }

    /// Adds a new rung from the power rail.
    @discardableResult
    mutating func addRung() -> UUID {
        let rung = S7Path()
        rungs.append(rung)
        return rung.id
    }

    /// Puts a new, empty branch in parallel with an element; returns the branch.
    @discardableResult
    mutating func addParallelBranch(around elementID: UUID) -> UUID? {
        let branch = S7Path()
        let done = editPaths { path in
            guard let index = path.items.firstIndex(where: { $0.id == elementID }) else { return false }
            if case var .parallel(group) = path.items[index] {
                group.branches.append(branch)
                path.items[index] = .parallel(group)
            } else {
                path.items[index] = .parallel(S7Branches([S7Path([path.items[index]]), branch]))
            }
            return true
        }
        return done ? branch.id : nil
    }

    // MARK: Deleting

    /// Deletes an element (a group deletes with all its branches).
    @discardableResult
    mutating func removeElement(_ elementID: UUID) -> Bool {
        let done = editPaths { path in
            guard let index = path.items.firstIndex(where: { $0.id == elementID }) else { return false }
            path.items.remove(at: index)
            return true
        }
        if done { normalize() }
        return done
    }

    /// Deletes a branch of a parallel or open-branch group, or a rung.
    @discardableResult
    mutating func removeBranch(_ pathID: UUID) -> Bool {
        if let index = rungs.firstIndex(where: { $0.id == pathID }) {
            rungs.remove(at: index)
            if rungs.isEmpty { rungs = [S7Path()] }
            return true
        }
        let done = editPaths { path in
            for index in path.items.indices {
                switch path.items[index] {
                case var .parallel(group):
                    guard let branch = group.branches.firstIndex(where: { $0.id == pathID }) else { continue }
                    group.branches.remove(at: branch)
                    path.items[index] = .parallel(group)
                    return true
                case var .fanOut(group):
                    guard let branch = group.branches.firstIndex(where: { $0.id == pathID }) else { continue }
                    group.branches.remove(at: branch)
                    path.items[index] = .fanOut(group)
                    return true
                default:
                    continue
                }
            }
            return false
        }
        if done { normalize() }
        return done
    }

    // MARK: Operands, instructions and types

    /// Types an operand into an element's field. Text is stored as typed.
    @discardableResult
    mutating func setOperand(_ text: String, of elementID: UUID, slot: S7OperandSlot = .operand) -> Bool {
        editNode(elementID) { node in
            switch node {
            case var .contact(contact):
                if slot == .second { contact.secondOperand = text } else { contact.operand = text }
                node = .contact(contact)
            case var .coil(coil):
                if slot == .second { coil.secondOperand = text } else { coil.operand = text }
                node = .coil(coil)
            case var .box(box):
                switch slot {
                case .instance: box.instance = text
                case .operand, .second: box.operand = text
                }
                node = .box(box)
            default:
                return false
            }
            return true
        }
    }

    /// Types an operand at a box pin (IN1, PT, OUT…).
    @discardableResult
    mutating func setPin(_ name: String, to text: String, of boxID: UUID) -> Bool {
        setPin(name, source: .operand(text), of: boxID)
    }

    /// Feeds a Bool box input from its own branch starting at the power rail;
    /// returns the branch.
    @discardableResult
    mutating func connectPinToBranch(_ name: String, of boxID: UUID) -> UUID? {
        let branch = S7Path()
        return setPin(name, source: .branch(branch), of: boxID) ? branch.id : nil
    }

    @discardableResult
    mutating func setPin(_ name: String, source: S7PinSource, of boxID: UUID) -> Bool {
        editNode(boxID) { node in
            guard case var .box(box) = node else { return false }
            if let index = box.inputs.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                box.inputs[index].source = source
            } else if let index = box.outputs.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                box.outputs[index].source = source
            } else if box.instruction.spec.outputs.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                box.outputs.append(S7Pin(name, source))
            } else {
                box.inputs.append(S7Pin(name, source))
            }
            node = .box(box)
            return true
        }
    }

    /// Picks the instruction of a box (typing a name into "??", or the box's
    /// instruction list). Pins with the same name keep their operands.
    @discardableResult
    mutating func setInstruction(_ instruction: S7Instruction, of boxID: UUID) -> Bool {
        editNode(boxID) { node in
            guard case let .box(old) = node else { return false }
            var box = S7Box(instruction, id: old.id)
            box.instance = instruction.needsInstance ? old.instance : ""
            box.operand = instruction.needsBitOperand ? old.operand : ""
            for index in box.inputs.indices {
                if let kept = old.input(box.inputs[index].name) { box.inputs[index].source = kept.source }
            }
            for index in box.outputs.indices {
                if let kept = old.output(box.outputs[index].name) { box.outputs[index].source = kept.source }
            }
            node = .box(box)
            return true
        }
    }

    /// Makes a box a call of a user FC/FB, with one pin per parameter.
    @discardableResult
    mutating func setCall(_ block: SiemensBlock, instance: String = "", of boxID: UUID) -> Bool {
        editNode(boxID) { node in
            guard case .box = node, block.kind != .organizationBlock else { return false }
            node = .box(S7Box.call(block, instance: instance))
            if case var .box(box) = node {
                box.id = boxID
                node = .box(box)
            }
            return true
        }
    }

    /// Picks the data type from the box's type list ("???" / "Auto" = nil).
    @discardableResult
    mutating func setDataType(_ type: PLCDataType?, second: PLCDataType? = nil, of elementID: UUID) -> Bool {
        editNode(elementID) { node in
            switch node {
            case var .box(box):
                box.dataType = type
                if second != nil { box.secondDataType = second }
                node = .box(box)
            case var .contact(contact):
                contact.dataType = type
                node = .contact(contact)
            default:
                return false
            }
            return true
        }
    }

    /// The yellow star: adds IN3, IN4… (or OUT2… on MOVE). Returns the new pin's name.
    @discardableResult
    mutating func addBoxInput(to boxID: UUID) -> String? {
        var added: String?
        _ = editNode(boxID) { node in
            guard case var .box(box) = node else { return false }
            let spec = box.instruction.spec
            if spec.expandableInputs || box.instruction == .calculate {
                let name = "IN\(box.inputs.count + 1)"
                box.inputs.append(S7Pin(name))
                added = name
            } else if spec.expandableOutputs {
                let name = "OUT\(box.outputs.count + 1)"
                box.outputs.append(S7Pin(name))
                added = name
            } else {
                return false
            }
            node = .box(box)
            return true
        }
        return added
    }

    @discardableResult
    mutating func setContactKind(_ kind: S7ContactKind, comparison: S7Comparison? = nil, of elementID: UUID) -> Bool {
        editNode(elementID) { node in
            guard case var .contact(contact) = node else { return false }
            contact.kind = kind
            if let comparison { contact.comparison = comparison }
            node = .contact(contact)
            return true
        }
    }

    @discardableResult
    mutating func setCoilKind(_ kind: S7CoilKind, of elementID: UUID) -> Bool {
        editNode(elementID) { node in
            guard case var .coil(coil) = node else { return false }
            coil.kind = kind
            node = .coil(coil)
            return true
        }
    }

    @discardableResult
    mutating func setExpression(_ expression: String, of boxID: UUID) -> Bool {
        editNode(boxID) { node in
            guard case var .box(box) = node else { return false }
            box.expression = expression
            node = .box(box)
            return true
        }
    }

    // MARK: Lookup

    /// An element anywhere in the network.
    func element(_ id: UUID) -> S7Node? {
        func search(_ path: S7Path) -> S7Node? {
            for node in path.items {
                if node.id == id { return node }
                switch node {
                case let .parallel(group), let .fanOut(group):
                    for branch in group.branches {
                        if let found = search(branch) { return found }
                    }
                case let .box(box):
                    for pin in box.inputs + box.outputs {
                        if case let .branch(branch) = pin.source, let found = search(branch) { return found }
                    }
                default:
                    break
                }
            }
            return nil
        }
        for rung in rungs {
            if let found = search(rung) { return found }
        }
        return nil
    }

    // MARK: Internals

    /// Applies `edit` to the first path (depth-first) for which it returns true.
    private mutating func editPaths(_ edit: (inout S7Path) -> Bool) -> Bool {
        for index in rungs.indices {
            if S7Network.edit(&rungs[index], edit) { return true }
        }
        return false
    }

    private static func edit(_ path: inout S7Path, _ body: (inout S7Path) -> Bool) -> Bool {
        if body(&path) { return true }
        for index in path.items.indices {
            switch path.items[index] {
            case var .parallel(group):
                for branch in group.branches.indices {
                    if edit(&group.branches[branch], body) {
                        path.items[index] = .parallel(group)
                        return true
                    }
                }
            case var .fanOut(group):
                for branch in group.branches.indices {
                    if edit(&group.branches[branch], body) {
                        path.items[index] = .fanOut(group)
                        return true
                    }
                }
            case var .box(box):
                for pin in box.inputs.indices {
                    guard case var .branch(branch) = box.inputs[pin].source else { continue }
                    if edit(&branch, body) {
                        box.inputs[pin].source = .branch(branch)
                        path.items[index] = .box(box)
                        return true
                    }
                }
                for pin in box.outputs.indices {
                    guard case var .branch(branch) = box.outputs[pin].source else { continue }
                    if edit(&branch, body) {
                        box.outputs[pin].source = .branch(branch)
                        path.items[index] = .box(box)
                        return true
                    }
                }
            default:
                break
            }
        }
        return false
    }

    private mutating func editNode(_ id: UUID, _ body: (inout S7Node) -> Bool) -> Bool {
        var changed = false
        _ = editPaths { path in
            guard let index = path.items.firstIndex(where: { $0.id == id }) else { return false }
            var node = path.items[index]
            if body(&node) {
                path.items[index] = node
                changed = true
            }
            return true
        }
        return changed
    }

    /// Removes empty branches of open groups and dissolves one-branch groups.
    private mutating func normalize() {
        func clean(_ path: S7Path) -> S7Path {
            var items: [S7Node] = []
            for node in path.items {
                switch node {
                case let .parallel(group):
                    let branches = group.branches.map(clean).filter { !$0.items.isEmpty }
                    if branches.count == 1 {
                        items += branches[0].items
                    } else if branches.count > 1 {
                        items.append(.parallel(S7Branches(branches, id: group.id)))
                    }
                case let .fanOut(group):
                    let branches = group.branches.map(clean).filter { !$0.items.isEmpty }
                    if branches.count == 1 {
                        items += branches[0].items
                    } else if branches.count > 1 {
                        items.append(.fanOut(S7Branches(branches, id: group.id)))
                    }
                case var .box(box):
                    for index in box.inputs.indices {
                        if case let .branch(branch) = box.inputs[index].source { box.inputs[index].source = .branch(clean(branch)) }
                    }
                    for index in box.outputs.indices {
                        if case let .branch(branch) = box.outputs[index].source { box.outputs[index].source = .branch(clean(branch)) }
                    }
                    items.append(.box(box))
                default:
                    items.append(node)
                }
            }
            return S7Path(items, id: path.id)
        }
        rungs = rungs.map(clean)
        if rungs.isEmpty { rungs = [S7Path()] }
    }
}

nonisolated extension S7Box {
    /// A call box for a user FC/FB: one input pin per Input/InOut and one output
    /// pin per Output, plus Ret_Val for an FC with a return value.
    static func call(_ block: SiemensBlock, instance: String = "") -> S7Box {
        let interface = block.interface
        let inputs = (interface.input + interface.inOut).map { S7Pin($0.name) }
        var outputs = interface.output.map { S7Pin($0.name) }
        if block.kind == .function, interface.returnType.caseInsensitiveCompare("Void") != .orderedSame {
            outputs.append(S7Pin("Ret_Val"))
        }
        return S7Box(.call, instance: block.kind == .functionBlock ? instance : "", calledBlock: block.name,
                     inputs: inputs, outputs: outputs)
    }
}
