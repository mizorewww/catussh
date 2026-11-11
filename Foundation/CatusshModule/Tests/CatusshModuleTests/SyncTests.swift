//
//  SyncTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import CryptoKit
import XCTest

/// A device as sync sees it: its items, what it last knew, its passphrase and
/// the keys it has from iCloud Keychain.
private struct Device {
    var machines: [RDMachine] = []
    var identities: [RDIdentity] = []
    var snippets: [RDSnippet] = []
    var portForwards: [RDPortForward] = []
    var folders: [RDFolder] = []
    var settings: [String: SyncSetting] = [:]
    var state = SyncState()
    var passphrase: String? = "correct horse battery"
    var key: SyncCipher.Key?
    /// Off by default: most tests are about the passphrase, as before.
    var usesKeychain = false
    var keychain: [SyncKey] = []
    var syncsIdentities = true
    var syncsSnippets = true
    /// The key the last round made, as it would be put in iCloud Keychain.
    var madeKey: SyncKey?

    /// One round against `cloud`, applying what it says.
    @discardableResult
    mutating func sync(_ cloud: inout Data?, at now: Date, replacing: Bool = false) -> SyncOutcome {
        var input = SyncInput(
            machines: machines, identities: identities, state: state, passphrase: passphrase, remote: cloud,
            key: key
        )
        input.snippets = snippets
        input.portForwards = portForwards
        input.folders = folders
        input.settings = settings
        input.keychainKeys = keychain
        input.usesKeychain = usesKeychain
        input.syncsIdentities = syncsIdentities
        input.syncsSnippets = syncsSnippets
        input.replacesRemote = replacing
        input.now = now
        input.rounds = 1000
        input.minimumRounds = 1000
        let outcome = SyncSession.run(input)
        madeKey = nil
        guard case let .done(done) = outcome else { return outcome }
        apply(done.machines, to: &machines)
        apply(done.identities, to: &identities)
        apply(done.snippets, to: &snippets)
        apply(done.portForwards, to: &portForwards)
        for change in done.folders {
            switch change {
            case let .put(name, folder):
                folders.removeAll { $0.name == name }
                folders.append(folder)
            case let .remove(name):
                folders.removeAll { $0.name == name }
            }
        }
        for change in done.settings {
            switch change {
            case let .put(name, value): settings[name] = value
            case let .remove(name): settings[name] = nil
            }
        }
        state = done.state
        key = done.key
        if let made = done.newKey {
            madeKey = made
            keychain.insert(made, at: 0)
        }
        if let upload = done.upload { cloud = upload }
        return outcome
    }

    private func apply<Value: Identifiable>(_ changes: [SyncChange<Value>], to items: inout [Value])
        where Value.ID == UUID
    {
        for change in changes {
            switch change {
            case let .put(value):
                items.removeAll { $0.id == value.id }
                items.append(value)
            case let .remove(id):
                items.removeAll { $0.id == id }
            }
        }
    }
}

/// What a version 1 build stored: sealed under a passphrase, with no word of
/// which kind of key.
private func versionOneEnvelope(_ document: SyncDocument, passphrase: String) throws -> Data {
    let key = SyncCipher.key(passphrase: passphrase, salt: SyncCipher.newSalt(), rounds: 1000)
    let plain = try JSONEncoder().encode(document)
    let packed = try (plain as NSData).compressed(using: .zlib) as Data
    let sealed = try XCTUnwrap(CryptoKit.AES.GCM.seal(packed, using: key.key, authenticating: SyncCipher.context).combined)
    let envelope = SyncEnvelope(version: 1, salt: key.salt, rounds: key.rounds, sealed: sealed)
    return try JSONEncoder().encode(envelope)
}

private func envelope(_ cloud: Data?) throws -> SyncEnvelope {
    try JSONDecoder().decode(SyncEnvelope.self, from: XCTUnwrap(cloud))
}

private func uploaded(_ outcome: SyncOutcome) -> Bool {
    if case let .done(done) = outcome { return done.upload != nil }
    return false
}

final class SyncTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func time(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func machine(_ name: String) -> RDMachine {
        RDMachine(remoteAddress: "192.0.2.1", remotePort: "22", name: name)
    }

    func testASecondDeviceReceivesWhatTheFirstHas() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha"), machine("beta")]
        mac.identities = [RDIdentity(username: "root", password: "secret")]

        XCTAssertTrue(uploaded(mac.sync(&cloud, at: time(0))))
        XCTAssertFalse(uploaded(phone.sync(&cloud, at: time(10))), "nothing of its own to add")

        XCTAssertEqual(Set(phone.machines.map(\.name)), ["alpha", "beta"])
        XCTAssertEqual(phone.identities.first?.password, "secret")
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(20))), "a round with no changes uploads nothing")
    }

    func testBothDevicesKeepWhatEachAdded() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        phone.machines = [machine("beta")]

        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(10))
        mac.sync(&cloud, at: time(20))

        XCTAssertEqual(Set(mac.machines.map(\.name)), ["alpha", "beta"])
        XCTAssertEqual(Set(phone.machines.map(\.name)), ["alpha", "beta"])
    }

    func testTheLaterEditWins() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        mac.machines[0].name = "from the Mac"
        phone.machines[0].name = "from the phone"
        mac.sync(&cloud, at: time(10))
        phone.sync(&cloud, at: time(20))
        mac.sync(&cloud, at: time(30))

        XCTAssertEqual(mac.machines.map(\.name), ["from the phone"])
        XCTAssertEqual(phone.machines.map(\.name), ["from the phone"])
    }

    func testADeletionReachesTheOtherDevice() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha"), machine("beta")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        phone.machines.removeAll { $0.name == "alpha" }
        phone.sync(&cloud, at: time(10))
        mac.sync(&cloud, at: time(20))
        XCTAssertEqual(mac.machines.map(\.name), ["beta"])

        // And is not brought back by a round that changes nothing.
        phone.sync(&cloud, at: time(30))
        XCTAssertEqual(phone.machines.map(\.name), ["beta"])
    }

    func testAnEditAfterADeletionBringsTheItemBack() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        phone.machines = []
        phone.sync(&cloud, at: time(10))
        mac.machines[0].comment = "still needed"
        mac.sync(&cloud, at: time(20))
        phone.sync(&cloud, at: time(30))

        XCTAssertEqual(phone.machines.map(\.comment), ["still needed"])
    }

    func testConnectingDoesNotCountAsAnEdit() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        mac.machines[0].lastConnection = time(5)
        mac.machines[0].lastBanner = "Welcome"
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(10))))

        // Another device's edit leaves this device's own record of use alone.
        phone.machines[0].name = "renamed"
        phone.sync(&cloud, at: time(20))
        mac.sync(&cloud, at: time(30))
        XCTAssertEqual(mac.machines[0].name, "renamed")
        XCTAssertEqual(mac.machines[0].lastBanner, "Welcome")
    }

    func testEditsAtTheSameInstantSettleOnOne() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        mac.machines[0].name = "one"
        phone.machines[0].name = "two"
        mac.sync(&cloud, at: time(10))
        phone.sync(&cloud, at: time(10))
        mac.sync(&cloud, at: time(10))
        XCTAssertEqual(mac.machines.map(\.name), phone.machines.map(\.name))
        XCTAssertFalse(uploaded(phone.sync(&cloud, at: time(11))))
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(12))))
    }

    func testAWrongPassphraseReadsNothingAndWritesNothing() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        let stored = cloud

        phone.passphrase = "something else"
        phone.machines = [machine("beta")]
        guard case .locked = phone.sync(&cloud, at: time(10)) else { return XCTFail("expected locked") }
        XCTAssertEqual(cloud, stored)
        XCTAssertEqual(phone.machines.map(\.name), ["beta"])
    }

    func testReplacingPutsThisDevicesDataUnderANewKey() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))

        phone.passphrase = "a new passphrase"
        phone.machines = [machine("beta")]
        phone.sync(&cloud, at: time(10), replacing: true)

        guard case .locked = mac.sync(&cloud, at: time(20)) else { return XCTFail("expected locked") }
        mac.passphrase = "a new passphrase"
        mac.sync(&cloud, at: time(30))
        XCTAssertEqual(Set(mac.machines.map(\.name)), ["alpha", "beta"])
    }

    func testChangingThePassphraseKeepsWhatAnotherDeviceStored() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha"), machine("beta")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        // The phone deletes one and adds one; the Mac has not synced since.
        phone.machines.removeAll { $0.name == "alpha" }
        phone.machines.append(machine("gamma"))
        phone.sync(&cloud, at: time(10))

        mac.passphrase = "a new passphrase"
        mac.sync(&cloud, at: time(20), replacing: true)
        XCTAssertEqual(Set(mac.machines.map(\.name)), ["beta", "gamma"])

        guard case .locked = phone.sync(&cloud, at: time(30)) else { return XCTFail("expected locked") }
        phone.passphrase = "a new passphrase"
        phone.sync(&cloud, at: time(40))
        XCTAssertEqual(Set(phone.machines.map(\.name)), ["beta", "gamma"])
    }

    func testTurningSyncOffAndOnDoesNotUndoWhatHappenedMeanwhile() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha"), machine("beta")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        // The phone stops syncing; the Mac renames one server and deletes the other.
        phone.state = SyncState()
        mac.machines.removeAll { $0.name == "beta" }
        mac.machines[0].name = "renamed"
        mac.sync(&cloud, at: time(10))

        phone.machines.append(machine("gamma"))
        phone.sync(&cloud, at: time(20))
        mac.sync(&cloud, at: time(30))
        XCTAssertEqual(Set(phone.machines.map(\.name)), ["renamed", "gamma"])
        XCTAssertEqual(Set(mac.machines.map(\.name)), ["renamed", "gamma"])
    }

    func testAClockThatRunsAheadDoesNotUndoALaterEdit() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))

        // The phone's clock is an hour ahead.
        phone.machines[0].name = "from the phone"
        phone.sync(&cloud, at: time(3600 + 10))
        mac.sync(&cloud, at: time(20))
        mac.machines[0].name = "later, from the Mac"
        mac.sync(&cloud, at: time(30))
        phone.sync(&cloud, at: time(3600 + 40))
        XCTAssertEqual(mac.machines.map(\.name), ["later, from the Mac"])
        XCTAssertEqual(phone.machines.map(\.name), ["later, from the Mac"])
    }

    func testAnExpiredDeletionIsNotPassedBackAndForth() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha"), machine("beta")]
        mac.sync(&cloud, at: time(0))
        phone.sync(&cloud, at: time(1))
        mac.machines.removeAll { $0.name == "alpha" }
        mac.sync(&cloud, at: time(10))
        phone.sync(&cloud, at: time(20))

        // The Mac forgets the deletion; the phone, whose clock is behind, has not yet.
        let later = 10 + SyncMerge.tombstoneLifetime + 1
        XCTAssertTrue(uploaded(mac.sync(&cloud, at: time(later))))
        XCTAssertFalse(uploaded(phone.sync(&cloud, at: time(later - 3600))))
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(later + 10))))
        XCTAssertEqual(phone.machines.map(\.name), ["beta"])
    }

    func testAKindThatIsNotSyncedIsLeftAlone() {
        var cloud: Data?
        var mac = Device(), phone = Device()
        mac.machines = [machine("alpha")]
        mac.identities = [RDIdentity(username: "root", password: "secret")]
        mac.sync(&cloud, at: time(0))

        phone.syncsIdentities = false
        phone.identities = [RDIdentity(username: "local", password: "stays here")]
        phone.machines = [machine("beta")]
        phone.sync(&cloud, at: time(10))
        XCTAssertEqual(phone.identities.map(\.username), ["local"])

        // The identities stored by the Mac are still there for a third device.
        var pad = Device()
        pad.sync(&cloud, at: time(20))
        XCTAssertEqual(pad.identities.map(\.username), ["root"])
        XCTAssertEqual(Set(pad.machines.map(\.name)), ["alpha", "beta"])
    }

    func testWhatIsStoredDoesNotShowItsContents() throws {
        var cloud: Data?
        var mac = Device()
        mac.machines = [machine("alpha-server-name")]
        mac.identities = [RDIdentity(username: "root", password: "a-very-secret-password")]
        mac.sync(&cloud, at: time(0))

        let stored = try XCTUnwrap(cloud)
        let text = String(decoding: stored, as: UTF8.self)
        XCTAssertFalse(text.contains("alpha-server-name"))
        XCTAssertFalse(text.contains("a-very-secret-password"))
        XCTAssertFalse(text.contains("192.0.2.1"))
    }

    func testTamperedOrForeignDataIsRefused() throws {
        var cloud: Data?
        var mac = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))

        var envelope = try JSONDecoder().decode(SyncEnvelope.self, from: XCTUnwrap(cloud))
        envelope.sealed[envelope.sealed.count - 1] ^= 1
        var tampered: Data? = try JSONEncoder().encode(envelope)
        guard case .locked = mac.sync(&tampered, at: time(10)) else { return XCTFail("expected locked") }

        // Fewer rounds than allowed: not derived, not written under.
        envelope.rounds = 1
        var weak: Data? = try JSONEncoder().encode(envelope)
        guard case .unreadable = mac.sync(&weak, at: time(20)) else { return XCTFail("expected unreadable") }

        envelope.version = SyncEnvelope.currentVersion + 1
        var newer: Data? = try JSONEncoder().encode(envelope)
        guard case .newer = mac.sync(&newer, at: time(30)) else { return XCTFail("expected newer") }

        var garbage: Data? = Data("not an envelope".utf8)
        guard case .unreadable = mac.sync(&garbage, at: time(40)) else { return XCTFail("expected unreadable") }
    }

    func testOpenTellsAWrongPassphraseFromDamagedData() throws {
        let plain = Data("the document".utf8)
        let key = SyncCipher.key(passphrase: "the passphrase", salt: SyncCipher.newSalt(), rounds: 1000)
        let sealed = try SyncCipher.seal(plain, with: key)
        let envelope = try JSONDecoder().decode(SyncEnvelope.self, from: sealed)
        XCTAssertEqual(try SyncCipher.open(envelope, with: key), plain)

        XCTAssertEqual(envelope.version, 2)
        XCTAssertEqual(envelope.kind, .passphrase)
        let wrong = SyncCipher.key(passphrase: "another passphrase", salt: key.salt, rounds: key.rounds)
        XCTAssertThrowsError(try SyncCipher.open(envelope, with: wrong)) {
            XCTAssertEqual($0 as? SyncCipher.OpenError, .wrongPassphrase)
        }

        // Sealed under the right key, but what is inside is not a document:
        // it opens and then fails to decompress.
        var damaged = envelope
        damaged.sealed = try XCTUnwrap(CryptoKit.AES.GCM.seal(
            Data("not compressed".utf8), using: key.key, authenticating: SyncCipher.context(for: envelope)
        ).combined)
        XCTAssertThrowsError(try SyncCipher.open(damaged, with: key)) {
            XCTAssertEqual($0 as? SyncCipher.OpenError, .corruptedData)
        }
    }

    func testDamagedStoredDataIsUnreadableNotLocked() throws {
        var cloud: Data?
        var mac = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))

        var envelope = try JSONDecoder().decode(SyncEnvelope.self, from: XCTUnwrap(cloud))
        let key = try XCTUnwrap(mac.key)
        envelope.sealed = try XCTUnwrap(CryptoKit.AES.GCM.seal(
            Data("not compressed".utf8), using: key.key, authenticating: SyncCipher.context(for: envelope)
        ).combined)
        var damaged: Data? = try JSONEncoder().encode(envelope)
        guard case .unreadable = mac.sync(&damaged, at: time(10)) else {
            return XCTFail("expected unreadable, not locked: another passphrase cannot help")
        }
    }

    func testAnOldDeletionIsForgotten() {
        var cloud: Data?
        var mac = Device()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        mac.machines = []
        mac.sync(&cloud, at: time(10))
        XCTAssertEqual(mac.state.machines.count, 1)
        mac.sync(&cloud, at: time(10 + SyncMerge.tombstoneLifetime + 1))
        XCTAssertTrue(mac.state.machines.isEmpty)
    }

    // MARK: - The key in iCloud Keychain

    /// A device with iCloud Keychain and no passphrase: what sync is now.
    private func keychainDevice() -> Device {
        var device = Device()
        device.passphrase = nil
        device.usesKeychain = true
        return device
    }

    func testTheFirstDeviceMakesAKeyAndTheNextWaitsForIt() throws {
        var cloud: Data?
        var mac = keychainDevice(), phone = keychainDevice()
        mac.machines = [machine("alpha")]

        XCTAssertTrue(uploaded(mac.sync(&cloud, at: time(0))))
        let made = try XCTUnwrap(mac.madeKey)
        let stored = try envelope(cloud)
        XCTAssertEqual(stored.version, SyncEnvelope.currentVersion)
        XCTAssertEqual(stored.kind, .keychain)
        XCTAssertEqual(stored.keyID, made.id)
        XCTAssertNil(stored.salt)

        // Before iCloud Keychain brings the key: nothing read, nothing written.
        let before = cloud
        guard case .waitingForKey = phone.sync(&cloud, at: time(10)) else { return XCTFail("expected waiting") }
        XCTAssertEqual(cloud, before)
        XCTAssertNil(phone.madeKey, "a device that waits does not make a key of its own")

        phone.keychain = mac.keychain
        XCTAssertFalse(uploaded(phone.sync(&cloud, at: time(20))))
        XCTAssertEqual(phone.machines.map(\.name), ["alpha"])
        XCTAssertNil(phone.madeKey)
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(30))))
    }

    func testTwoDevicesThatMakeAKeyAtOnceBothGoOn() throws {
        var cloud: Data?
        var mac = keychainDevice(), phone = keychainDevice()
        mac.machines = [machine("alpha")]
        phone.machines = [machine("beta")]

        // Both find nothing stored; the phone's upload lands last.
        var macCloud: Data?
        mac.sync(&macCloud, at: time(0))
        phone.sync(&cloud, at: time(1))
        XCTAssertNotEqual(mac.madeKey?.id, phone.madeKey?.id)

        // iCloud Keychain brings each the other's key: two items, both kept.
        let keys = phone.keychain + mac.keychain
        mac.keychain = keys
        phone.keychain = keys
        mac.sync(&cloud, at: time(10))
        phone.sync(&cloud, at: time(20))
        XCTAssertEqual(Set(mac.machines.map(\.name)), ["alpha", "beta"])
        XCTAssertEqual(Set(phone.machines.map(\.name)), ["alpha", "beta"])
    }

    func testAPassphraseFromVersionOneMovesToTheKeychain() throws {
        let alpha = machine("alpha")
        var document = SyncDocument()
        document.machines[alpha.id.uuidString] = .init(modified: time(0), value: alpha)
        var cloud: Data? = try versionOneEnvelope(document, passphrase: "correct horse battery")

        // A device that never had the passphrase cannot read it, and is asked.
        var pad = keychainDevice()
        guard case .locked = pad.sync(&cloud, at: time(5)) else { return XCTFail("expected locked") }

        // One that has it opens it and seals it again under a key in iCloud
        // Keychain, though nothing changed.
        var mac = Device()
        mac.usesKeychain = true
        XCTAssertTrue(uploaded(mac.sync(&cloud, at: time(10))))
        XCTAssertEqual(mac.machines.map(\.name), ["alpha"])
        let made = try XCTUnwrap(mac.madeKey)
        XCTAssertEqual(try envelope(cloud).kind, .keychain)
        XCTAssertEqual(try envelope(cloud).keyID, made.id)

        // The others then need nothing but the key.
        pad.keychain = mac.keychain
        pad.sync(&cloud, at: time(20))
        XCTAssertEqual(pad.machines.map(\.name), ["alpha"])
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(30))))
    }

    func testWithoutTheKeychainVersionOneIsReadAndLeftAsItIs() throws {
        let alpha = machine("alpha")
        var document = SyncDocument()
        document.machines[alpha.id.uuidString] = .init(modified: time(0), value: alpha)
        var cloud: Data? = try versionOneEnvelope(document, passphrase: "correct horse battery")

        var mac = Device()
        XCTAssertFalse(uploaded(mac.sync(&cloud, at: time(10))), "nothing to change, so nothing written")
        XCTAssertEqual(mac.machines.map(\.name), ["alpha"])
        XCTAssertEqual(try envelope(cloud).version, 1)

        // A change is written as version 2, still under the passphrase.
        mac.machines.append(machine("beta"))
        mac.sync(&cloud, at: time(20))
        XCTAssertEqual(try envelope(cloud).version, 2)
        XCTAssertEqual(try envelope(cloud).kind, .passphrase)
    }

    func testWithNeitherKeychainNorPassphraseNothingIsWritten() {
        var cloud: Data?
        var mac = Device()
        mac.passphrase = nil
        mac.machines = [machine("alpha")]
        guard case .needsPassphrase = mac.sync(&cloud, at: time(0)) else { return XCTFail("expected needsPassphrase") }
        XCTAssertNil(cloud)
    }

    func testAPassphraseChosenForWantOfTheKeychainStaysAPassphrase() throws {
        var cloud: Data?
        var old = Device()
        old.machines = [machine("alpha")]
        old.sync(&cloud, at: time(0))

        // A device with iCloud Keychain and the passphrase reads it, and
        // leaves it to the passphrase: the other device has nothing else.
        var mac = Device()
        mac.usesKeychain = true
        mac.sync(&cloud, at: time(10))
        mac.machines.append(machine("beta"))
        mac.sync(&cloud, at: time(20))
        XCTAssertEqual(try envelope(cloud).kind, .passphrase)
        XCTAssertNil(mac.madeKey)
        old.sync(&cloud, at: time(30))
        XCTAssertEqual(Set(old.machines.map(\.name)), ["alpha", "beta"])
    }

    func testResettingTheKeyKeepsWhatIsStoredAndTheOthersFollow() throws {
        var cloud: Data?
        var mac = keychainDevice(), phone = keychainDevice()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))
        let first = try XCTUnwrap(mac.madeKey)
        phone.keychain = mac.keychain
        phone.sync(&cloud, at: time(1))

        // The phone adds one; the Mac has not synced since, and resets.
        phone.machines.append(machine("beta"))
        phone.sync(&cloud, at: time(10))
        XCTAssertTrue(uploaded(mac.sync(&cloud, at: time(20), replacing: true)))
        let second = try XCTUnwrap(mac.madeKey)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try envelope(cloud).keyID, second.id)
        XCTAssertEqual(Set(mac.machines.map(\.name)), ["alpha", "beta"])

        // The phone waits for the new key, then goes on.
        guard case .waitingForKey = phone.sync(&cloud, at: time(30)) else { return XCTFail("expected waiting") }
        phone.keychain = [second]
        phone.machines.append(machine("gamma"))
        phone.sync(&cloud, at: time(40))
        mac.sync(&cloud, at: time(50))
        XCTAssertEqual(Set(phone.machines.map(\.name)), ["alpha", "beta", "gamma"])
        XCTAssertEqual(Set(mac.machines.map(\.name)), ["alpha", "beta", "gamma"])
    }

    func testReplacingWhatCannotBeReadPutsThisDevicesDataUnderANewKey() throws {
        var cloud: Data?
        var mac = keychainDevice(), phone = keychainDevice()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))

        // The phone never got that key.
        phone.machines = [machine("beta")]
        guard case .waitingForKey = phone.sync(&cloud, at: time(10)) else { return XCTFail("expected waiting") }
        phone.sync(&cloud, at: time(20), replacing: true)
        let made = try XCTUnwrap(phone.madeKey)
        XCTAssertEqual(try envelope(cloud).keyID, made.id)

        mac.keychain = [made]
        mac.sync(&cloud, at: time(30))
        XCTAssertEqual(Set(mac.machines.map(\.name)), ["alpha", "beta"])
    }

    func testTamperingWithTheHeaderIsRefused() throws {
        var cloud: Data?
        var mac = keychainDevice()
        mac.machines = [machine("alpha")]
        mac.sync(&cloud, at: time(0))

        // Said to be sealed under a passphrase: it does not open as one.
        var swapped = try envelope(cloud)
        swapped.sealer = .passphrase
        swapped.salt = SyncCipher.newSalt()
        swapped.rounds = 1000
        mac.passphrase = "correct horse battery"
        var tampered: Data? = try JSONEncoder().encode(swapped)
        guard case .locked = mac.sync(&tampered, at: time(10)) else { return XCTFail("expected locked") }

        var noID = try envelope(cloud)
        noID.keyID = nil
        var missing: Data? = try JSONEncoder().encode(noID)
        guard case .unreadable = mac.sync(&missing, at: time(20)) else { return XCTFail("expected unreadable") }
    }

    // MARK: - Snippets, port forwards, folders and settings

    func testSnippetsAndPortForwardsSyncLikeServers() {
        var cloud: Data?
        var mac = keychainDevice(), phone = keychainDevice()
        let server = machine("alpha")
        mac.machines = [server]
        mac.snippets = [RDSnippet(name: "uptime", code: "uptime"), RDSnippet(name: "disk", code: "df -h")]
        mac.portForwards = [RDPortForward(bindPort: 8080, targetHost: "localhost", targetPort: 80, usingMachine: server.id)]
        mac.sync(&cloud, at: time(0))
        phone.keychain = mac.keychain
        phone.sync(&cloud, at: time(1))
        XCTAssertEqual(Set(phone.snippets.map(\.name)), ["uptime", "disk"])
        XCTAssertEqual(phone.portForwards.first?.usingMachine, server.id)

        // Edited on one side, deleted on the other.
        phone.snippets.removeAll { $0.name == "disk" }
        mac.snippets[0].code = "uptime -p"
        mac.portForwards[0].bindPort = 9090
        phone.sync(&cloud, at: time(10))
        mac.sync(&cloud, at: time(20))
        phone.sync(&cloud, at: time(30))
        XCTAssertEqual(mac.snippets.map(\.name), ["uptime"])
        XCTAssertEqual(phone.snippets.map(\.code), ["uptime -p"])
        XCTAssertEqual(phone.portForwards.map(\.bindPort), [9090])
    }

    func testFoldersOfTheSameNameAreOneFolder() {
        var cloud: Data?
        var mac = keychainDevice(), phone = keychainDevice()
        mac.folders = [RDFolder(name: "Work")]
        phone.folders = [RDFolder(name: "Work"), RDFolder(name: "Home")]
        let phoneWork = phone.folders[0].id

        mac.sync(&cloud, at: time(0))
        phone.keychain = mac.keychain
        phone.sync(&cloud, at: time(10))
        mac.sync(&cloud, at: time(20))
        XCTAssertEqual(mac.folders.map(\.name).sorted(), ["Home", "Work"])
        XCTAssertEqual(phone.folders.map(\.name).sorted(), ["Home", "Work"])
        XCTAssertEqual(phone.folders.first { $0.name == "Work" }?.id, phoneWork, "each device keeps its own id")

        // A rename is a folder gone and one made.
        mac.folders = [RDFolder(name: "Office"), RDFolder(name: "Home", source: .uuRemote(userID: "42"))]
        mac.sync(&cloud, at: time(30))
        phone.sync(&cloud, at: time(40))
        XCTAssertEqual(phone.folders.map(\.name).sorted(), ["Home", "Office"])
        XCTAssertEqual(phone.folders.first { $0.name == "Home" }?.source, .uuRemote(userID: "42"))
    }

    func testSettingsSyncOneByOne() {
        var cloud: Data?
        var mac = keychainDevice(), phone = keychainDevice()
        mac.settings = ["timeout": .int(10), "appearance": .string("dark"), "terminal.theme": .strings(["Dracula"])]
        // A new device's defaults do not override what is stored.
        phone.settings = ["timeout": .int(5)]
        mac.sync(&cloud, at: time(0))
        phone.keychain = mac.keychain
        phone.sync(&cloud, at: time(10))
        XCTAssertEqual(phone.settings, mac.settings)

        // Different settings changed on each side both stay.
        mac.settings["terminal.font-size"] = .strings(["15"])
        phone.settings["timeout"] = .int(20)
        phone.settings["terminal.theme"] = nil
        mac.sync(&cloud, at: time(20))
        phone.sync(&cloud, at: time(30))
        mac.sync(&cloud, at: time(40))
        let expected: [String: SyncSetting] = [
            "timeout": .int(20), "appearance": .string("dark"), "terminal.font-size": .strings(["15"]),
        ]
        XCTAssertEqual(mac.settings, expected)
        XCTAssertEqual(phone.settings, expected)
    }

    func testAKindThatIsNotSyncedHereIsPassedOn() {
        var cloud: Data?
        var mac = keychainDevice(), phone = keychainDevice(), pad = keychainDevice()
        mac.snippets = [RDSnippet(name: "uptime", code: "uptime")]
        mac.sync(&cloud, at: time(0))

        phone.keychain = mac.keychain
        phone.syncsSnippets = false
        phone.snippets = [RDSnippet(name: "local", code: "ls")]
        phone.machines = [machine("beta")]
        phone.sync(&cloud, at: time(10))
        XCTAssertEqual(phone.snippets.map(\.name), ["local"])

        pad.keychain = mac.keychain
        pad.sync(&cloud, at: time(20))
        XCTAssertEqual(pad.snippets.map(\.name), ["uptime"])
        XCTAssertEqual(pad.machines.map(\.name), ["beta"])
    }

    func testWhatAnEarlierVersionStoredStillReads() throws {
        // Servers and identities only, as version 1 wrote them, and the
        // state it kept.
        let json = #"{"identities":{},"machines":{}}"#
        let document = try JSONDecoder().decode(SyncDocument.self, from: Data(json.utf8))
        XCTAssertTrue(document.snippets.isEmpty && document.settings.isEmpty && document.folders.isEmpty)
        let state = try JSONDecoder().decode(SyncState.self, from: Data(#"{"identities":{},"machines":{}}"#.utf8))
        XCTAssertTrue(state.portForwards.isEmpty)
        let old = try JSONDecoder().decode(
            SyncEnvelope.self, from: Data(#"{"version":1,"salt":"AAAAAAAAAAA=","rounds":1000,"sealed":""}"#.utf8)
        )
        XCTAssertEqual(old.kind, .passphrase)
    }

    /// Not a check so much as a measure: how much of iCloud's 1 MB a large
    /// collection takes once compressed and sealed.
    func testALargeCollectionFitsInTheStore() throws {
        var cloud: Data?
        var mac = keychainDevice()
        func random(_ count: Int) -> String {
            Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        }
        mac.machines = (0 ..< 300).map { index in
            var server = RDMachine(
                remoteAddress: "10.0.\(index / 256).\(index % 256)", remotePort: "22", name: "server-\(index)"
            )
            server.comment = "Rack \(index % 12), managed by the infrastructure team"
            return server
        }
        // Passwords and private keys are random, and do not compress.
        mac.identities = (0 ..< 50).map { index in
            RDIdentity(username: "user\(index)", password: random(24), privateKey: random(2400))
        }
        mac.snippets = (0 ..< 200).map { RDSnippet(name: "snippet \($0)", code: "for f in *; do echo $f; done # \($0)") }
        mac.portForwards = (0 ..< 50).map {
            RDPortForward(bindPort: 8000 + $0, targetHost: "localhost", targetPort: 80, usingMachine: mac.machines[$0].id)
        }
        mac.folders = (0 ..< 20).map { RDFolder(name: "Folder \($0)") }
        mac.settings = Dictionary(uniqueKeysWithValues: (0 ..< 60).map { ("terminal.key-\($0)", SyncSetting.strings(["value"])) })
        mac.sync(&cloud, at: time(0))

        let size = try XCTUnwrap(cloud).count
        print("Sync: 300 servers, 50 identities with keys, 200 snippets, 50 forwards, 20 folders, 60 settings: \(size) bytes")
        XCTAssertLessThan(size, 1_000_000)
    }
}
