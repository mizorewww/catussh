//
//  SSHCommandReaderTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import XCTest

final class SSHCommandReaderTests: XCTestCase {
    func testBasicCommand() {
        let reader = SSHCommandReader(command: "ssh root@example.com")
        XCTAssertEqual(reader?.username, "root")
        XCTAssertEqual(reader?.remoteAddress, "example.com")
        XCTAssertEqual(reader?.remotePort, "22")
    }

    func testCustomPort() {
        let reader = SSHCommandReader(command: "ssh ubuntu@10.0.0.8 -p 2222")
        XCTAssertEqual(reader?.remotePort, "2222")
        XCTAssertEqual(reader?.command, "ssh ubuntu@10.0.0.8 -p 2222")
    }

    func testRejectsAnonymousLogin() {
        XCTAssertNil(SSHCommandReader(command: "ssh example.com"))
    }

    func testRejectsMissingParts() {
        XCTAssertNil(SSHCommandReader(command: "ssh @example.com"))
        XCTAssertNil(SSHCommandReader(command: "ssh root@"))
        XCTAssertNil(SSHCommandReader(command: "ssh"))
        XCTAssertNil(SSHCommandReader(command: "mosh root@example.com"))
    }

    func testRejectsInvalidPort() {
        XCTAssertNil(SSHCommandReader(command: "ssh root@example.com -p abc"))
        XCTAssertNil(SSHCommandReader(command: "ssh root@example.com -p 70000"))
    }

    func testToleratesRepeatedSpaces() {
        let reader = SSHCommandReader(command: "ssh  root@example.com  -p  2222")
        XCTAssertEqual(reader?.username, "root")
        XCTAssertEqual(reader?.remotePort, "2222")
    }

    func testPreservesCase() {
        let reader = SSHCommandReader(command: "ssh Root@Example.COM -p 2222")
        XCTAssertEqual(reader?.username, "Root")
        XCTAssertEqual(reader?.remoteAddress, "Example.COM")
        XCTAssertEqual(reader?.remotePort, "2222")
    }

    func testUppercasePrefix() {
        let reader = SSHCommandReader(command: "SSH root@example.com")
        XCTAssertEqual(reader?.username, "root")
        XCTAssertEqual(reader?.remoteAddress, "example.com")
    }

    func testPortBeforeHost() {
        let reader = SSHCommandReader(command: "ssh -p 2222 ubuntu@10.0.0.8")
        XCTAssertEqual(reader?.username, "ubuntu")
        XCTAssertEqual(reader?.remoteAddress, "10.0.0.8")
        XCTAssertEqual(reader?.remotePort, "2222")
        XCTAssertEqual(reader?.command, "ssh ubuntu@10.0.0.8 -p 2222")
    }

    func testRejectsUnknownTokens() {
        XCTAssertNil(SSHCommandReader(command: "ssh root@example.com -v"))
        XCTAssertNil(SSHCommandReader(command: "ssh -i key.pem root@example.com"))
        XCTAssertNil(SSHCommandReader(command: "ssh -p 2222"))
        XCTAssertNil(SSHCommandReader(command: "ssh root@example.com -p"))
        XCTAssertNil(SSHCommandReader(command: "ssh -p abc root@example.com"))
    }

    func testRoundTrip() {
        let original = "ssh deploy@192.168.1.10 -p 2200"
        let reader = SSHCommandReader(command: original)
        XCTAssertEqual(reader?.command, original)
    }

    func testColonPortOnBareTarget() {
        let reader = SSHCommandReader(command: "ssh root@example.com:2222")
        XCTAssertEqual(reader?.username, "root")
        XCTAssertEqual(reader?.remoteAddress, "example.com")
        XCTAssertEqual(reader?.remotePort, "2222")
        XCTAssertEqual(reader?.command, "ssh root@example.com -p 2222")
    }

    func testRejectsBrokenColonPort() {
        XCTAssertNil(SSHCommandReader(command: "ssh root@example.com:"))
        XCTAssertNil(SSHCommandReader(command: "ssh root@example.com:abc"))
        XCTAssertNil(SSHCommandReader(command: "ssh root@example.com:70000"))
    }

    func testColonStaysInHostWhenNotALoneTarget() {
        // With flags around, a colon keeps meaning "part of the host".
        let reader = SSHCommandReader(command: "ssh -p 2222 root@example.com:3333")
        XCTAssertEqual(reader?.remoteAddress, "example.com:3333")
        XCTAssertEqual(reader?.remotePort, "2222")
        // Several colons can be an IPv6 host rather than a port.
        let v6 = SSHCommandReader(command: "ssh root@2001:db8::1")
        XCTAssertEqual(v6?.remoteAddress, "2001:db8::1")
        XCTAssertEqual(v6?.remotePort, "22")
        // One colon ahead of the @ is nobody's port either.
        XCTAssertNil(SSHCommandReader(command: "ssh user:name@example.com"))
    }

    func testQuickConnectAddsMissingPrefix() {
        let reader = SSHCommandReader(quickConnect: "root@example.com")
        XCTAssertEqual(reader?.username, "root")
        XCTAssertEqual(reader?.remoteAddress, "example.com")
        XCTAssertEqual(reader?.remotePort, "22")
    }

    func testQuickConnectAcceptsColonPort() {
        let reader = SSHCommandReader(quickConnect: "root@example.com:2222")
        XCTAssertEqual(reader?.remotePort, "2222")
        let prefixed = SSHCommandReader(quickConnect: "ssh root@example.com:2222")
        XCTAssertEqual(prefixed?.remotePort, "2222")
    }

    func testQuickConnectKeepsFullCommands() {
        let reader = SSHCommandReader(quickConnect: "SSH -p 2222 Root@Example.COM")
        XCTAssertEqual(reader?.username, "Root")
        XCTAssertEqual(reader?.remoteAddress, "Example.COM")
        XCTAssertEqual(reader?.remotePort, "2222")
    }

    func testQuickConnectRejectsEmptyAndAnonymous() {
        XCTAssertNil(SSHCommandReader(quickConnect: ""))
        XCTAssertNil(SSHCommandReader(quickConnect: "   "))
        XCTAssertNil(SSHCommandReader(quickConnect: "example.com"))
    }

    func testSuggestionCompletesTypedPrefix() {
        let recent = ["ssh root@alpha -p 22", "ssh ubuntu@beta -p 2222"]
        XCTAssertEqual(
            SSHCommandReader.suggestion(for: "roo", in: recent),
            "ssh root@alpha -p 22"
        )
        XCTAssertEqual(
            SSHCommandReader.suggestion(for: "ssh ubu", in: recent),
            "ssh ubuntu@beta -p 2222"
        )
    }

    func testSuggestionSkipsEmptyAndExactMatches() {
        let recent = ["", "ssh root@alpha -p 22"]
        XCTAssertEqual(
            SSHCommandReader.suggestion(for: "roo", in: recent),
            "ssh root@alpha -p 22"
        )
        XCTAssertNil(SSHCommandReader.suggestion(for: "ssh root@alpha -p 22", in: recent))
        XCTAssertNil(SSHCommandReader.suggestion(for: "xyz", in: recent))
        // Too short to mean anything.
        XCTAssertNil(SSHCommandReader.suggestion(for: "ro", in: recent))
    }

    // MARK: Cloudflare Access

    func testCloudflareProxyCommandAsDocumented() throws {
        let reader = try XCTUnwrap(SSHCommandReader(command: "ssh -o 'ProxyCommand=cloudflared access ssh --hostname %h' user@kosame-ssh.kfcv50.today"))
        XCTAssertEqual(reader.username, "user")
        XCTAssertEqual(reader.remoteAddress, "kosame-ssh.kfcv50.today")
        XCTAssertEqual(reader.remotePort, "22")
        XCTAssertTrue(reader.usesCloudflareAccess)
        XCTAssertEqual(reader.machine.transport, .cloudflareAccess)
    }

    func testCloudflareProxyCommandSpellings() {
        let commands = [
            "ssh -o ProxyCommand='cloudflared access ssh --hostname %h' user@host.example.com",
            "ssh -o \"ProxyCommand cloudflared access ssh --hostname %h\" user@host.example.com",
            "ssh -oProxyCommand=\"/opt/homebrew/bin/cloudflared access ssh --hostname=%h\" user@host.example.com",
            "ssh user@host.example.com -o 'proxycommand=cloudflared access tcp -T %h'",
            "ssh -o 'ProxyCommand=cloudflared access ssh' user@host.example.com",
        ]
        for command in commands {
            let reader = SSHCommandReader(command: command)
            XCTAssertEqual(reader?.remoteAddress, "host.example.com", command)
            XCTAssertEqual(reader?.usesCloudflareAccess, true, command)
        }
    }

    func testCloudflareLiteralHostnameIsWhereItGoes() {
        let reader = SSHCommandReader(command: "ssh -o 'ProxyCommand=cloudflared access ssh --hostname ssh.example.com' root@alias -p 2222")
        XCTAssertEqual(reader?.remoteAddress, "ssh.example.com")
        XCTAssertEqual(reader?.remotePort, "2222")
    }

    func testCloudflareCommandRoundTrips() throws {
        let reader = try XCTUnwrap(SSHCommandReader(command: "ssh -o 'ProxyCommand=cloudflared access ssh --hostname %h' user@host.example.com"))
        XCTAssertEqual(SSHCommandReader(command: reader.command), reader)
        XCTAssertEqual(SSHCommandReader(quickConnect: "-o 'ProxyCommand=cloudflared access ssh --hostname %h' user@host.example.com"), reader)
    }

    func testOtherOptionsAreStillRefused() {
        XCTAssertNil(SSHCommandReader(command: "ssh -o StrictHostKeyChecking=no root@example.com"))
        XCTAssertNil(SSHCommandReader(command: "ssh -o 'ProxyCommand=nc -X 5 -x proxy:1080 %h %p' root@example.com"))
        XCTAssertNil(SSHCommandReader(command: "ssh -o 'ProxyCommand=cloudflared access ssh root@example.com"))
    }

    func testPlainCommandsStayDirect() throws {
        let reader = try XCTUnwrap(SSHCommandReader(command: "ssh root@example.com"))
        XCTAssertFalse(reader.usesCloudflareAccess)
        XCTAssertEqual(reader.command, "ssh root@example.com -p 22")
        XCTAssertEqual(reader.machine.transport, .direct)
    }

    func testRecentsSavedBeforeDecode() throws {
        let json = #"{"remoteAddress":"example.com","remotePort":"22","username":"root"}"#
        let reader = try JSONDecoder().decode(SSHCommandReader.self, from: Data(json.utf8))
        XCTAssertFalse(reader.usesCloudflareAccess)
    }
}
