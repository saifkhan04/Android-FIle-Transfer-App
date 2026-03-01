import SwiftUI

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var hoveredRemoteEntryID: String? = nil
    @State private var hoveredLocalEntryID: String? = nil
    @State private var footerHeight: CGFloat = 200
    @State private var footerDragStartHeight: CGFloat? = nil
    @State private var pendingDeleteTarget: DeleteTarget?

    private enum DeleteTarget {
        case remote
        case local
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                Text("Device: \(vm.deviceDisplayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            HStack(spacing: 0) {
                RemotePaneView(
                    vm: vm,
                    hoveredEntryID: $hoveredRemoteEntryID,
                    onRequestDelete: { pendingDeleteTarget = .remote }
                )

                Divider()
                    .frame(maxHeight: .infinity)

                LocalPaneView(
                    vm: vm,
                    hoveredEntryID: $hoveredLocalEntryID,
                    onRequestDelete: { pendingDeleteTarget = .local }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            TransferQueueView(
                vm: vm,
                footerHeight: $footerHeight,
                footerDragStartHeight: $footerDragStartHeight
            )
        }
        .frame(minWidth: 840, minHeight: 620)
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
}
