//
//  RDIdentity+Deploy.swift
//  CatusshModule
//
//  ssh-copy-id: appends an identity's public key to ~/.ssh/authorized_keys
//  on servers, so the identity's key signs in to them. Shared by macOS and
//  iOS; each app picks the servers and reports the outcome.
//

import Foundation
import NSRemoteShell

public enum PublicKeyDeployment {
    /// Which servers took the key and which did not, by name.
    public struct Outcome: Sendable {
        public var succeeded: [String] = []
        public var failed: [String] = []
    }

    /// The remote command: makes ~/.ssh and authorized_keys with the
    /// permissions sshd requires, and appends the key unless it is there.
    public static func installCommand(for publicKey: String) -> String {
        let pub = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedKey = pub.replacingOccurrences(of: "'", with: "'\\''")
        return "umask 077 && mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && (grep -qxF '\(escapedKey)' ~/.ssh/authorized_keys || printf '%s\\n' '\(escapedKey)' >> ~/.ssh/authorized_keys)"
    }

    /// Installs `publicKey` on each server in turn, signing in as each
    /// server already does. Blocks; call off the main thread.
    public static func deploy(_ publicKey: String, to machines: [RDMachine.ID]) -> Outcome {
        let installCmd = installCommand(for: publicKey)
        var outcome = Outcome()
        for machineID in machines {
            let machine = CatusshStore.shared.workerMachine(for: machineID)
            guard machine.isNotPlaceholder() else { continue }
            let shell = NSRemoteShell.configured(for: machine, timeout: CatusshStore.shared.workerTimeoutNumber)
            let auth = shell.connectAndAuthenticate(
                identity: CatusshStore.shared.workerAssociatedIdentity(for: machine),
                autoIdentities: CatusshStore.shared.workerIdentitiesForAutoAuth
            )
            guard auth == .success else {
                outcome.failed.append(machine.name)
                shell.requestDisconnectAndWait()
                shell.destroyPermanently()
                continue
            }
            let rc = shell.beginExecute(
                withCommand: installCmd,
                withTimeout: 15,
                withOnCreate: {},
                withOutput: nil,
                withContinuationHandler: { true }
            )
            shell.requestDisconnectAndWait()
            shell.destroyPermanently()
            if rc == 0 {
                outcome.succeeded.append(machine.name)
            } else {
                outcome.failed.append(machine.name)
            }
        }
        return outcome
    }

    /// After a deployment every server took: the servers that sign in
    /// automatically now use the identity whose key they hold. Main thread.
    public static func adopt(identity: RDIdentity.ID, on machines: [RDMachine.ID]) {
        for machineID in machines {
            var machine = CatusshStore.shared.machineGroup[machineID]
            if machine.isNotPlaceholder(), machine.associatedIdentity == nil {
                machine.associatedIdentity = identity.uuidString
                CatusshStore.shared.machineGroup[machineID] = machine
            }
        }
    }
}

public extension IdentityDraft {
    /// Replaces the key pair with a new Ed25519 one, labelled with the
    /// comment, else user@catussh.
    mutating func generateEd25519KeyPair() {
        let label = comment.isEmpty
            ? (username.isEmpty ? "catussh" : "\(username)@catussh")
            : comment
        let pair = RDIdentity.generateEd25519KeyPair(comment: label)
        privateKey = pair.privateKey
        publicKey = pair.publicKey
        passphrase = ""
    }
}
