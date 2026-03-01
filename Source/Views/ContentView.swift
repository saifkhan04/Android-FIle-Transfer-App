import SwiftUI
import AppKit

private enum UITheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var hoveredRemoteEntryID: String? = nil
    @State private var hoveredLocalEntryID: String? = nil
    @State private var footerHeight: CGFloat = 200
    @State private var footerDragStartHeight: CGFloat? = nil
    @State private var pendingDeleteTarget: DeleteTarget?
    @AppStorage("ui_theme") private var uiThemeRaw: String = UITheme.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private enum DeleteTarget {
        case remote
        case local
    }

    private var selectedTheme: UITheme {
        get { UITheme(rawValue: uiThemeRaw) ?? .system }
        set { uiThemeRaw = newValue.rawValue }
    }

    private var appBackground: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.09, blue: 0.12),
                    Color(red: 0.11, green: 0.13, blue: 0.17)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.96, blue: 0.98),
                Color(red: 0.91, green: 0.94, blue: 0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            appBackground
            .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DroidTransfer")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(colorScheme == .dark ? .white : .primary)
                        Text("Android and Mac file transfer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("Theme", selection: $uiThemeRaw) {
                        ForEach(UITheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .fixedSize(horizontal: true, vertical: false)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(vm.deviceSerial.isEmpty ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                        Text(vm.deviceSerial.isEmpty ? "No device" : vm.deviceDisplayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.35 : 0.9),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                )

                HStack(spacing: 12) {
                    RemotePaneView(
                        vm: vm,
                        hoveredEntryID: $hoveredRemoteEntryID,
                        onRequestDelete: { pendingDeleteTarget = .remote }
                    )
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                    )

                    LocalPaneView(
                        vm: vm,
                        hoveredEntryID: $hoveredLocalEntryID,
                        onRequestDelete: { pendingDeleteTarget = .local }
                    )
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                TransferQueueView(
                    vm: vm,
                    footerHeight: $footerHeight,
                    footerDragStartHeight: $footerDragStartHeight
                )
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                )
            }
            .padding(12)
        }
        .frame(minWidth: 840, minHeight: 620)
        .onAppear {
            applyThemeAppearance()
        }
        .onChange(of: uiThemeRaw) { _ in
            applyThemeAppearance()
        }
        .task {
            await vm.initialize()
        }
        .confirmationDialog(
            pendingDeleteTarget == .remote ? "Delete selected remote item(s)?" : "Delete selected local item(s)?",
            isPresented: Binding(
                get: { pendingDeleteTarget != nil },
                set: { if !$0 { pendingDeleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let target = pendingDeleteTarget else { return }
                pendingDeleteTarget = nil
                switch target {
                case .remote:
                    Task { await vm.deleteSelectedRemote() }
                case .local:
                    vm.deleteSelectedLocal()
                }
            }

            Button("Cancel", role: .cancel) {
                pendingDeleteTarget = nil
            }
        } message: {
            if pendingDeleteTarget == .remote {
                Text("This will permanently delete selected files/folders from your Android device.")
            } else {
                Text("This will permanently delete selected files/folders from your Mac.")
            }
        }
    }

    private func applyThemeAppearance() {
        switch selectedTheme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
