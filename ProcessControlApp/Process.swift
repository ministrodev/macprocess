import Foundation
import AppKit

struct ManagedProcess: Identifiable, Decodable, Hashable {
    let pid: Int
    let name: String
    let cpu: String
    let memory: String
    let state: String
    let isNative: Bool?
    let isApplication: Bool?
    var id: Int { pid }

    var isNativeProcess: Bool {
        if let isNative { return isNative }
        let lower = name.lowercased()
        if lower.hasPrefix("/system/") || lower.hasPrefix("/usr/") ||
            lower.hasPrefix("/bin/") || lower.hasPrefix("/sbin/") || lower.hasPrefix("/private/") ||
            lower.hasPrefix("kernel_") || lower.hasPrefix("launchd") { return true }

        return false
    }

    var displayName: String {
        let parts = name.split(separator: "/").map(String.init)
        // Filhos de apps (renderers, helpers etc.) mantêm o caminho do .app no `ps`.
        // Agrupá-los pelo bundle deixa a lista bem menor e mais compreensível.
        if let bundle = parts.first(where: { $0.lowercased().hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }
        let last = parts.last ?? name
        return last.lowercased().hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    var isActive: Bool { !state.uppercased().hasPrefix("T") && !state.uppercased().hasPrefix("Z") }
    var statusLabel: String { isActive ? "ATIVO" : "DESATIVADO" }

    var belongsToApplication: Bool {
        if let isApplication { return isApplication }
        if name.split(separator: "/").contains(where: { $0.lowercased().hasSuffix(".app") }) { return true }
        return false
    }
}

enum ProcessAction { case stop, start }

struct ClosedNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let appName: String
    let icon: NSImage?
}

@MainActor
final class ProcessStore: ObservableObject {
    @Published var processes: [ManagedProcess] = []
    @Published var selected: ManagedProcess?
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var closedNotice: ClosedNotice?
    @Published var isLoading = false

    func refresh(showLoading: Bool = true) async {
        if showLoading { isLoading = true }; defer { if showLoading { isLoading = false } }
        do {
            let data = try await Backend.run("list")
            processes = classify(try JSONDecoder().decode([ManagedProcess].self, from: data))
            if processes.isEmpty { processes = classify(await fallbackProcessList()) }
        } catch {
            // Xcode pode executar o pacote fora da raiz do projeto. Nesse caso,
            // consultamos o mesmo `ps` diretamente, preservando CPU e memória.
            processes = classify(await fallbackProcessList())
            if processes.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func fallbackProcessList() async -> [ManagedProcess] {
        let snapshot = await Backend.systemProcessList()
        return snapshot.isEmpty ? runningApplications() : snapshot
    }

    private func classify(_ list: [ManagedProcess]) -> [ManagedProcess] {
        let running = NSWorkspace.shared.runningApplications
        let byPID = Dictionary(uniqueKeysWithValues: running.map { (Int($0.processIdentifier), $0) })
        let byName = Dictionary(grouping: running, by: { ($0.localizedName ?? "").lowercased() })
        return list.map { process in
            let app = byPID[process.pid] ?? byName[process.displayName.lowercased()]?.first
            let lower = process.name.lowercased()
            let systemPath = lower.hasPrefix("/system/") || lower.hasPrefix("/usr/") || lower.hasPrefix("/bin/") || lower.hasPrefix("/sbin/") || lower.hasPrefix("/private/") || lower.hasPrefix("kernel_") || lower.hasPrefix("launchd")
            let native = systemPath || (app?.bundleIdentifier?.hasPrefix("com.apple.") ?? false)
            let application = process.name.split(separator: "/").contains { $0.lowercased().hasSuffix(".app") } || app?.bundleURL != nil
            return ManagedProcess(pid: process.pid, name: process.name, cpu: process.cpu, memory: process.memory, state: process.state, isNative: native, isApplication: application)
        }
    }

    func liveUpdates() async {
        while !Task.isCancelled {
            await refresh(showLoading: processes.isEmpty)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func runningApplications() -> [ManagedProcess] {
        NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier > 1 && $0.localizedName != nil }
            .map {
                ManagedProcess(
                    pid: Int($0.processIdentifier),
                    name: $0.localizedName ?? "Aplicativo sem nome",
                    cpu: "—", memory: "—", state: $0.isTerminated ? "Encerrado" : "Ativo",
                    isNative: $0.bundleIdentifier?.hasPrefix("com.apple.") ?? false,
                    isApplication: true
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func findAppIcon(pid: Int?, name: String) -> NSImage? {
        if let pid = pid, let app = NSRunningApplication(processIdentifier: pid_t(pid)), let icon = app.icon {
            return icon
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame }), let icon = app.icon {
            return icon
        }
        return nil
    }

    func perform(_ action: ProcessAction, on process: ManagedProcess) async {
        do { _ = try await Backend.run(action == .stop ? "stop" : "start", "\(process.pid)"); await refresh() }
        catch { errorMessage = "Não foi possível alterar \(process.name): \(error.localizedDescription)" }
    }

    func terminate(_ process: ManagedProcess) async {
        let name = process.displayName
        let pid = pid_t(process.pid)
        let icon = findAppIcon(pid: process.pid, name: name)
        
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.forceTerminate()
            app.terminate()
        }
        
        do {
            _ = try await Backend.run("stop", "\(process.pid)")
        } catch {
            _ = kill(pid, SIGTERM)
            usleep(40000)
            if kill(pid, 0) == 0 {
                _ = kill(pid, SIGKILL)
            }
        }
        _ = kill(pid, SIGKILL)
        
        try? await Task.sleep(nanoseconds: 120_000_000)
        await refresh(showLoading: false)
        closedNotice = ClosedNotice(
            title: "Fechado com sucesso",
            message: "O processo \"\(name)\" (PID \(process.pid)) foi encerrado com sucesso.",
            appName: name,
            icon: icon
        )
    }

    func terminateGroup(processes: [ManagedProcess], groupName: String? = nil) async {
        let name = groupName ?? processes.first?.displayName ?? "Processos"
        let icon = findAppIcon(pid: processes.first?.pid, name: name)
        
        for app in NSWorkspace.shared.runningApplications {
            if let appName = app.localizedName, appName.localizedCaseInsensitiveCompare(name) == .orderedSame {
                app.forceTerminate()
                app.terminate()
            }
        }
        
        for process in processes {
            let pid = pid_t(process.pid)
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.forceTerminate()
                app.terminate()
            }
            _ = try? await Backend.run("stop", "\(process.pid)")
            _ = kill(pid, SIGTERM)
            _ = kill(pid, SIGKILL)
        }
        
        try? await Task.sleep(nanoseconds: 150_000_000)
        await refresh(showLoading: false)
        closedNotice = ClosedNotice(
            title: "Fechado com sucesso",
            message: "O grupo \"\(name)\" com \(processes.count) subprocessos foi encerrado com sucesso.",
            appName: name,
            icon: icon
        )
    }
}

enum Backend {
    static func run(_ arguments: String...) async throws -> Data {
        try await Task.detached {
            let task = Process()
            let configuredPath = ProcessInfo.processInfo.environment["PROCESS_BACKEND_PATH"]
            let bundledURL = Bundle.main.url(forResource: "process-backend", withExtension: nil)
            // No desenvolvimento via Swift Package, o diretório de trabalho é a raiz do pacote.
            let backendURL = configuredPath.map(URL.init(fileURLWithPath:)) ?? bundledURL ?? developmentBackendURL()
            guard FileManager.default.isExecutableFile(atPath: backendURL.path) else {
                throw NSError(
                    domain: "MacProcess", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Helper C++ não encontrado em \(backendURL.path)"]
                )
            }
            task.executableURL = backendURL
            task.arguments = arguments
            let output = Pipe(), errors = Pipe(); task.standardOutput = output; task.standardError = errors
            try task.run(); task.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            if task.terminationStatus != 0 {
                let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Erro desconhecido"
                throw NSError(domain: "MacProcess", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: error])
            }
            return data
        }.value
    }

    private static func developmentBackendURL() -> URL {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath),
            URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        ]
        for root in roots {
            var folder = root
            for _ in 0..<8 {
                let candidate = folder.appendingPathComponent("Backend/build/process-backend")
                if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
                folder.deleteLastPathComponent()
            }
        }
        return roots[0].appendingPathComponent("Backend/build/process-backend")
    }

    static func systemProcessList() async -> [ManagedProcess] {
        await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-axo", "pid=,pcpu=,pmem=,stat=,comm="]
            let output = Pipe()
            task.standardOutput = output
            do {
                try task.run(); task.waitUntilExit()
                guard task.terminationStatus == 0,
                      let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return [] }
                return text.split(separator: "\n").compactMap { line in
                    let fields = line.split(maxSplits: 4, whereSeparator: { $0 == " " || $0 == "\t" })
                    guard fields.count == 5, let pid = Int(fields[0]) else { return nil }
                    return ManagedProcess(pid: pid, name: String(fields[4]), cpu: String(fields[1]), memory: String(fields[2]), state: String(fields[3]), isNative: nil, isApplication: nil)
                }
            } catch { return [] }
        }.value
    }
}
