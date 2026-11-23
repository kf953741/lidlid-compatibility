import Foundation
import IOKit
import LidLidServiceCore
import LidOnceSystem

struct SystemSleepSetting: SleepSetting {
    let root: PowerDriver
    static func parse(_ output: String) throws -> Bool {
        let lines = output.split(whereSeparator: \.isNewline)
        let hasPmsetHeader = lines.contains {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == "System-wide power settings:" || trimmed == "Currently in use:"
        }
        guard hasPmsetHeader else { throw ServiceFailure("无法读取系统睡眠设置，请稍后重试") }
        var values: [Bool] = []
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "SleepDisabled" else { continue }
            guard fields.count == 2 else { throw ServiceFailure("无法读取系统睡眠设置，请稍后重试") }
            if fields[1] == "0" { values.append(false) }
            else if fields[1] == "1" { values.append(true) }
            else { throw ServiceFailure("无法读取系统睡眠设置，请稍后重试") }
        }
        // On a fresh macOS install where `disablesleep` has never been toggled,
        // `pmset -g` may omit `SleepDisabled`, which semantically means 0 (false).
        if values.isEmpty { return false }
        guard values.count == 1 else { throw ServiceFailure("无法读取系统睡眠设置，请稍后重试") }
        return values[0]
    }
    func read() throws -> Bool {
        let saved = try Self.parse(run(["-g"]))
        let kernel = root.bool("SleepDisabled") ?? false
        guard kernel == saved else {
            throw ServiceFailure("兼容组件未能确认睡眠设置，请稍后重试")
        }
        return saved
    }
    func write(disabled: Bool) throws {
        _ = try run(["-a", "disablesleep", disabled ? "1" : "0"])
        // The persistent preference alone is not proof the kernel applied it.
        // Wait a bounded interval for the actual root-domain property as well.
        let until = ProcessInfo.processInfo.systemUptime + 1
        while (root.bool("SleepDisabled") ?? false) != disabled {
            guard ProcessInfo.processInfo.systemUptime < until else {
                throw ServiceFailure("兼容组件未能确认睡眠设置，请稍后重试")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // Fixed executable and arguments only. No shell, sudoers, caller-supplied
    // path, command, environment, or arbitrarily privileged file operations.
    private func run(_ arguments: [String]) throws -> String {
        let task = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = arguments
        task.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"]
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        var output = Data()
        let readDone = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        try task.run()
        try? pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        guard done.wait(timeout: .now() + 2.5) == .success else {
            kill(task.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 0.5)
            _ = readDone.wait(timeout: .now() + 0.5)
            throw ServiceFailure("系统睡眠设置超时，请保持开盖并重试")
        }
        guard readDone.wait(timeout: .now() + 0.5) == .success else {
            throw ServiceFailure("系统睡眠设置响应异常")
        }
        guard task.terminationStatus == 0 else { throw ServiceFailure("系统拒绝兼容组件的睡眠设置") }
        guard output.count <= 16_384 else { throw ServiceFailure("系统睡眠设置响应异常") }
        return String(decoding: output, as: UTF8.self)
    }
}
