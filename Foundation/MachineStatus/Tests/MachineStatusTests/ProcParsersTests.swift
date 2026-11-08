//
//  ProcParsersTests.swift
//  MachineStatusTests
//
//  Fixture-driven tests for the Linux /proc and os-release parsers.
//

@testable import MachineStatus
import XCTest

final class ProcParsersTests: XCTestCase {
    // MARK: - /proc/meminfo

    private let meminfoFixture = """
    MemTotal:       16384000 kB
    MemFree:         1024000 kB
    MemAvailable:    8192000 kB
    Buffers:          512000 kB
    Cached:          4096000 kB
    SwapCached:            0 kB
    SwapTotal:       2097152 kB
    SwapFree:        1048576 kB
    HugePages_Total:       0
    Hugepagesize:       2048 kB
    """

    func testMeminfoParsesKeyedValues() {
        let info = ProcParsers.parseMeminfo(meminfoFixture)
        XCTAssertEqual(info["MEMTOTAL"], 16_384_000)
        XCTAssertEqual(info["MEMFREE"], 1_024_000)
        XCTAssertEqual(info["BUFFERS"], 512_000)
        XCTAssertEqual(info["CACHED"], 4_096_000)
        XCTAssertEqual(info["SWAPTOTAL"], 2_097_152)
        XCTAssertEqual(info["SWAPFREE"], 1_048_576)
        // A kB-suffixed line parses under its uppercased, colon-stripped key.
        XCTAssertEqual(info["HUGEPAGESIZE"], 2048)
        // Lines without a kB suffix are ignored.
        XCTAssertNil(info["HUGEPAGES_TOTAL"])
    }

    func testMeminfoUsesMemAvailableWhenPresent() {
        let memory = ServerStatus.MemoryInfo(meminfo: meminfoFixture)
        XCTAssertEqual(memory.memAvailable, 8_192_000)
        XCTAssertEqual(memory.phyUsed, 0.5, accuracy: 0.001)
    }

    func testNvidiaSmiCSVParser() {
        let csv = """
        550.54.14, GPU-1234-5678, NVIDIA GeForce RTX 4090, 24564, 4096, 20468, 95.02.3C.00.01, 35, 72, 18
        550.54.14, GPU-8765-4321, NVIDIA GeForce RTX 4090, 24564, 1024, 23540, 95.02.3C.00.01, [N/A], 10, 4
        """
        let graphics = ServerStatus.GraphicsInfo.parseCSV(csv)
        XCTAssertEqual(graphics?.version, "550.54.14")
        XCTAssertEqual(graphics?.units.count, 2)
        XCTAssertEqual(graphics?.units.first?.uuid, "GPU-1234-5678")
        XCTAssertEqual(graphics?.units.first?.name, "NVIDIA GeForce RTX 4090")
        XCTAssertEqual(graphics?.units.first?.memory.total, 24564)
        XCTAssertEqual(graphics?.units.first?.memory.used, 4096)
        XCTAssertEqual(graphics?.units.first?.fan_speed, "35 %")
        XCTAssertEqual(graphics?.units.first?.utilization.gpu_util, 72)
        XCTAssertEqual(graphics?.units.last?.fan_speed, "[N/A]")
        XCTAssertNil(ServerStatus.GraphicsInfo.parseCSV("no nvidia gpu available"))
    }

    func testSwapUsageIsRelativeToSwapTotal() {
        // Regression: swap usage was divided by physical memory total,
        // making the reported swap percentage always wrong.
        let info = ServerStatus.MemoryInfo(
            total: 16_384_000, free: 1_024_000, buffers: 512_000, cached: 4_096_000,
            swapTotal: 2_097_152, swapFree: 1_048_576
        )
        XCTAssertEqual(info.swapUsed, 0.5, accuracy: 0.001)
        XCTAssertEqual(info.phyUsed, (16_384_000 - 1_024_000 - 4_096_000 - 512_000) / 16_384_000, accuracy: 0.001)
    }

    func testZeroSwapDoesNotDivideByZero() {
        let info = ServerStatus.MemoryInfo(
            total: 16_384_000, free: 1_024_000, buffers: 0, cached: 0,
            swapTotal: 0, swapFree: 0
        )
        XCTAssertEqual(info.swapUsed, 0)
        XCTAssertFalse(info.swapUsed.isNaN)
    }

    // MARK: - /proc/stat

    private let procStatFixture = """
    cpu  100 0 200 1600 50 0 10 0 0 0
    cpu0 50 0 100 800 25 0 5 0 0 0
    cpu1 50 0 100 800 25 0 5 0 0 0
    intr 123456
    """

    func testProcStatParsesSummaryAndCores() {
        let (summary, cores) = ProcParsers.parseProcStat(procStatFixture)
        XCTAssertEqual(summary?.user, 100)
        XCTAssertEqual(summary?.idle, 1600)
        XCTAssertEqual(cores["cpu0"]?.system, 100)
        XCTAssertEqual(cores["cpu1"]?.iowait, 25)
        XCTAssertEqual(cores.count, 2)
    }

    func testPercentageBetweenSamples() {
        let (privSum, _) = ProcParsers.parseProcStat(procStatFixture)
        let currRaw = procStatFixture
            .replacingOccurrences(of: "cpu  100", with: "cpu  200") // user +100
        let (currSum, _) = ProcParsers.parseProcStat(currRaw)
        guard let priv = privSum, let curr = currSum else {
            XCTFail("missing summary rows")
            return
        }
        let percent = ProcParsers.calculatePercent(priv: priv, curr: curr)
        // total delta is 100, all of it user time
        XCTAssertEqual(percent.sumUser, 100, accuracy: 0.01)
        XCTAssertEqual(percent.sumUsed, 100, accuracy: 0.01)
    }

    func testIdenticalSamplesYieldZeroNotNaN() {
        // Regression: an idle machine can report identical counters twice;
        // dividing by the zero delta produced NaN/inf percentages.
        let (sum, _) = ProcParsers.parseProcStat(procStatFixture)
        guard let sum else {
            XCTFail("missing summary row")
            return
        }
        let percent = ProcParsers.calculatePercent(priv: sum, curr: sum)
        XCTAssertEqual(percent.sumUsed, 0)
        XCTAssertFalse(percent.sumUsed.isNaN)
        XCTAssertFalse(percent.sumSystem.isInfinite)
    }

    // MARK: - /etc/os-release

    func testOsReleasePrefersPrettyNameAndStripsDoubleQuotes() {
        let fixture = """
        NAME="Ubuntu"
        VERSION_ID="22.04"
        PRETTY_NAME="Ubuntu 22.04.1 LTS"
        """
        XCTAssertEqual(ProcParsers.parseOsReleaseName(fixture), "Ubuntu 22.04.1 LTS")
    }

    func testOsReleaseFallsBackToName() {
        XCTAssertEqual(ProcParsers.parseOsReleaseName("NAME=\"Debian GNU/Linux\""), "Debian GNU/Linux")
    }

    func testOsReleaseStripsSingleQuotes() {
        // Regression: the old condition compared prefixes against double
        // quotes but suffixes against single quotes, so nothing was stripped.
        XCTAssertEqual(ProcParsers.parseOsReleaseName("NAME='Fedora Linux'"), "Fedora Linux")
    }

    func testOsReleaseUnquotedAndMissing() {
        XCTAssertEqual(ProcParsers.parseOsReleaseName("NAME=Alpine Linux"), "Alpine Linux")
        XCTAssertEqual(ProcParsers.parseOsReleaseName(""), "Generic Linux")
    }

    // MARK: - /proc/loadavg

    func testLoadavgParses() {
        let load = ProcParsers.parseLoadavg("0.27 0.34 0.39 2/916 23817")
        XCTAssertEqual(load.load1avg, 0.27, accuracy: 0.001)
        XCTAssertEqual(load.load5avg, 0.34, accuracy: 0.001)
        XCTAssertEqual(load.load15avg, 0.39, accuracy: 0.001)
        XCTAssertEqual(load.runningProcess, 2)
        XCTAssertEqual(load.totalProcess, 916)
    }

    func testLoadavgMalformedReturnsZero() {
        let load = ProcParsers.parseLoadavg("garbage")
        XCTAssertEqual(load.load1avg, 0)
        XCTAssertEqual(load.totalProcess, 0)
    }

    // MARK: - merged monitor script

    private let mergedOutputFixture = """
    <<<CATUSSH-SECTION:cpu-a>>>
    cpu  100 0 200 1600 50 0 10 0 0 0
    cpu0 50 0 100 800 25 0 5 0 0 0
    <<<CATUSSH-SECTION:net-a>>>
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo: 1000      10    0    0    0     0          0         0     1000      10    0    0    0     0       0          0
      eth0: 5000      50    0    0    0     0          0         0     2000      20    0    0    0     0       0          0
    <<<CATUSSH-SECTION:wait>>>
    <<<CATUSSH-SECTION:cpu-b>>>
    cpu  200 0 300 3200 100 0 20 0 0 0
    cpu0 100 0 150 1600 50 0 10 0 0 0
    <<<CATUSSH-SECTION:uptime>>>
    773229.50 1531748.20
    <<<CATUSSH-SECTION:hostname>>>
    web-01
    """

    func testSplitMonitorSectionsAssignsPayloads() {
        let sections = ProcParsers.splitMonitorSections(mergedOutputFixture)
        XCTAssertTrue(sections["cpu-a"]?.contains("cpu0 50") == true)
        XCTAssertTrue(sections["net-a"]?.contains("eth0:") == true)
        XCTAssertEqual(sections["uptime"]?.trimmingCharacters(in: .whitespacesAndNewlines), "773229.50 1531748.20")
        XCTAssertEqual(sections["hostname"]?.trimmingCharacters(in: .whitespacesAndNewlines), "web-01")
        // The sleep marker opens a section with no payload.
        XCTAssertEqual(sections["wait"]?.trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertFalse(sections["cpu-b"]?.contains("cpu0 50") == true)
    }

    func testSplitMonitorSectionsIgnoresInlineMarkerLookalikes() {
        // Only a full-line marker opens a section; payload text containing
        // the marker inside a longer line must not split.
        let raw = """
        <<<CATUSSH-SECTION:df>>>
        /dev/sda1 100 50 50 50% /mnt/<<<CATUSSH-SECTION:mem>>>-disk
        """
        let sections = ProcParsers.splitMonitorSections(raw)
        XCTAssertNil(sections["mem"])
        XCTAssertTrue(sections["df"]?.contains("/mnt/<<<CATUSSH-SECTION:mem>>>-disk") == true)
    }

    func testSplitMonitorSectionsToleratesCarriageReturns() {
        let raw = "<<<CATUSSH-SECTION:hostname>>>\r\nweb-01\r\n<<<CATUSSH-SECTION:uptime>>>\r\n42 84\r\n"
        let sections = ProcParsers.splitMonitorSections(raw)
        XCTAssertEqual(sections["hostname"]?.trimmingCharacters(in: .whitespacesAndNewlines), "web-01")
        XCTAssertEqual(ProcParsers.parseUptime(sections["uptime"] ?? ""), 42)
    }

    func testMonitorScriptSamplesCountersTwiceAroundOneSleep() {
        let script = ServerStatus.monitorScript(includeStatic: true)
        XCTAssertEqual(script.components(separatedBy: "/bin/cat /proc/stat").count - 1, 2)
        XCTAssertEqual(script.components(separatedBy: "/bin/cat /proc/net/dev").count - 1, 2)
        XCTAssertEqual(script.components(separatedBy: "/bin/sleep 1").count - 1, 1)
        for section in ["cpu-a", "net-a", "cpu-b", "net-b", "mem", "df", "uptime", "loadavg", "hostname", "os-release"] {
            XCTAssertTrue(
                script.contains("echo '\(ServerStatus.sectionMarkerPrefix)\(section)\(ServerStatus.sectionMarkerSuffix)'"),
                "missing marker for \(section)"
            )
        }
    }

    func testMonitorScriptOmitsStaticsUnlessAsked() {
        let script = ServerStatus.monitorScript(includeStatic: false)
        XCTAssertFalse(script.contains("os-release"))
        XCTAssertFalse(script.contains("hostname"))
        XCTAssertEqual(script.components(separatedBy: "/bin/sleep 1").count - 1, 1)
    }

    // MARK: - /proc/uptime

    func testParseUptimeReadsFirstField() {
        XCTAssertEqual(ProcParsers.parseUptime("773229.50 1531748.20\n"), 773_229.5, accuracy: 0.001)
        XCTAssertEqual(ProcParsers.parseUptime("42"), 42)
        XCTAssertEqual(ProcParsers.parseUptime("garbage"), 0)
        XCTAssertEqual(ProcParsers.parseUptime(""), 0)
    }

    // MARK: - df -Pk

    private let dfPkFixture = """
    Filesystem                        1024-blocks     Used Available Capacity Mounted on
    udev                                 8192000        0   8192000       0% /dev
    tmpfs                                1638400   124928   1513472       8% /run
    /dev/mapper/ubuntu--vg-ubuntu--lv   51281224 15994688  32923552      33% /
    tmpfs                                8192000        0   8192000       0% /dev/shm
    tmpfs                                   5120        0      5120       0% /run/lock
    none                                       0        0         0       0% /sys/fs/cgroup
    /dev/sda2                            1959920   251792   1606088      14% /boot
    /dev/sdb1                          976762532 6185396 920562116       1% /media/My Passport
    """

    func testDfPkParsesNumericColumns() {
        let elements = ProcParsers.parseDfPk(dfPkFixture)
        let root = elements.first { $0.mountPoint == "/" }
        XCTAssertEqual(root?.size, "49G")
        XCTAssertEqual(root?.used, "15G")
        XCTAssertEqual(root?.free, "31G")
        XCTAssertEqual(root?.percent, 33)
    }

    func testDfPkKeepsLongDeviceNames() {
        // Regression: df -h wraps a long device name onto its own line, and
        // the old space-splitting parser silently dropped both halves; -P
        // keeps one filesystem per line.
        let elements = ProcParsers.parseDfPk(dfPkFixture)
        XCTAssertTrue(elements.contains { $0.mountPoint == "/" })
        XCTAssertEqual(elements.count, 7)
    }

    func testDfPkKeepsSpacesInMountPointAndSkipsEmptyFilesystems() {
        let elements = ProcParsers.parseDfPk(dfPkFixture)
        let mounted = elements.first { $0.mountPoint == "/media/My Passport" }
        XCTAssertEqual(mounted?.size, "932G")
        XCTAssertEqual(mounted?.used, "5.9G")
        XCTAssertFalse(elements.contains { $0.mountPoint == "/sys/fs/cgroup" })
    }

    func testDfPkFormatsKilobytesLikeDfH() {
        XCTAssertEqual(ProcParsers.formatKilobytes(957_440), "935M")
        XCTAssertEqual(ProcParsers.formatKilobytes(512), "512K")
        XCTAssertEqual(ProcParsers.formatKilobytes(1_945_600), "1.9G")
    }
}
