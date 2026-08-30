import SwiftUI
import AppKit

enum AppTab: String, CaseIterable {
    case processes = "Processos"
    case startup = "Inicialização & 2º Plano"
}

struct DashboardView: View {
    @StateObject private var store = ProcessStore()
    @StateObject private var startupStore = StartupStore()
    
    @State private var currentTab: AppTab = .processes
    @State private var search = ""
    @State private var showNative = false
    @State private var expandedGroups: Set<String> = []
    @State private var showAllInstalled = false
    @State private var selectedId: String?
    @State private var selectedStartupId: String?

    private var filtered: [ManagedProcess] {
        search.isEmpty ? store.processes : store.processes.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var installed: [ManagedProcess] {
        filtered.filter { !$0.isNativeProcess && $0.belongsToApplication }
    }
    private var native: [ManagedProcess] {
        filtered.filter { $0.isNativeProcess || !$0.belongsToApplication }
    }

    private var filteredStartupItems: [StartupItem] {
        if search.isEmpty { return startupStore.items }
        return startupStore.items.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.label.localizedCaseInsensitiveContains(search) ||
            $0.type.rawValue.localizedCaseInsensitiveContains(search)
        }
    }

    private var cpuAverage: Double {
        let total = store.processes.reduce(0.0) { sum, p in
            sum + p.cpuValue
        }
        return min(100.0, total)
    }

    private var activeNotice: ClosedNotice? {
        store.closedNotice ?? startupStore.notice
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            
            VStack(spacing: 16) {
                header
                
                if currentTab == .processes {
                    HStack(alignment: .top, spacing: 18) {
                        sidebar
                        VStack(alignment: .leading, spacing: 12) {
                            processList
                            bottomBar
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        startupSidebar
                        VStack(alignment: .leading, spacing: 12) {
                            startupList
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .padding(20)

            // MARK: - Popup Modal com Animação Fluida de Abertura e Fechamento
            if let notice = activeNotice {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        dismissModal()
                    }

                VStack(spacing: 16) {
                    let isError = notice.title.lowercased().contains("falha") || notice.title.lowercased().contains("não foi possível")

                    if let icon = notice.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isError ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.12))
                                .frame(width: 64, height: 64)
                            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(isError ? Color.red : Color.accentColor)
                        }
                    }

                    VStack(spacing: 6) {
                        Text(notice.title)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(isError ? Color.red : Color.primary)

                        Text(notice.message)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)

                    Button {
                        dismissModal()
                    } label: {
                        Text("OK")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minWidth: 90)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 20)
                            .background(isError ? Color.red : Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(24)
                .frame(width: 340)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.35), radius: 25, y: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.82).combined(with: .opacity),
                        removal: .scale(scale: 0.88).combined(with: .opacity)
                    )
                )
                .zIndex(100)
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .animation(.spring(response: 0.32, dampingFraction: 0.76), value: activeNotice != nil)
        .task {
            await store.liveUpdates()
        }
        .task {
            await startupStore.refresh()
        }
        .alert(
            "Ação indisponível",
            isPresented: Binding(
                get: { store.errorMessage != nil || startupStore.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil; startupStore.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? startupStore.errorMessage ?? "")
        }
    }

    private func dismissModal() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
            store.closedNotice = nil
            startupStore.notice = nil
        }
    }

    // MARK: - Header com Tab Switcher Moderno
    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                if let appIcon = AppIconProvider.loadAppIcon() {
                    Image(nsImage: appIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 36, height: 36)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                            )
                        Image(systemName: currentTab == .processes ? "cpu" : "bolt.shield")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacProcess")
                        .font(.headline.bold())
                        .foregroundStyle(.primary)
                    Text(currentTab == .processes ? "Gerenciador de Processos" : "Itens de Inicialização & Background")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Tab Switcher
            HStack(spacing: 4) {
                tabButton(title: "Processos", icon: "cpu", tab: .processes)
                tabButton(title: "Inicialização & 2º Plano", icon: "bolt.shield", tab: .startup)
            }
            .padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Spacer()

            // Barra de busca
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField(currentTab == .processes ? "Buscar processos..." : "Buscar inicialização...", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(width: 220)
            .background(Color.primary.opacity(0.04), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))

            // Botão atualizar
            Button {
                Task {
                    if currentTab == .processes {
                        await store.refresh()
                    } else {
                        await startupStore.refresh()
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 32, height: 32)

                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading || startupStore.isLoading)
            .help("Atualizar lista")
        }
    }

    private func tabButton(title: String, icon: String, tab: AppTab) -> some View {
        let isSelected = currentTab == tab
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                currentTab = tab
                search = ""
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .shadow(color: isSelected ? Color.black.opacity(0.08) : Color.clear, radius: 2, y: 1)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sidebar de Processos
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Text(macName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            Divider().overlay(Color.primary.opacity(0.08))

            VStack(alignment: .leading, spacing: 10) {
                specItem(label: "Memória RAM", value: "\(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) GB")
                specItem(label: "CPU", value: "\(ProcessInfo.processInfo.processorCount) Núcleos")
                specItem(label: "Total de Processos", value: "\(store.processes.count)")
                specItem(label: "Apps Instalados", value: "\(installed.count)")
                specItem(label: "Processos Nativos", value: "\(native.count)")
                specItem(label: "Status", value: "Em Execução", isBlue: true)
            }

            Spacer()

            developerFooter
        }
        .padding(18)
        .frame(width: 220)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Sidebar de Inicialização
    private var startupSidebar: some View {
        let total = startupStore.items.count
        let enabledCount = startupStore.items.filter(\.isEnabled).count
        let disabledCount = total - enabledCount

        return VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 6) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 4)

                Text("Inicialização")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            Divider().overlay(Color.primary.opacity(0.08))

            VStack(alignment: .leading, spacing: 10) {
                specItem(label: "Total de Itens", value: "\(total)")
                specItem(label: "Itens Habilitados", value: "\(enabledCount)", isBlue: true)
                specItem(label: "Itens Desabilitados", value: "\(disabledCount)")
                specItem(label: "Filtro Ativo", value: "Sem Nativos Mac")
            }

            Divider().overlay(Color.primary.opacity(0.08))

            VStack(alignment: .leading, spacing: 6) {
                Text("Dica de Desempenho")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("Desabilitar apps de inicialização acelera o boot do macOS e economiza memória RAM.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }

            Spacer()

            developerFooter
        }
        .padding(18)
        .frame(width: 220)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Rodapé do Desenvolvedor na Barra Lateral
    private var developerFooter: some View {
        VStack(spacing: 10) {
            Divider().overlay(Color.primary.opacity(0.08))

            // Logo Centralizada
            Link(destination: URL(string: "https://ministrodev.com")!) {
                MinistroLogoView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .help("Ministro Developer - ministrodev.com")
            .padding(.top, 2)

            // Ícones Interativos: Website, Email, GitHub, Instagram
            HStack(spacing: 10) {
                // Website
                Link(destination: URL(string: "https://ministrodev.com")!) {
                    iconButton(systemName: "globe", helpText: "Website: ministrodev.com")
                }
                .buttonStyle(.plain)

                // E-mail
                Link(destination: URL(string: "mailto:contato@ministrodev.com")!) {
                    iconButton(systemName: "envelope.fill", helpText: "E-mail: contato@ministrodev.com")
                }
                .buttonStyle(.plain)

                // GitHub
                Link(destination: URL(string: "https://github.com/ministrodev/macprocess")!) {
                    iconButton(systemName: "chevron.left.forwardslash.chevron.right", helpText: "GitHub: github.com/ministrodev/macprocess")
                }
                .buttonStyle(.plain)

                // Instagram
                Link(destination: URL(string: "https://instagram.com/ministrodev")!) {
                    iconButton(systemName: "camera.circle.fill", helpText: "Instagram: @ministrodev")
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func iconButton(systemName: String, helpText: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 28, height: 28)
        .help(helpText)
    }

    private func specItem(label: String, value: String, isBlue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(isBlue ? Color.accentColor : .primary)
        }
    }

    private var macName: String {
        let name = Host.current().localizedName ?? "Mac"
        return name.isEmpty ? "MacBook Pro" : name
    }

    // MARK: - Process List (Ordenação Estável)
    private var processList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PROCESSO").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 75, alignment: .center)
                Text("MEM").frame(width: 75, alignment: .center)
                Text("AÇÕES").frame(width: 70, alignment: .center)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().overlay(Color.primary.opacity(0.10))

            ScrollView {
                LazyVStack(spacing: 0) {
                    let installedGroups = processGroups(installed, prefix: "installed")
                    sectionTitle("APLICATIVOS INSTALADOS", count: installedGroups.count)

                    ForEach(showAllInstalled ? installedGroups : Array(installedGroups.prefix(8))) { group in
                        groupRows(group)
                    }

                    if installedGroups.count > 8 {
                        Button(showAllInstalled ? "Mostrar menos" : "Ver mais (\(installedGroups.count - 8))") {
                            withAnimation(.easeInOut(duration: 0.2)) { showAllInstalled.toggle() }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                        .font(.caption.weight(.medium))
                        .padding(.vertical, 8)
                    }

                    if !native.isEmpty {
                        VStack(spacing: 0) {
                            Divider().overlay(Color.primary.opacity(0.10))
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showNative.toggle() }
                            } label: {
                                HStack {
                                    Image(systemName: showNative ? "chevron.down" : "chevron.right")
                                        .font(.caption2.bold())
                                    Text("PROCESSOS NATIVOS DO macOS")
                                        .font(.caption2.weight(.bold))
                                    Spacer()
                                    Text("\(native.count)")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .background(Color.primary.opacity(0.035))

                            Divider().overlay(Color.primary.opacity(0.10))
                        }

                        if showNative {
                            ForEach(processGroups(native, prefix: "native")) { group in
                                groupRows(group)
                            }
                        }
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .overlay {
            if store.isLoading {
                ProgressView().controlSize(.regular)
            }
        }
    }

    // MARK: - Startup List (Apps em Segundo Plano & Inicialização)
    private var startupList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("APLICATIVO / SERVIÇO").frame(maxWidth: .infinity, alignment: .leading)
                Text("TIPO").frame(width: 200, alignment: .leading)
                Text("INICIALIZAÇÃO").frame(width: 100, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().overlay(Color.primary.opacity(0.10))

            if filteredStartupItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                    Text(search.isEmpty ? "Nenhum aplicativo de inicialização de terceiros encontrado." : "Nenhum resultado para \"\(search)\".")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(StartupItemType.allCases) { type in
                            let itemsOfType = filteredStartupItems.filter { $0.type == type }
                            if !itemsOfType.isEmpty {
                                sectionTitle(type.rawValue.uppercased(), count: itemsOfType.count)
                                ForEach(itemsOfType) { item in
                                    startupRow(item)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .overlay {
            if startupStore.isLoading {
                ProgressView().controlSize(.regular)
            }
        }
    }

    private func startupRow(_ item: StartupItem) -> some View {
        let isSelected = selectedStartupId == item.id
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let icon = item.displayIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 32, height: 32)
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(item.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.type.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 200, alignment: .leading)

                // Toggle Seletor
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { _ in
                        Task { await startupStore.toggle(item: item) }
                    }
                ))
                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                .labelsHidden()
                .frame(width: 100, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.001)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedStartupId = (selectedStartupId == item.id) ? nil : item.id
            }

            Divider().overlay(Color.primary.opacity(0.06))
        }
    }

    // MARK: - Barra de Atividade Inferior
    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text("Carga de CPU:")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 5)

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(8, geo.size.width * CGFloat(min(1.0, cpuAverage / 100.0))), height: 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 10)

            Text("\(Int(cpuAverage))%")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 45, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Título de Seção
    private func sectionTitle(_ title: String, count: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.035))

            Divider().overlay(Color.primary.opacity(0.10))
        }
    }

    private func row(_ process: ManagedProcess, showDivider: Bool = true) -> some View {
        let isSelected = selectedId == "pid-\(process.pid)"
        return ProcessRow(
            process: process,
            isSelected: isSelected,
            showDivider: showDivider,
            onSelect: {
                selectedId = (selectedId == "pid-\(process.pid)") ? nil : "pid-\(process.pid)"
            },
            terminate: { Task { await store.terminate(process) } }
        )
    }

    // MARK: - Agrupamento e Ordenação Estável
    private func processGroups(_ processes: [ManagedProcess], prefix: String) -> [ProcessGroup] {
        Dictionary(grouping: processes, by: \.displayName).map { name, members in
            ProcessGroup(
                id: "\(prefix)-\(name)",
                name: name,
                processes: members.sorted {
                    if $0.displayName != $1.displayName {
                        return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    }
                    return $0.pid < $1.pid
                }
            )
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @ViewBuilder private func groupRows(_ group: ProcessGroup) -> some View {
        if group.processes.count == 1, let process = group.processes.first {
            row(process)
        } else {
            let isExpanded = expandedGroups.contains(group.id)
            let isGroupSelected = selectedId == group.id

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    AppIcon(pid: group.processes[0].pid, appName: group.name)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                            .font(.system(size: 13, weight: .medium))
                        Text("\(group.processes.count) subprocessos")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(group.cpuTotal).font(.system(size: 12)).frame(width: 75, alignment: .center)
                    Text(group.memoryTotal).font(.system(size: 12)).frame(width: 75, alignment: .center)

                    HStack(spacing: 6) {
                        Button {
                            Task { await store.terminateGroup(processes: group.processes, groupName: group.name) }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.accentColor.opacity(0.28), lineWidth: 0.8)
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help("Encerrar todos os subprocessos")

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isExpanded {
                                    expandedGroups.remove(group.id)
                                } else {
                                    expandedGroups.insert(group.id)
                                }
                            }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help(isExpanded ? "Recolher subprocessos" : "Expandir subprocessos")
                    }
                    .frame(width: 70, alignment: .center)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedId = (selectedId == group.id) ? nil : group.id
                }

                if isExpanded {
                    Divider().overlay(Color.primary.opacity(0.06))
                    ForEach(Array(group.processes.enumerated()), id: \.element.id) { index, child in
                        let isChildSelected = selectedId == "pid-\(child.pid)"
                        HStack(spacing: 8) {
                            AppIcon(pid: child.pid, appName: child.displayName)
                                .frame(width: 22, height: 22)
                                .opacity(0.8)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(child.displayName).lineLimit(1).font(.system(size: 12))
                                Text("PID \(child.pid)").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text("\(child.cpu)%").font(.system(size: 12)).frame(width: 75, alignment: .center)
                            Text("\(child.memory)%").font(.system(size: 12)).frame(width: 75, alignment: .center)

                            Button {
                                Task { await store.terminate(child) }
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.12))
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.28), lineWidth: 0.8)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .help("Encerrar Processo")
                            .frame(width: 70, alignment: .center)
                        }
                        .padding(.leading, 26)
                        .padding(.trailing, 14)
                        .padding(.vertical, 6)
                        .background(
                            isChildSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.015)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedId = (selectedId == "pid-\(child.pid)") ? nil : "pid-\(child.pid)"
                        }

                        if index < group.processes.count - 1 {
                            Divider()
                                .padding(.leading, 26)
                                .overlay(Color.primary.opacity(0.05))
                        }
                    }
                }
            }
            .background(
                isGroupSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isGroupSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: isGroupSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
    }
}

// MARK: - Linha de Processo Individual
private struct ProcessRow: View {
    let process: ManagedProcess
    var isSelected: Bool = false
    var showDivider: Bool = true
    var onSelect: () -> Void = {}
    let terminate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AppIcon(pid: process.pid, appName: process.displayName)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(process.displayName).lineLimit(1).font(.system(size: 13, weight: .medium))
                    Text("PID \(process.pid)").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(process.cpu)%").font(.system(size: 12)).frame(width: 75, alignment: .center)
                Text("\(process.memory)%").font(.system(size: 12)).frame(width: 75, alignment: .center)

                Button(action: terminate) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.28), lineWidth: 0.8)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Encerrar Processo")
                .frame(width: 70, alignment: .center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.001)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }

            if showDivider {
                Divider().overlay(Color.primary.opacity(0.08))
            }
        }
    }
}

// MARK: - Modelo de Grupo de Processos
private struct ProcessGroup: Identifiable {
    let id: String
    let name: String
    let processes: [ManagedProcess]

    var cpuDouble: Double {
        processes.reduce(0.0) { $0 + $1.cpuValue }
    }
    var memDouble: Double {
        processes.reduce(0.0) { $0 + $1.memoryValue }
    }

    var cpuTotal: String {
        String(format: "%.1f%%", cpuDouble)
    }
    var memoryTotal: String {
        String(format: "%.1f%%", memDouble)
    }
    var isActive: Bool { processes.contains(where: \.isActive) }
}

// MARK: - Extensão de Apoio para Conversão Numérica
private extension ManagedProcess {
    var cpuValue: Double {
        Double(cpu.replacingOccurrences(of: ",", with: ".")) ?? 0.0
    }
    var memoryValue: Double {
        Double(memory.replacingOccurrences(of: ",", with: ".")) ?? 0.0
    }
}

// MARK: - Ícone de Aplicativo
private struct AppIcon: View {
    let pid: Int
    let appName: String

    var body: some View {
        if let icon = matchingApplication?.icon ?? NSRunningApplication(processIdentifier: pid_t(pid))?.icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var matchingApplication: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.localizedCaseInsensitiveCompare(appName) == .orderedSame
        }
    }
}
