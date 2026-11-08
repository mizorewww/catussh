//
//  Bench.swift
//  catussh (macOS)
//

#if DEBUG
    import AppKit
    import CatusshModule
    import CatusshTerminal
    import NSRemoteShell
    import QuartzCore
    import SwiftUI

    extension Notification.Name {
        static let benchFiles = Notification.Name("me.mizorewww.rayon.bench.files")
    }

    private final class RunLoopLoad: @unchecked Sendable {
        var busy = 0.0
        var stretch = 0.0
        var woke = CACurrentMediaTime()
    }

    @MainActor
    enum Bench {
        static func runIfRequested() {
            if ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_FILES"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task { await previewFiles() } }
            }
            if ProcessInfo.processInfo.environment["CATUSSH_BENCH_SETTINGS"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task { await settings() } }
            }
            guard let value = ProcessInfo.processInfo.environment["CATUSSH_BENCH_FILES"], let count = Int(value) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task { await files(count) } }
        }

        static var longest = 0.0

        static func settle(_ action: () -> Void) async -> Double {
            let load = RunLoopLoad()
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { _, activity in
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { load.woke = now } else { load.busy += now - load.woke; load.stretch = max(load.stretch, now - load.woke); load.woke = now }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            action()
            try? await Task.sleep(nanoseconds: 400_000_000)
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            longest = load.stretch * 1000
            return load.busy * 1000
        }

        static func report(_ name: String, _ samples: [Double]) {
            let sorted = samples.sorted()
            let median = sorted[sorted.count / 2]
            NSLog("BENCH %@ median %.2f ms  max %.2f ms  n=%d", name, median, sorted.last ?? 0, samples.count)
        }

        static func emptyFilesPage() async -> FileTransferContext {
            let machine = RDMachine(remoteAddress: "203.0.113.10", remotePort: "22", name: "web-01")
            let context = FileTransferContext(machine: machine)
            FileTransferManager.shared.transfers.append(context)
            AppRouter.shared.route = .transfer(context.id)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while context.processConnection { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            context.connected = true
            context.isProgressRunning = false
            try? await Task.sleep(nanoseconds: 500_000_000)
            return context
        }

        static func previewFiles() async {
            let context = await emptyFilesPage()
            context.currentDir = "/var/log"
            let base = URL(fileURLWithPath: "/var/log")
            let names = ["nginx", "journal", "apt", "private", "auth.log", "syslog", "kern.log", "dpkg.log", "boot.log",
                         "a-very-long-file-name-that-does-not-fit-in-the-name-column-of-the-table-and-is-truncated-in-the-middle-2026-10-11.log.gz",
                         "fail2ban.log", "alternatives.log", "cloud-init.log", "wtmp", "btmp", "lastlog", "ufw.log", "mail.log"]
            context.currentFileList = names.enumerated().map { index, name in
                let file = NSRemoteFile(filename: name)
                var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                attributes.flags = 0xF
                attributes.filesize = UInt64(index * index * 4321 + 17)
                attributes.uid = index < 4 ? 0 : 1000
                attributes.gid = 0
                attributes.permissions = index < 4 ? 0o040755 : 0o100644
                attributes.mtime = UInt(1_780_000_000 + index * 86400 * 3)
                attributes.atime = attributes.mtime
                file.populateAttributes(attributes)
                return FileTransferContext.RemoteFile(base: base, name: name, fstat: file)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            NotificationCenter.default.post(name: .benchFiles, object: nil, userInfo: ["select": 6])
        }

        static func files(_ count: Int) async {
            let context = await emptyFilesPage()
            let base = URL(fileURLWithPath: "/var/log")
            var generator = SystemRandomNumberGenerator()
            let list = (0 ..< count).map { _ in
                let name = "file-\(Int.random(in: 0 ..< 10_000_000, using: &generator)).log"
                return FileTransferContext.RemoteFile(base: base, name: name, fstat: NSRemoteFile(filename: name))
            }
            report("show \(count)", [await settle { context.currentFileList = list }])
            NSLog("BENCH done")
        }

        static func settings() async {
            let router = AppRouter.shared
            router.settingsSelection = "general"
            report("open settings", [await settle { router.route = .settings }])
            NSLog("BENCH done")
        }
    }
#endif
