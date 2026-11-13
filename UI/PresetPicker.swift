import ChromaNoiseKit
import SwiftData
import SwiftUI

/// All presets, visible at once as wrapping chip groups: the built-in
/// categories, then the user's saved sounds (long-press to rename or
/// delete) with a Save chip that stores the current sound under a new name,
/// and, while a saved sound is edited, an Update chip that overwrites it.
struct PresetPicker: View {
    let model: PlayerModel

    @Environment(\.modelContext) private var context
    @Query(sort: \StoredPhonon.createdAt) private var saved: [StoredPhonon]

    /// The name dialog on screen, if any — one at a time by construction.
    private enum NameEditor {
        case saving
        case renaming(StoredPhonon)

        var isSaving: Bool {
            if case .saving = self { true } else { false }
        }

        var renamingTarget: StoredPhonon? {
            if case .renaming(let stored) = self { stored } else { nil }
        }
    }

    @State private var nameEditor: NameEditor?
    @State private var draftName = ""
    /// The saved sound awaiting a delete confirmation.
    @State private var pendingDelete: StoredPhonon?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.presetGroups, id: \.name) { group in
                section(group.name) {
                    ForEach(group.phonons, id: \.name) { preset in
                        let selection = PlayerModel.PresetSelection.builtIn(name: preset.name)
                        Chip(title: preset.name, state: chipState(selection)) {
                            model.load(preset, as: selection)
                        }
                    }
                }
            }
            section("My Sounds") {
                ForEach(saved) { stored in
                    Chip(title: stored.name, state: chipState(.saved(id: stored.id))) {
                        if let phonon = stored.phonon {
                            model.load(phonon, as: .saved(id: stored.id))
                        }
                    } menu: {
                        Button("Rename", systemImage: "pencil") {
                            draftName = stored.name
                            nameEditor = .renaming(stored)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            pendingDelete = stored
                        }
                    }
                }
                if let edited = editedSavedSound {
                    actionChip("Update \u{201C}\(edited.name)\u{201D}", systemImage: "square.and.arrow.down") {
                        update(edited)
                    }
                    .accessibilityLabel("Update \(edited.name) with the edits")
                }
                actionChip(editedSavedSound == nil ? "Save" : "Save as New", systemImage: "plus") {
                    draftName = ""
                    nameEditor = .saving
                }
                .accessibilityLabel("Save current sound as new")
                if saved.isEmpty {
                    Text("Paint a sound, then save it here")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)   // centers on the Save chip's row
                }
            }
        }
        .padding(.vertical, 4)
        // Tick on switching sounds; a deleted sound's deselection stays silent.
        .sensoryFeedback(.selection, trigger: model.selection) { _, new in new != nil }
        .onAppear {
            // A restored selection may point at a sound deleted since.
            if case .saved(let id) = model.selection, !saved.contains(where: { $0.id == id }) {
                model.savedPresetDeleted(id: id)
            }
        }
        // Siri learns saved names for "Play <sound> in ChromaNoise".
        .onChange(of: saved.map(\.name)) {
            ChromaNoiseShortcuts.updateAppShortcutParameters()
        }
        .alert("Save Sound", isPresented: isShowing { $0.isSaving }) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save", action: saveCurrent)
                .disabled(trimmedDraft.isEmpty)
        }
        .alert("Rename Sound", isPresented: isShowing { $0.renamingTarget != nil },
               presenting: nameEditor?.renamingTarget) { stored in
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                stored.name = trimmedDraft
                persist()
                model.savedPresetRenamed(id: stored.id, to: trimmedDraft)
            }
            .disabled(trimmedDraft.isEmpty)
        }
        .confirmationDialog(pendingDelete.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { stored in
            Button("Delete", role: .destructive) { delete(stored) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can\u{2019}t be undone.")
        }
    }

    private func section<Chips: View>(_ title: String, @ViewBuilder chips: () -> Chips) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: 8) {
                chips()
            }
        }
    }

    private func chipState(_ selection: PlayerModel.PresetSelection) -> ChipState {
        guard model.selection == selection else { return .normal }
        return model.isEdited ? .edited : .selected
    }

    /// The selected saved sound, if it has unsaved edits.
    private var editedSavedSound: StoredPhonon? {
        guard model.isEdited, case .saved(let id) = model.selection else { return nil }
        return saved.first { $0.id == id }
    }

    /// An outlined capsule for an action, as opposed to a sound.
    private func actionChip(_ title: String, systemImage: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Not Label: in a flow layout's unconstrained measure it
            // can pick a stacked style and drop the title.
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(Capsule().strokeBorder(.tint, lineWidth: 1))
                .frame(minHeight: 44)   // full-size hit target, compact capsule
                .contentShape(Rectangle())
        }
        // Not the default style: in a Form row that makes a tap anywhere in
        // the row fire every such button (Update would also open Save).
        .buttonStyle(.borderless)
    }

    private func delete(_ stored: StoredPhonon) {
        model.savedPresetDeleted(id: stored.id)
        context.delete(stored)
        persist()
    }

    private func update(_ stored: StoredPhonon) {
        guard (try? stored.update(with: model.phonon)) != nil else { return }
        persist()
        model.savedPresetUpdated(id: stored.id)
    }

    /// Writes changes now: autosave is deferred, and a kill before it runs
    /// would lose the latest save, rename, update or delete.
    private func persist() {
        try? context.save()
    }

    private var trimmedDraft: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Presents one of the name dialogs; dismissing it clears `nameEditor`.
    private func isShowing(_ editor: @escaping (NameEditor) -> Bool) -> Binding<Bool> {
        Binding(get: { nameEditor.map(editor) ?? false },
                set: { if !$0 { nameEditor = nil } })
    }

    private func saveCurrent() {
        let name = trimmedDraft
        var phonon = model.phonon
        phonon.name = name
        guard !name.isEmpty, let stored = try? StoredPhonon(phonon: phonon, name: name) else { return }
        context.insert(stored)
        persist()
        model.load(phonon, as: .saved(id: stored.id))
    }
}

/// A preset chip: a compact capsule inside a full 44 pt hit target. Chips
/// with a menu (saved sounds) are a `Menu` whose tap is the primary action
/// and whose long-press opens the menu from the chip itself. (A
/// `.contextMenu` would instead lift the whole Form row, every chip in it.)
private struct Chip<MenuItems: View>: View {
    let title: String
    let state: ChipState
    let action: () -> Void
    let menu: MenuItems?

    init(title: String, state: ChipState, action: @escaping () -> Void,
         @ViewBuilder menu: () -> MenuItems) {
        self.title = title
        self.state = state
        self.action = action
        self.menu = menu()
    }

    var body: some View {
        Group {
            if let menu {
                Menu {
                    menu
                } label: {
                    label
                } primaryAction: {
                    action()
                }
                .menuIndicator(.hidden)
            } else {
                Button(action: action) { label }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state == .normal ? [] : .isSelected)
        .accessibilityValue(state == .edited ? "Edited" : "")
    }

    private var label: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            // Edited: still marked as the source, but lighter than selected.
            .overlay {
                if state == .edited {
                    Capsule().strokeBorder(.tint, lineWidth: 1)
                }
            }
            .frame(minHeight: 44)   // full-size hit target, compact capsule
            .contentShape(Rectangle())
    }

    private var foreground: AnyShapeStyle {
        switch state {
        case .normal: AnyShapeStyle(.primary)
        case .selected: AnyShapeStyle(.white)
        case .edited: AnyShapeStyle(.tint)
        }
    }

    private var background: AnyShapeStyle {
        switch state {
        case .normal: AnyShapeStyle(.fill.tertiary)
        case .selected: AnyShapeStyle(.tint)
        case .edited: AnyShapeStyle(.tint.opacity(0.12))
        }
    }
}

/// How a preset chip relates to the current sound.
private enum ChipState {
    case normal
    /// The current sound, unchanged.
    case selected
    /// The current sound's source, since painted over or reshaped.
    case edited
}

extension Chip where MenuItems == EmptyView {
    init(title: String, state: ChipState, action: @escaping () -> Void) {
        self.title = title
        self.state = state
        self.action = action
        self.menu = nil
    }
}
