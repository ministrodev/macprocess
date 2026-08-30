import Foundation
import AppKit

enum StartupItemType: String, CaseIterable, Identifiable {
    case userAgent = "Inicialização do Usuário"
    case globalAgent = "Agente do Sistema"
    case backgroundDaemon = "Serviço em Segundo Plano"

    var id: String { rawValue }
    
    var requiresAdmin: Bool {
        switch self {
        case .userAgent: return false
        case .globalAgent, .backgroundDaemon: return true
        }
    }
}

struct StartupItem: Identifiable, Hashable {
    let id: String
    let name: String
    let label: String
    let path: String
    let executablePath: String?
    let type: StartupItemType
    var isEnabled: Bool
    let runAtLoad: Bool

    var displayIcon: NSImage? {
        if let exec = executablePath {
            let parts = exec.split(separator: "/").map(String.init)
            if let appIndex = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
                let appPath = "/" + parts[0...appIndex].joined(separator: "/")
                return NSWorkspace.shared.icon(forFile: appPath)
            }
            if FileManager.default.fileExists(atPath: exec) {
                return NSWorkspace.shared.icon(forFile: exec)
            }
        }

        let cleanName = name
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }),
           let icon = app.icon {
            return icon
        }

        return nil
    }
}

@MainActor
final class StartupStore: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var notice: ClosedNotice?

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        items = await loadStartupItems()
    }

    private func loadStartupItems() async -> [StartupItem] {
        return await Task.detached {
            var results: [StartupItem] = []
            let fileManager = FileManager.default
            let home = fileManager.homeDirectoryForCurrentUser.path

            let directories: [(path: String, type: StartupItemType)] = [
                ("\(home)/Library/LaunchAgents", .userAgent),
                ("/Library/LaunchAgents", .globalAgent),
                ("/Library/LaunchDaemons", .backgroundDaemon)
            ]

            for (dirPath, type) in directories {
                guard let files = try? fileManager.contentsOfDirectory(atPath: dirPath) else { continue }
                for file in files {
                    guard file.hasSuffix(".plist") || file.hasSuffix(".disabled") || file.contains(".plist.disabled") else { continue }

                    let fullPath = (dirPath as NSString).appendingPathComponent(file)

                    guard let dict = NSDictionary(contentsOfFile: fullPath) as? [String: Any] else { continue }

                    let label = dict["Label"] as? String ?? file

                    // FILTRO ESTRITO: Omitir processos nativos do Mac da Apple
                    let lowerLabel = label.lowercased()
                    if lowerLabel.hasPrefix("com.apple.") || lowerLabel.hasPrefix("apple.") {
                        continue
                    }

                    var execPath: String? = dict["Program"] as? String
                    if execPath == nil, let args = dict["ProgramArguments"] as? [String] {
                        if args.count > 1 && args[0] == "open" {
                            execPath = args[1]
                        } else if let first = args.first {
                            execPath = first
                        }
                    }

                    if let exec = execPath?.lowercased() {
                        if exec.hasPrefix("/system/") || exec.hasPrefix("/usr/libexec/") || exec.hasPrefix("/usr/sbin/") || exec.hasPrefix("/usr/bin/apple") {
                            continue
                        }
                    }

                    let runAtLoad = dict["RunAtLoad"] as? Bool ?? true
                    let plistDisabled = dict["Disabled"] as? Bool ?? false
                    let isFileDisabled = file.hasSuffix(".disabled")
                    let isEnabled = !plistDisabled && !isFileDisabled

                    let name = Self.extractDisplayName(label: label, execPath: execPath, filename: file)

                    results.append(StartupItem(
                        id: fullPath,
                        name: name,
                        label: label,
                        path: fullPath,
                        executablePath: execPath,
                        type: type,
                        isEnabled: isEnabled,
                        runAtLoad: runAtLoad
                    ))
                }
            }

            return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }

    nonisolated private static func extractDisplayName(label: String, execPath: String?, filename: String) -> String {
        if let exec = execPath {
            let parts = exec.split(separator: "/").map(String.init)
            if let app = parts.first(where: { $0.lowercased().hasSuffix(".app") }) {
                return String(app.dropLast(4))
            }
            if let last = parts.last, !last.isEmpty && last != "open" {
                return last
            }
        }

        let labelParts = label.split(separator: ".").map(String.init)
        if labelParts.count >= 2 {
            let last = labelParts.last ?? label
            let secondLast = labelParts[labelParts.count - 2]
            if last.count > 3 && last != "launcher" && last != "agent" && last != "daemon" {
                return last.prefix(1).uppercased() + last.dropFirst()
            }
            return secondLast.prefix(1).uppercased() + secondLast.dropFirst()
        }

        let base = filename.replacingOccurrences(of: ".plist", with: "").replacingOccurrences(of: ".disabled", with: "")
        return base
    }

    func toggle(item: StartupItem) async {
        let enable = !item.isEnabled
        let icon = item.displayIcon
        let uid = getuid()

        let success = await Task.detached { () -> (Bool, String?) in
            return Self.performToggle(item: item, enable: enable, uid: uid)
        }.value

        if success.0 {
            await refresh()
            notice = ClosedNotice(
                title: enable ? "Serviço Habilitado" : "Serviço Desabilitado",
                message: enable
                    ? "\"\(item.name)\" foi ativado e iniciará automaticamente com o sistema."
                    : "\"\(item.name)\" foi desativado com sucesso. Ele não será iniciado mesmo após reiniciar o sistema.",
                appName: item.name,
                icon: icon
            )
        } else {
            await refresh()
            let reason = success.1 ?? "Permissão negada ou operação cancelada."
            notice = ClosedNotice(
                title: "Falha ao Alterar Serviço",
                message: "Não foi possível \(enable ? "ativar" : "desativar") \"\(item.name)\":\n\(reason)",
                appName: item.name,
                icon: icon
            )
        }
    }

    nonisolated private static func performToggle(item: StartupItem, enable: Bool, uid: uid_t) -> (Bool, String?) {
        let currentPath = item.path
        let isSystemPath = item.type.requiresAdmin

        if enable {
            // Habilitar
            var targetPath = currentPath
            if currentPath.hasSuffix(".disabled") {
                targetPath = currentPath.replacingOccurrences(of: ".disabled", with: "")
            }

            if isSystemPath {
                let escapedCurrent = currentPath.replacingOccurrences(of: "\"", with: "\\\"")
                let escapedTarget = targetPath.replacingOccurrences(of: "\"", with: "\\\"")
                let script = """
                if [ -f "\(escapedCurrent)" ]; then mv "\(escapedCurrent)" "\(escapedTarget)"; fi;
                launchctl enable system/\(item.label) 2>/dev/null || true;
                launchctl enable gui/\(uid)/\(item.label) 2>/dev/null || true;
                launchctl bootstrap system "\(escapedTarget)" 2>/dev/null || launchctl load -w "\(escapedTarget)" 2>/dev/null || true
                """
                let (ok, output) = runWithAdminPrivileges(script)
                if !ok {
                    return (false, output.isEmpty ? "Operação cancelada pelo usuário." : output)
                }
                return (FileManager.default.fileExists(atPath: targetPath), nil)
            } else {
                // Usuário local
                if currentPath.hasSuffix(".disabled") {
                    try? FileManager.default.moveItem(atPath: currentPath, toPath: targetPath)
                }
                runCommand("/bin/launchctl", ["enable", "gui/\(uid)/\(item.label)"])
                runCommand("/bin/launchctl", ["bootstrap", "gui/\(uid)", targetPath])
                runCommand("/bin/launchctl", ["load", "-w", targetPath])
                return (FileManager.default.fileExists(atPath: targetPath), nil)
            }
        } else {
            // Desabilitar
            let targetDisabledPath = currentPath.hasSuffix(".disabled") ? currentPath : (currentPath + ".disabled")

            if isSystemPath {
                let escapedCurrent = currentPath.replacingOccurrences(of: "\"", with: "\\\"")
                let escapedDisabled = targetDisabledPath.replacingOccurrences(of: "\"", with: "\\\"")
                let script = """
                launchctl bootout system/\(item.label) 2>/dev/null || true;
                launchctl bootout gui/\(uid)/\(item.label) 2>/dev/null || true;
                launchctl unload -w "\(escapedCurrent)" 2>/dev/null || true;
                launchctl disable system/\(item.label) 2>/dev/null || true;
                launchctl disable gui/\(uid)/\(item.label) 2>/dev/null || true;
                if [ -f "\(escapedCurrent)" ]; then mv "\(escapedCurrent)" "\(escapedDisabled)"; fi
                """
                let (ok, output) = runWithAdminPrivileges(script)
                if !ok {
                    return (false, output.isEmpty ? "Operação cancelada ou permissão negada." : output)
                }
                let disabledExists = FileManager.default.fileExists(atPath: targetDisabledPath)
                let originalGone = !FileManager.default.fileExists(atPath: currentPath)
                return (disabledExists || originalGone, nil)
            } else {
                // Usuário local
                runCommand("/bin/launchctl", ["bootout", "gui/\(uid)/\(item.label)"])
                runCommand("/bin/launchctl", ["unload", "-w", currentPath])
                runCommand("/bin/launchctl", ["disable", "gui/\(uid)/\(item.label)"])

                if !currentPath.hasSuffix(".disabled") {
                    do {
                        try FileManager.default.moveItem(atPath: currentPath, toPath: targetDisabledPath)
                    } catch {
                        return (false, error.localizedDescription)
                    }
                }
                return (FileManager.default.fileExists(atPath: targetDisabledPath), nil)
            }
        }
    }

    nonisolated private static func runCommand(_ executable: String, _ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        try? task.run()
        task.waitUntilExit()
    }

    nonisolated private static func runWithAdminPrivileges(_ shellScript: String) -> (Bool, String) {
        // Escapa aspas para o AppleScript
        let escapedShell = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = "do shell script \"\(escapedShell)\" with administrator privileges"
        var errorDict: NSDictionary?
        if let scriptObj = NSAppleScript(source: appleScript) {
            let outputDesc = scriptObj.executeAndReturnError(&errorDict)
            if let error = errorDict {
                let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "Erro de autorização"
                return (false, errorMsg)
            }
            return (true, outputDesc.stringValue ?? "")
        }
        return (false, "Falha ao inicializar o serviço de autenticação do macOS.")
    }
}
