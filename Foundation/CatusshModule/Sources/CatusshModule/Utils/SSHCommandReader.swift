//
//  SSHCommandReader.swift
//  catussh
//
//  Created by Lakr Aream on 2022/2/9.
//

import Foundation

public struct SSHCommandReader: Codable, Equatable {
    public let remoteAddress: String
    public let remotePort: String
    public let username: String
    /// Set when the command reaches the server through Cloudflare Access, with
    /// `-o ProxyCommand='cloudflared access ssh --hostname %h'`; the address is
    /// then the Access hostname. Optional so recents saved before decode.
    public let viaCloudflareAccess: Bool?

    public var usesCloudflareAccess: Bool { viaCloudflareAccess == true }

    /// What cloudflared's documentation tells you to put in an ssh command.
    public static let cloudflareProxyOption = "-o ProxyCommand='cloudflared access ssh --hostname %h'"

    public var command: String {
        let proxy = usesCloudflareAccess ? Self.cloudflareProxyOption + " " : ""
        return "ssh \(proxy)\(username)@\(remoteAddress) -p \(remotePort)"
    }

    /// The server this command connects to, as the terminal opens it.
    public var machine: RDMachine {
        var machine = RDMachine(
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            name: remoteAddress,
            group: "SSHCommandReader",
            associatedIdentity: nil
        )
        machine.transport = usesCloudflareAccess ? .cloudflareAccess : .direct
        return machine
    }

    public init?(command: String) {
        let parser = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the "ssh " prefix is case-insensitive; the username and host
        // keep their case, a Linux username is case-sensitive.
        guard parser.lowercased().hasPrefix("ssh "),
              var tokens = Self.split(String(parser.dropFirst(4)))
        else {
            return nil
        }
        // A bare `user@host:port` target is read as an explicit port, the
        // ssh-command syntax Quick Connect accepts next to `-p port`. Only
        // a lone target gets this reading: with flags around, a colon stays
        // part of the host, and several colons can still be an IPv6 host.
        if tokens.count == 1, let token = tokens.first, token.contains("@"),
           token.filter({ $0 == ":" }).count == 1, let colon = token.lastIndex(of: ":")
        {
            tokens = [String(token[..<colon]), "-p", String(token[token.index(after: colon)...])]
        }
        // "-p <port>" and "-o ProxyCommand=..." may come before or after user@host.
        var target: String?
        var port: String?
        var cloudflareHostname: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "-p", port == nil {
                guard index + 1 < tokens.count, let value = UInt16(tokens[index + 1]) else {
                    return nil
                }
                port = "\(value)"
                index += 2
            } else if token.hasPrefix("-o"), cloudflareHostname == nil {
                // "-o Key=Value", "-oKey=Value" and "-o 'Key Value'".
                let option: String
                if token == "-o" {
                    guard index + 1 < tokens.count else { return nil }
                    option = tokens[index + 1]
                    index += 2
                } else {
                    option = String(token.dropFirst(2))
                    index += 1
                }
                // Only a proxy command cloudflared runs is understood; any
                // other option would be silently dropped otherwise.
                guard let hostname = Self.cloudflareHostname(inOption: option) else { return nil }
                cloudflareHostname = hostname
            } else if target == nil, token.contains("@") {
                target = token
                index += 1
            } else {
                return nil
            }
        }
        guard let reader = target else {
            return nil // requires username, block anonymous login
        }
        let component = reader.components(separatedBy: "@")
        guard component.count == 2 else {
            return nil
        }
        let name = component[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var addr = component[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count > 0, addr.count > 0 else {
            return nil
        }
        // %h is the host ssh was given; a literal hostname is where it goes.
        if let cloudflareHostname {
            addr = cloudflareHostname.replacingOccurrences(of: "%h", with: addr)
        }
        username = name
        remoteAddress = addr
        remotePort = port ?? "22"
        viaCloudflareAccess = cloudflareHostname == nil ? nil : true
    }

    /// The `--hostname` of a `ProxyCommand=cloudflared access ssh|tcp ...`
    /// option, "%h" when it names none; nil for any other option.
    static func cloudflareHostname(inOption option: String) -> String? {
        let separator = option.firstIndex { $0 == "=" || $0 == " " }
        guard let separator,
              option[..<separator].lowercased() == "proxycommand"
        else { return nil }
        var value = String(option[option.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("=") { value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard let words = split(value), words.count >= 3,
              words[0] == "cloudflared" || words[0].hasSuffix("/cloudflared"),
              words[1] == "access", words[2] == "ssh" || words[2] == "tcp"
        else { return nil }
        var hostname = "%h"
        var index = 3
        while index < words.count {
            let word = words[index]
            for flag in ["--hostname", "--tunnel-host", "-T"] {
                if word == flag, index + 1 < words.count {
                    hostname = words[index + 1]
                    index += 1
                } else if word.hasPrefix(flag + "=") {
                    hostname = String(word.dropFirst(flag.count + 1))
                }
            }
            index += 1
        }
        return hostname.isEmpty ? nil : hostname
    }

    /// Splits like a shell: whitespace separates words, quotes group them and
    /// a backslash takes the next character as it is. Nil for an open quote.
    static func split(_ line: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                inWord = true
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character == "\\" {
                escaped = true
            } else if character.isWhitespace {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(character)
                inWord = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if inWord { words.append(current) }
        return words
    }
}

public extension SSHCommandReader {
    /// Parses what was typed into Quick Connect: `user@host`,
    /// `user@host:port` or a full ssh command, with or without the
    /// "ssh " prefix (the prefix match stays case-insensitive).
    init?(quickConnect input: String) {
        var trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.lowercased().hasPrefix("ssh ") { trimmed = "ssh " + trimmed }
        self.init(command: trimmed)
    }

    /// The first candidate worth offering as a completion of what was
    /// typed into Quick Connect: it shares the typed prefix, is not the
    /// typed string itself, and the input is long enough to mean something.
    static func suggestion(for input: String, in candidates: some Sequence<String>) -> String? {
        guard input.count > 2 else { return nil }
        let typed = input.hasPrefix("ssh ") ? input : "ssh " + input
        return candidates.lazy.first { !$0.isEmpty && $0.hasPrefix(typed) && $0 != typed }
    }
}
