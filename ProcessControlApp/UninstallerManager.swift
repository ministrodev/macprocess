import Foundation
import AppKit

struct InstalledApplication: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleIdentifier: String
    let source: String
    let size: Int64
    var id: String { url.path }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

struct AppResidual: Identifiable, Hashable {
    let url: URL
    let category: String
    let isOrphan: Bool
    let size: Int64
    var id: String { url.path }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var displayName: String {
        let value = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".savedState", with: "")
        return value.split(separator: ".").last.map(String.init) ?? value
    }

    var probablePublisher: String {
        let value = url.deletingPathExtension().lastPathComponent
        let parts = value.split(separator: ".")
        return parts.count > 1 ? String(parts[parts.count - 2]).capitalized : "Não identificado"
    }

    init(url: URL, category: String, isOrphan: Bool) {
        self.url = url
        self.category = category
        self.isOrphan = isOrphan
        self.size = Self.directorySize(url)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        return enumerator.reduce(Int64(0)) { total, item in
            guard let file = item as? URL,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }
}

@MainActor
final class UninstallerStore: ObservableObject {
    @Published private(set) var applications: [InstalledApplication] = []
    @Published private(set) var residuals: [AppResidual] = []
    @Published private(set) var orphanedResiduals: [AppResidual] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var selectedTotalSize: Int64 = 0
    @Published var notice: ClosedNotice?
    private var scanningApplicationID: String?

    func refresh() async {
        isLoading = true
        let apps = await Task.detached { Self.findApplications() }.value
        applications = apps
        isLoading = false
        orphanedResiduals = await Task.detached { Self.findOrphans(knownBundleIDs: Set(apps.map(\.bundleIdentifier))) }.value
    }

    func scanResiduals(for app: InstalledApplication) async {
        let appID = app.id
        scanningApplicationID = appID
        isScanning = true
        let result = await Task.detached { Self.findResiduals(for: app) }.value
        guard scanningApplicationID == appID else { return }
        residuals = result.residuals
        selectedTotalSize = result.totalSize
        isScanning = false
        scanningApplicationID = nil
    }

    func moveToTrash(app: InstalledApplication, residuals selectedResiduals: [AppResidual]) async -> Bool {
        isRemoving = true
        let recoveredSize = app.size + selectedResiduals.reduce(0) { $0 + $1.size }
        let result = await Task.detached { Self.trash([app.url] + selectedResiduals.map(\.url)) }.value
        isRemoving = false
        let appRemoved = !result.failed.contains(app.url)
        notice = ClosedNotice(
            title: result.failed.isEmpty ? "Enviado para a Lixeira" : "Remoção parcialmente concluída",
            message: result.failed.isEmpty
                ? "\(ByteCountFormatter.string(fromByteCount: recoveredSize, countStyle: .file)) foram liberados. Os itens estão na Lixeira e podem ser recuperados até ela ser esvaziada."
                : result.message,
            appName: app.name,
            icon: app.icon
        )
        if appRemoved { await refresh(); residuals = []; selectedTotalSize = 0 }
        return appRemoved
    }

    func moveOrphansToTrash(_ selected: [AppResidual]) async -> Bool {
        guard !selected.isEmpty else { return false }
        isRemoving = true
        let recoveredSize = selected.reduce(0) { $0 + $1.size }
        let result = await Task.detached { Self.trash(selected.map(\.url)) }.value
        isRemoving = false
        notice = ClosedNotice(
            title: result.failed.isEmpty ? "Resíduos enviados para a Lixeira" : "Alguns resíduos não foram movidos",
            message: result.failed.isEmpty
                ? "\(ByteCountFormatter.string(fromByteCount: recoveredSize, countStyle: .file)) foram enviados para a Lixeira e poderão ser recuperados até ela ser esvaziada."
                : result.message,
            appName: "Resíduos",
            icon: nil
        )
        await refresh()
        return result.failed.isEmpty
    }

    nonisolated private static func findApplications() -> [InstalledApplication] {
        let manager = FileManager.default
        let folders = ["/Applications", manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var found: [InstalledApplication] = []
        for folder in folders {
            guard let urls = try? manager.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil) else { continue }
            for url in urls where url.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: url),
                      let identifier = bundle.bundleIdentifier,
                      !identifier.hasPrefix("com.apple.") else { continue }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                found.append(InstalledApplication(url: url, name: name, bundleIdentifier: identifier, source: folder, size: AppResidual.directorySize(url)))
            }
        }
        return found.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func findResiduals(for app: InstalledApplication) -> (residuals: [AppResidual], totalSize: Int64) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let id = app.bundleIdentifier
        let names = [id, app.name, app.url.deletingPathExtension().lastPathComponent]
        let direct: [(String, URL)] = [
            ("Dados do app", home.appendingPathComponent("Library/Application Support/\(id)")),
            ("Cache", home.appendingPathComponent("Library/Caches/\(id)")),
            ("Preferências", home.appendingPathComponent("Library/Preferences/\(id).plist")),
            ("Logs", home.appendingPathComponent("Library/Logs/\(id)")),
            ("Estado salvo", home.appendingPathComponent("Library/Saved Application State/\(id).savedState")),
            ("Container", home.appendingPathComponent("Library/Containers/\(id)"))
        ]
        var results = direct.compactMap { category, url -> AppResidual? in
            FileManager.default.fileExists(atPath: url.path) ? AppResidual(url: url, category: category, isOrphan: false) : nil
        }
        let searchable = [
            ("Dados do app", home.appendingPathComponent("Library/Application Support")),
            ("Cache", home.appendingPathComponent("Library/Caches")),
            ("Logs", home.appendingPathComponent("Library/Logs"))
        ]
        for (category, folder) in searchable {
            guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for child in children where names.contains(where: { child.lastPathComponent.localizedCaseInsensitiveContains($0) }) {
                results.append(AppResidual(url: child, category: category, isOrphan: false))
            }
        }
        let unique = Array(Set(results)).sorted { $0.url.path < $1.url.path }
        return (unique, AppResidual.directorySize(app.url) + unique.reduce(0) { $0 + $1.size })
    }

    nonisolated private static func findOrphans(knownBundleIDs: Set<String>) -> [AppResidual] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [
            ("Cache sem app", home.appendingPathComponent("Library/Caches")),
            ("Dados sem app", home.appendingPathComponent("Library/Application Support")),
            ("Preferência sem app", home.appendingPathComponent("Library/Preferences")),
            ("Estado salvo sem app", home.appendingPathComponent("Library/Saved Application State"))
        ]
        var results: [AppResidual] = []
        for (category, folder) in folders {
            guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for child in children {
                let name = child.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".savedState", with: "")
                guard name.contains("."),
                      !name.hasPrefix("com.apple."),
                      !knownBundleIDs.contains(name),
                      child.path.hasPrefix(home.path + "/Library/") else { continue }
                results.append(AppResidual(url: child, category: category, isOrphan: true))
            }
        }
        return results.sorted { $0.url.path < $1.url.path }
    }

    nonisolated private static func trash(_ urls: [URL]) -> (failed: [URL], message: String) {
        var failed: [URL] = []
        for url in Set(urls) {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { failed.append(url) }
        }
        if failed.isEmpty { return ([], "Os itens selecionados foram movidos para a Lixeira e podem ser recuperados até ela ser esvaziada.") }
        return (failed, "\(urls.count - failed.count) item(ns) foram enviados para a Lixeira. \(failed.count) exigem permissão adicional ou estão em uso.")
    }
}
