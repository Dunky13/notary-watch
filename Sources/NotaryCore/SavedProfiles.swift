import Foundation

public struct SavedNotaryProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public let credentials: NotaryProfile

    public init(id: UUID = UUID(), displayName: String, credentials: NotaryProfile) {
        self.id = id
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentials = credentials
    }
}

public enum ProfileStorageError: LocalizedError {
    case invalidCatalog, invalidName, missingProfile

    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: "Saved profiles could not be loaded. The saved data has been preserved."
        case .invalidName: "Enter a profile display name without line breaks or control characters."
        case .missingProfile: "This profile is no longer saved. Choose another profile."
        }
    }
}

public struct ProfileCatalog: Codable, Equatable, Sendable {
    public private(set) var version = 1
    public private(set) var profiles: [SavedNotaryProfile] = []
    public private(set) var activeProfileID: UUID?

    public init() {}
    public var active: SavedNotaryProfile? { profiles.first { $0.id == activeProfileID } }

    public mutating func remember(_ credentials: NotaryProfile, displayName: String? = nil) throws {
        guard !credentials.name.isEmpty else { throw NotaryError.invalidProfile }
        let label = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, !Self.validName(label) { throw ProfileStorageError.invalidName }
        if let index = profiles.firstIndex(where: { $0.credentials == credentials }) {
            if let label { profiles[index].displayName = label }
            activeProfileID = profiles[index].id
        } else {
            let saved = SavedNotaryProfile(displayName: label ?? credentials.name, credentials: credentials)
            profiles.append(saved)
            activeProfileID = saved.id
        }
        try validate()
    }

    public mutating func rename(_ id: UUID, to name: String) throws {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(label) else { throw ProfileStorageError.invalidName }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileStorageError.missingProfile }
        profiles[index].displayName = label
    }

    public mutating func remove(_ id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw ProfileStorageError.missingProfile }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = profiles.first?.id }
    }

    public func validate() throws {
        guard version == 1,
            Set(profiles.map(\.id)).count == profiles.count,
            profiles.allSatisfy({ Self.validName($0.displayName) && !$0.credentials.name.isEmpty }),
            profiles.isEmpty ? activeProfileID == nil : active != nil
        else {
            throw ProfileStorageError.invalidCatalog
        }
        for (index, profile) in profiles.enumerated() {
            if profiles.dropFirst(index + 1).contains(where: { $0.credentials == profile.credentials }) {
                throw ProfileStorageError.invalidCatalog
            }
        }
    }

    private static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Stores connection references only. Passwords remain owned by notarytool and Keychain.
@MainActor
public struct ProfileStore {
    public static let key = "notaryProfiles.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() throws -> ProfileCatalog {
        if defaults.object(forKey: Self.key) != nil {
            guard let data = defaults.data(forKey: Self.key) else { throw ProfileStorageError.invalidCatalog }
            do {
                let catalog = try JSONDecoder().decode(ProfileCatalog.self, from: data)
                try catalog.validate()
                return catalog
            } catch { throw ProfileStorageError.invalidCatalog }
        }
        var catalog = ProfileCatalog()
        if let name = defaults.string(forKey: "profile"), !name.isEmpty {
            try catalog.remember(NotaryProfile(name: name, keychainPath: defaults.string(forKey: "keychainPath") ?? ""))
            try save(catalog)
        }
        return catalog
    }

    public func save(_ catalog: ProfileCatalog) throws {
        try catalog.validate()
        let data = try JSONEncoder().encode(catalog)
        defaults.set(data, forKey: Self.key)
        // Keep the active connection readable by earlier local app versions.
        if let active = catalog.active {
            defaults.set(active.credentials.name, forKey: "profile")
            defaults.set(active.credentials.keychainPath, forKey: "keychainPath")
        } else {
            defaults.removeObject(forKey: "profile")
            defaults.removeObject(forKey: "keychainPath")
        }
    }
}
