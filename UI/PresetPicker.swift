import ChromaNoiseKit
import SwiftData
import SwiftUI

/// All presets, visible at once as wrapping chip groups: the built-in
/// categories, then the user's saved sounds (long-press to rename or
/// delete) with a Save chip that stores the current sound under a new name.
struct PresetPicker: View {
    let model: PlayerModel

    @Environment(\.modelContext) private var context
    @Query(sort: \StoredPhonon.createdAt) private var saved: [StoredPhonon]

    @State private var isNaming = false
    @State private var renaming: StoredPhonon?
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.presetGroups, id: \.name) { group in
                section(group.name) {
                    ForEach(group.phonons, id: \.name) { preset in
                        chip(preset.name, selected: model.selection == .builtIn(name: preset.name)) {
                            model.load(preset, as: .builtIn(name: preset.name))
                        }
                    }
                }
            }
            section("My Sounds") {
                ForEach(saved) { stored in
                    Chip(title: stored.name, selected: model.selection == .saved(id: stored.id)) {
                        if let phonon = stored.phonon {
                            model.load(phonon, as: .saved(id: stored.id))
                        }
                    } menu: {
                        Button("Rename", systemImage: "pencil") {
                            draftName = stored.name
                            renaming = stored
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.savedPresetDeleted(id: stored.id)
                            context.delete(stored)
                        }
                    }
                }
                Button {
                    draftName = ""
                    isNaming = true
                } label: {
                    // Not Label: in a flow layout's unconstrained measure it
                    // can pick a stacked style and drop the title.
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Save")
                    }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(.tint, lineWidth: 1))
                        .frame(minHeight: 44)   // full-size hit target, compact capsule
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Save current sound")
            }
        }
        .padding(.vertical, 4)
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
        .alert("Save Sound", isPresented: $isNaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save", action: saveCurrent)
                .disabled(trimmedDraft.isEmpty)
        }
        .alert("Rename Sound", isPresented: isRenaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let stored = renaming else { return }
                stored.name = trimmedDraft
                model.savedPresetRenamed(id: stored.id, to: trimmedDraft)
            }
            .disabled(trimmedDraft.isEmpty)
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

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Chip(title: title, selected: selected, action: action)
    }

    private var trimmedDraft: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func saveCurrent() {
        let name = trimmedDraft
        var phonon = model.phonon
        phonon.name = name
        guard !name.isEmpty, let stored = try? StoredPhonon(phonon: phonon, name: name) else { return }
        context.insert(stored)
        model.load(phonon, as: .saved(id: stored.id))
    }
}

/// A preset chip: a compact capsule inside a full 44 pt hit target. Chips
/// with a menu (saved sounds) are a `Menu` whose tap is the primary action
/// and whose long-press opens the menu from the chip itself. (A
/// `.contextMenu` would instead lift the whole Form row, every chip in it.)
private struct Chip<MenuItems: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    let menu: MenuItems?

    init(title: String, selected: Bool, action: @escaping () -> Void,
         @ViewBuilder menu: () -> MenuItems) {
        self.title = title
        self.selected = selected
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
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var label: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary),
                        in: Capsule())
            .frame(minHeight: 44)   // full-size hit target, compact capsule
            .contentShape(Rectangle())
    }
}

extension Chip where MenuItems == EmptyView {
    init(title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
        self.menu = nil
    }
}
