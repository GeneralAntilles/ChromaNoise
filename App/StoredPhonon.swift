import ChromaNoiseKit
import Foundation
import SwiftData

/// A user-saved preset. The phonon itself is stored as one JSON blob, so
/// changes to `Phonon` (or its 32-float array) never need a schema migration;
/// `name` and `createdAt` live in columns for display and sorting.
@Model
final class StoredPhonon {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var data: Data

    init(phonon: Phonon, name: String) throws {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.data = try JSONEncoder().encode(phonon)
    }

    /// The saved sound, named by the (renameable) `name` column.
    var phonon: Phonon? {
        guard var p = try? JSONDecoder().decode(Phonon.self, from: data) else { return nil }
        p.name = name
        return p
    }
}
