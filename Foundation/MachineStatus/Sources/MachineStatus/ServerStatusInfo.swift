//
//  ServerInfo.swift
//  catussh
//
//  Created by Lakr Aream on 2022/2/12.
//

import Combine
import Foundation
import NSRemoteShell

/// Mirror of CatusshModule's `onMainThread`; MachineStatus sits below
/// CatusshModule in the package graph and cannot import it.
/// - Parameter run: the job to be fired on the main thread
func onMainThread(delay: Double = 0, run: @escaping () -> Void) {
    // Preserve the legacy model callbacks without claiming the models are Sendable.
    nonisolated(unsafe) let run = run
    guard delay == 0, Thread.isMainThread else {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            run()
        }
        return
    }
    run()
}

/// Hands a value out of a @Sendable dispatch block without capturing a
/// var, which Swift 6 diagnoses.
private final class ConcurrentValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func store(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public class ServerStatus: ObservableObject, Equatable {
    public init() {}

    /// The merged monitor script echoes this marker on its own line ahead
    /// of each section; `ProcParsers.splitMonitorSections` only opens a
    /// section on a full-line match, which kernel /proc payloads, df rows
    /// and os-release assignments can never produce. That is what the old
    /// "[*******]" token could not promise inside two samples of one file.
    static let sectionMarkerPrefix = "<<<CATUSSH-SECTION:"
    static let sectionMarkerSuffix = ">>>"

    /// `nvidia-smi` stays a command of its own: it is slow and missing on
    /// most machines, and its failure must not cost the other sections.
    static let graphicsScript = "nvidia-smi --query-gpu=driver_version,uuid,name,memory.total,memory.used,memory.free,vbios_version,fan.speed,utilization.gpu,utilization.memory --format=csv,noheader,nounits 2>/dev/null || echo \"no nvidia gpu available\""

    /// One remote run that samples the CPU and network counters twice one
    /// second apart and reads every other payload behind markers, so a
    /// refresh costs one exec channel instead of nine and one remote second
    /// instead of two. Linux reads /proc; Darwin uses its native tools.
    /// Static payloads join only while `includeStatic` — they cannot change
    /// while a connection stays up.
    static func monitorScript(includeStatic: Bool) -> String {
        var sections = [
            ("platform", "echo \"$CATUSSH_KERNEL\""),
            ("ts-a", "if [ \"$CATUSSH_KERNEL\" = Darwin ]; then /bin/date +%s; else /bin/cat /proc/uptime; fi"),
            ("cpu-a", "if [ \"$CATUSSH_KERNEL\" != Darwin ]; then /bin/cat /proc/stat; fi"),
            ("net-a", "if [ \"$CATUSSH_KERNEL\" = Darwin ]; then /usr/sbin/netstat -ibn; else /bin/cat /proc/net/dev; fi"),
            ("darwin-top", "if [ \"$CATUSSH_KERNEL\" = Darwin ]; then /usr/bin/top -l 2 -n 0 -s 1; fi"),
            ("wait", "if [ \"$CATUSSH_KERNEL\" != Darwin ]; then /bin/sleep 1; fi"),
            ("ts-b", "if [ \"$CATUSSH_KERNEL\" = Darwin ]; then /bin/date +%s; else /bin/cat /proc/uptime; fi"),
            ("cpu-b", "if [ \"$CATUSSH_KERNEL\" != Darwin ]; then /bin/cat /proc/stat; fi"),
            ("net-b", "if [ \"$CATUSSH_KERNEL\" = Darwin ]; then /usr/sbin/netstat -ibn; else /bin/cat /proc/net/dev; fi"),
            ("mem", "if [ \"$CATUSSH_KERNEL\" = Darwin ]; then /usr/sbin/sysctl hw.memsize hw.pagesize vm.swapusage; /usr/bin/vm_stat; else /bin/cat /proc/meminfo; fi"),
            ("df", "/bin/df -Pk"),
            ("uptime", "if [ \"$CATUSSH_KERNEL\" = Darwin ]; then /bin/date +%s; /usr/sbin/sysctl -n kern.boottime; else /bin/cat /proc/uptime; fi"),
            ("loadavg", "if [ \"$CATUSSH_KERNEL\" != Darwin ]; then /bin/cat /proc/loadavg; fi"),
        ]
        if includeStatic {
            sections += [
                ("hostname", "/bin/hostname 2>/dev/null || hostname 2>/dev/null || echo \"localhost\""),
                ("os-release", "if [ \"$CATUSSH_KERNEL\" = Darwin ]; then /usr/bin/sw_vers; else /bin/cat /etc/os-release; fi"),
            ]
        }
        let commands = sections.map { name, command in
            "echo '\(sectionMarkerPrefix)\(name)\(sectionMarkerSuffix)'\n\(command)"
        }
        return (["CATUSSH_KERNEL=\"$(/usr/bin/uname -s 2>/dev/null || uname -s)\""] + commands)
            .joined(separator: "\n")
    }

    static func downloadResultFrom(shell: NSRemoteShell, command: String, timeout: Double) -> String {
        guard shell.isConnected, shell.isAuthenticated else {
            return ""
        }
        var result = ""
        shell.beginExecute(
            withCommand: command,
            withTimeout: NSNumber(value: timeout),
            withOnCreate: {},
            withOutput: { result.append($0) },
            withContinuationHandler: nil
        )
        return result
    }

    // Not @Published on purpose: a refresh replaces every group in one
    // batch and sends a single objectWillChange (see requestInfoAndWait),
    // where six per-property publishes used to redraw every card six
    // times per round.
    public var processor: ProcessorInfo = .init()
    public var fileSystem: FileSystemInfo = .init()
    public var memory: MemoryInfo = .init()
    public var system: SystemInfo = .init()
    public var network: NetworkInfo = .init()

    // not all server have gpu, bro
    public var graphics: GraphicsInfo? = nil

    public static func == (lhs: ServerStatus, rhs: ServerStatus) -> Bool {
        lhs.processor == rhs.processor &&
            lhs.fileSystem == rhs.fileSystem &&
            lhs.memory == rhs.memory &&
            lhs.system == rhs.system &&
            lhs.network == rhs.network &&
            lhs.graphics == rhs.graphics
    }

    private static let queue = DispatchQueue(label: "me.mizorewww.rayon.info", attributes: .concurrent)

    /// Hostname and os-release cannot change while a connection stays up,
    /// so they are read once and reused until the monitor reports a
    /// reconnect via `resetSessionStatics`.
    private let staticsLock = NSLock()
    private var sessionHostname: String?
    private var sessionReleaseName: String?

    /// Drops the once-per-connection static readings so the next refresh
    /// pulls them again.
    public func resetSessionStatics() {
        staticsLock.lock()
        sessionHostname = nil
        sessionReleaseName = nil
        staticsLock.unlock()
    }

    /// Runs the merged monitor script and the GPU probe on two channels,
    /// then parses every section on its own: one section going missing
    /// (a hung `nvidia-smi`, an unsupported system probe) empties only its
    /// model. `timeout` bounds each channel so a hung probe cannot freeze
    /// the monitor loop forever.
    public func requestInfoAndWait(with remote: NSRemoteShell, timeout: Double) {
        // The shell multiplexes channels internally; claiming it Sendable
        // is for the compiler, like the legacy model callbacks.
        nonisolated(unsafe) let remote = remote
        staticsLock.lock()
        let includeStatic = sessionHostname == nil || sessionReleaseName == nil
        staticsLock.unlock()
        let group = DispatchGroup()
        let queue = Self.queue

        let mergedOutput = ConcurrentValue("")
        group.enter()
        queue.async {
            defer { group.leave() }
            mergedOutput.store(Self.downloadResultFrom(shell: remote, command: Self.monitorScript(includeStatic: includeStatic), timeout: timeout))
        }

        let graphicsResult = ConcurrentValue<GraphicsInfo?>(nil)
        group.enter()
        queue.async {
            defer { group.leave() }
            graphicsResult.store(GraphicsInfo(withRemote: remote, timeout: timeout))
        }

        group.wait()

        let sections = ProcParsers.splitMonitorSections(mergedOutput.load())
        let isDarwin = sections["platform"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "Darwin"
        if includeStatic {
            // Only a non-empty reading is cached; a failed probe is retried
            // on the next round instead of sticking a placeholder.
            let hostname = (sections["hostname"] ?? "").replacingOccurrences(of: "\n", with: "")
            let releasePayload = (sections["os-release"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            staticsLock.lock()
            if !hostname.isEmpty { sessionHostname = hostname }
            if !releasePayload.isEmpty {
                sessionReleaseName = isDarwin
                    ? ProcParsers.parseDarwinReleaseName(releasePayload)
                    : ProcParsers.parseOsReleaseName(releasePayload)
            }
            staticsLock.unlock()
        }
        staticsLock.lock()
        let hostname = sessionHostname ?? ""
        let releaseName = sessionReleaseName ?? ""
        staticsLock.unlock()

        let tsBefore = ProcParsers.parseUptime(sections["ts-a"] ?? "")
        let tsAfter = ProcParsers.parseUptime(sections["ts-b"] ?? "")
        let elapsed = (tsAfter > tsBefore && tsBefore > 0) ? max(0.5, tsAfter - tsBefore) : 1.0

        let processor: ProcessorInfo
        let network: NetworkInfo
        let memory: MemoryInfo
        let load: SystemLoadInternal
        let uptime: Double
        if isDarwin {
            processor = ProcessorInfo(darwinTop: sections["darwin-top"]) ?? .init()
            network = NetworkInfo(netstatBefore: sections["net-a"], netstatAfter: sections["net-b"], interval: elapsed) ?? .init()
            memory = MemoryInfo(darwinMemory: sections["mem"] ?? "")
            load = ProcParsers.parseDarwinTopLoad(sections["darwin-top"] ?? "")
            uptime = ProcParsers.parseDarwinUptime(sections["uptime"] ?? "")
        } else {
            processor = ProcessorInfo(statBefore: sections["cpu-a"], statAfter: sections["cpu-b"]) ?? .init()
            network = NetworkInfo(netDevBefore: sections["net-a"], netDevAfter: sections["net-b"], interval: elapsed) ?? .init()
            memory = MemoryInfo(meminfo: sections["mem"] ?? "")
            load = ProcParsers.parseLoadavg(sections["loadavg"] ?? "")
            uptime = ProcParsers.parseUptime(sections["uptime"] ?? "")
        }
        let fileSystem = FileSystemInfo(dfPk: sections["df"] ?? "")
        let system = SystemInfo(
            release: releaseName,
            uptimeInSec: uptime,
            hostname: hostname,
            runningProcs: load.runningProcess,
            totalProcs: load.totalProcess,
            load1: load.load1avg,
            load5: load.load5avg,
            load15: load.load15avg
        )
        let graphics = graphicsResult.load()

        onMainThread { [weak self] in
            guard let self else { return }
            // One publish per refresh: the whole batch lands behind a
            // single objectWillChange.
            objectWillChange.send()
            self.processor = processor
            self.fileSystem = fileSystem
            self.memory = memory
            self.system = system
            self.network = network
            self.graphics = graphics
        }
    }
}
