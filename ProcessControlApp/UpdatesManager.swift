import Foundation

struct SystemUpdate: Identifiable {
    let id: String
    let title: String
    let detail: String
}

@MainActor
final class UpdatesStore: ObservableObject {
    @Published private(set) var updates: [SystemUpdate] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var statusMessage = "Ainda não verificado"
    @Published private(set) var isInstalling = false
    @Published var installResult: String?
    @Published private(set) var automaticChecksEnabled: Bool?
    @Published private(set) var isChangingAutomaticChecks = false
    @Published var automaticChecksResult: String?
    @Published var notice: ClosedNotice?

    func refresh() async {
        guard !isInstalling else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await Task.detached { Self.availableUpdates() }.value
        updates = result.updates
        statusMessage = result.message
        automaticChecksEnabled = result.automaticChecksEnabled
        lastUpdated = Date()
    }

    func installAllAvailable() async {
        guard !isInstalling else { return }
        isInstalling = true
        installResult = nil
        let result = await Task.detached { Self.installAll() }.value
        isInstalling = false
        installResult = result.message
        await refresh()
    }

    func enableAutomaticChecks() async {
        guard !isChangingAutomaticChecks else { return }
        isChangingAutomaticChecks = true
        automaticChecksResult = nil
        let result = await Task.detached { Self.enableAutomaticChecksWithAuthorization() }.value
        isChangingAutomaticChecks = false
        automaticChecksResult = result.message
        if result.success {
            await refresh()
            notice = ClosedNotice(
                title: "Buscas Automáticas Ativadas",
                message: "O macOS agora buscará atualizações automaticamente.",
                appName: "Atualizações",
                icon: nil
            )
        } else {
            notice = ClosedNotice(
                title: "Falha ao Ativar Buscas Automáticas",
                message: result.message,
                appName: "Atualizações",
                icon: nil
            )
        }
    }

    /// Consulta apenas a ferramenta oficial do macOS; não instala, oculta ou remove atualizações.
    nonisolated private static func availableUpdates() -> (updates: [SystemUpdate], message: String, automaticChecksEnabled: Bool?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        process.arguments = ["--list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let schedule = automaticScheduleState()
            let lower = text.lowercased()
            if lower.contains("no new software available") || lower.contains("nenhuma atualização disponível") {
                return ([], "Seu macOS está atualizado", schedule)
            }

            let entries = text.split(separator: "\n").compactMap { line -> SystemUpdate? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("*") || trimmed.hasPrefix("-") else { return nil }
                let title = trimmed.drop(while: { $0 == "*" || $0 == "-" || $0 == " " })
                guard !title.isEmpty else { return nil }
                return SystemUpdate(id: String(title), title: String(title), detail: "Disponível pelo Atualização de Software do macOS")
            }
            return (entries, entries.isEmpty ? "Não foi possível identificar atualizações nesta consulta" : "Atualizações disponíveis", schedule)
        } catch {
            return ([], "Não foi possível consultar o serviço de atualização", nil)
        }
    }

    nonisolated private static func automaticScheduleState() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        process.arguments = ["--schedule"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let text = (String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").lowercased()
            if text.contains("turned on") || text.contains(" is on") || text.contains("ativad") { return true }
            if text.contains("turned off") || text.contains(" is off") || text.contains("desativad") { return false }
            return nil
        } catch {
            return nil
        }
    }

    nonisolated private static func enableAutomaticChecksWithAuthorization() -> (success: Bool, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"/usr/sbin/softwareupdate --schedule on\" with administrator privileges"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return (true, "As buscas automáticas por atualizações foram ativadas.")
            }
            let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (false, message.isEmpty ? "A alteração foi cancelada ou não pôde ser concluída." : message)
        } catch {
            return (false, "Não foi possível alterar a configuração: \(error.localizedDescription)")
        }
    }

    /// Usa o instalador oficial e faz o macOS solicitar a credencial administrativa.
    nonisolated private static func installAll() -> (success: Bool, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"/usr/sbin/softwareupdate --install --all\" with administrator privileges"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus == 0 {
                return (true, "As atualizações disponíveis foram enviadas para instalação. Algumas podem exigir reinicialização.")
            }
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, message.isEmpty ? "A instalação foi cancelada ou não pôde ser concluída." : message)
        } catch {
            return (false, "Não foi possível iniciar o instalador: \(error.localizedDescription)")
        }
    }
}
