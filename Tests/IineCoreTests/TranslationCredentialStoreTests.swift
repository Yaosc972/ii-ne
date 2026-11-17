import Foundation
import Testing
@testable import IineCore

struct TranslationCredentialStoreTests {
    @Test func newCredentialTakesPrecedenceWithoutReadingLegacy() {
        let keychain = MemoryKeychain()
        keychain.values = [TranslationCredentialStore.service: "current-key", LegacyBrandMigration.credentialService: "old-key"]
        #expect(keychain.store.load() == "current-key")
        #expect(keychain.reads == [TranslationCredentialStore.service])
        #expect(keychain.writes.isEmpty)
    }

    @Test func oldCredentialIsCopiedLazilyAndOriginalIsRetained() {
        let keychain = MemoryKeychain()
        keychain.values[LegacyBrandMigration.credentialService] = "old-key"
        #expect(keychain.store.load() == "old-key")
        #expect(keychain.values[TranslationCredentialStore.service] == "old-key")
        #expect(keychain.values[LegacyBrandMigration.credentialService] == "old-key")
        #expect(keychain.store.load() == "old-key")
        #expect(keychain.writes.count == 1)
    }

    @Test func migrationWriteFailurePreservesOldCredentialAndAllowsRetry() {
        let keychain = MemoryKeychain()
        keychain.values[LegacyBrandMigration.credentialService] = "old-key"
        keychain.canWrite = false
        #expect(keychain.store.load() == "old-key")
        #expect(keychain.values[TranslationCredentialStore.service] == nil)
        #expect(keychain.values[LegacyBrandMigration.credentialService] == "old-key")
        keychain.canWrite = true
        #expect(keychain.store.load() == "old-key")
        #expect(keychain.values[TranslationCredentialStore.service] == "old-key")
    }

    @Test func saveFailureDoesNotDeleteExistingCredential() {
        let keychain = MemoryKeychain()
        keychain.values[TranslationCredentialStore.service] = "current-key"
        keychain.canWrite = false
        #expect(!keychain.store.save("replacement-key"))
        #expect(keychain.values[TranslationCredentialStore.service] == "current-key")
        #expect(keychain.removals.isEmpty)
        #expect(!keychain.store.save(" \n "))
        #expect(keychain.values[TranslationCredentialStore.service] == "current-key")
    }

    @Test func clearingBothServicesPreventsLegacyCredentialResurrection() {
        let keychain = MemoryKeychain()
        keychain.values = [TranslationCredentialStore.service: "current-key", LegacyBrandMigration.credentialService: "old-key"]
        #expect(keychain.store.delete())
        #expect(keychain.store.load() == nil)
        #expect(keychain.values.isEmpty)
        #expect(keychain.store.delete())
    }

    @Test func unavailableCurrentCredentialDoesNotFallBackToLegacy() {
        let keychain = MemoryKeychain()
        keychain.values[LegacyBrandMigration.credentialService] = "old-key"
        keychain.unavailableServices.insert(TranslationCredentialStore.service)
        #expect(keychain.store.load() == nil)
        #expect(keychain.reads == [TranslationCredentialStore.service])
        #expect(keychain.writes.isEmpty)
    }

    @Test func clearingAttemptsBothServicesAndReportsFailure() {
        let keychain = MemoryKeychain()
        keychain.values = [TranslationCredentialStore.service: "current-key", LegacyBrandMigration.credentialService: "old-key"]
        keychain.unremovableServices.insert(TranslationCredentialStore.service)
        #expect(!keychain.store.delete())
        #expect(keychain.removals == [TranslationCredentialStore.service, LegacyBrandMigration.credentialService])
        #expect(keychain.values[TranslationCredentialStore.service] == "current-key")
        #expect(keychain.values[LegacyBrandMigration.credentialService] == nil)
    }
}

private final class MemoryKeychain {
    var values: [String: String] = [:]
    var reads: [String] = []
    var writes: [String] = []
    var removals: [String] = []
    var canWrite = true
    var unavailableServices: Set<String> = []
    var unremovableServices: Set<String> = []

    var store: TranslationCredentialStore {
        TranslationCredentialStore(keychain: .init(
            read: { service in
                self.reads.append(service)
                if self.unavailableServices.contains(service) { return .unavailable }
                return self.values[service].map(TranslationCredentialStore.Lookup.found) ?? .notFound
            },
            write: { service, value in
                self.writes.append(service)
                guard self.canWrite else { return false }
                self.values[service] = value
                return true
            },
            remove: { service in
                self.removals.append(service)
                guard !self.unremovableServices.contains(service) else { return false }
                self.values.removeValue(forKey: service)
                return true
            }
        ))
    }
}
