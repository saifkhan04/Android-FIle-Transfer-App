import SwiftUI
import AppKit

struct RemotePaneView: View {
    @ObservedObject var vm: AppViewModel
    @Binding var hoveredEntryID: String?
    let onRequestDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    vm.toggleSelectAllRemote()
                } label: {
                    Image(systemName: vm.isAllRemoteSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(vm.isAllRemoteSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Select/Deselect all in Android pane")

                Text("Android")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(vm.remoteCurrentPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                Button {
                    Task { await vm.remoteBack() }
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .help("Back")
                .font(.caption)
                .disabled(vm.isBusy || !vm.canRemoteBack)

                Button {
                    Task { await vm.remoteForward() }
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .help("Forward")
                .font(.caption)
                .disabled(vm.isBusy || !vm.canRemoteForward)

                Button {
                    onRequestDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected remote item(s)")
                .font(.caption)
                .disabled(vm.isBusy || vm.selectedRemoteEntryIDs.isEmpty || vm.deviceSerial.isEmpty)

                Button {
                    Task { await vm.downloadSelectedRemoteToLocal() }
                } label: {
                    Image(systemName: "arrow.down.to.line.compact")
                }
                .help("Transfer selected Android item(s) to Mac folder")
                .font(.caption)
                .disabled(vm.isBusy || vm.selectedRemoteEntryIDs.isEmpty || vm.deviceSerial.isEmpty)

                Button {
                    Task { await vm.refreshRemoteDirectory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Android pane")
                .font(.caption)
                .disabled(vm.isBusy || vm.deviceSerial.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.remoteEntries) { entry in
                        HStack(spacing: 10) {
                            Button {
                                vm.toggleRemoteSelection(id: entry.id)
                            } label: {
                                Image(systemName: vm.selectedRemoteEntryIDs.contains(entry.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(vm.selectedRemoteEntryIDs.contains(entry.id) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)

                            Image(systemName: entry.isDirectory ? "folder" : "doc")

                            Text(entry.name)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(remoteRowBackgroundColor(for: entry.id))
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            hoveredEntryID = isHovering ? entry.id : nil
                        }
                        .onTapGesture {
                            let isCommand = NSEvent.modifierFlags.contains(.command)
                            vm.handleRemoteRowSelection(id: entry.id, commandPressed: isCommand)
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            guard entry.isDirectory else { return }
                            vm.handleRemoteRowSelection(id: entry.id, commandPressed: false)
                            Task { await vm.openRemoteDirectory(entry) }
                        })
                    }
                }
            }
            .id("remote-\(vm.remoteCurrentPath)-\(vm.remoteListRevision)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func remoteRowBackgroundColor(for id: String) -> Color {
        if vm.selectedRemoteEntryIDs.contains(id) {
            return Color.accentColor.opacity(0.22)
        }
        if hoveredEntryID == id {
            return Color.accentColor.opacity(0.08)
        }
        return .clear
    }
}

struct LocalPaneView: View {
    @ObservedObject var vm: AppViewModel
    @Binding var hoveredEntryID: String?
    let onRequestDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    vm.toggleSelectAllLocal()
                } label: {
                    Image(systemName: vm.isAllLocalSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(vm.isAllLocalSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Select/Deselect all in Mac pane")

                Text("Mac")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(vm.localCurrentPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                Button {
                    vm.localBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .help("Back")
                .font(.caption)
                .disabled(vm.isBusy || !vm.canLocalBack)

                Button {
                    vm.localForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .help("Forward")
                .font(.caption)
                .disabled(vm.isBusy || !vm.canLocalForward)

                Button {
                    onRequestDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected local item(s)")
                .font(.caption)
                .disabled(vm.isBusy || vm.selectedLocalEntryIDs.isEmpty)

                Button {
                    Task { await vm.uploadSelectedLocalToRemote() }
                } label: {
                    Image(systemName: "arrow.up.to.line.compact")
                }
                .help("Transfer selected Mac item(s) to Android folder")
                .font(.caption)
                .disabled(vm.isBusy || vm.selectedLocalEntryIDs.isEmpty || vm.deviceSerial.isEmpty)

                Button {
                    do {
                        try vm.refreshLocalDirectory()
                        vm.status = "Loaded \(vm.localEntries.count) items from \(vm.localCurrentPath)."
                    } catch {
                        vm.status = "Failed to refresh local files: \(error.localizedDescription)"
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Mac pane")
                .font(.caption)
                .disabled(vm.isBusy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.localEntries) { entry in
                        HStack(spacing: 10) {
                            Button {
                                vm.toggleLocalSelection(id: entry.id)
                            } label: {
                                Image(systemName: vm.selectedLocalEntryIDs.contains(entry.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(vm.selectedLocalEntryIDs.contains(entry.id) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)

                            Image(systemName: entry.isDirectory ? "folder" : "doc")

                            Text(entry.name)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(localRowBackgroundColor(for: entry.id))
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            hoveredEntryID = isHovering ? entry.id : nil
                        }
                        .onTapGesture {
                            let isCommand = NSEvent.modifierFlags.contains(.command)
                            vm.handleLocalRowSelection(id: entry.id, commandPressed: isCommand)
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            guard entry.isDirectory else { return }
                            vm.handleLocalRowSelection(id: entry.id, commandPressed: false)
                            vm.openLocalDirectory(entry)
                        })
                    }
                }
            }
            .id("local-\(vm.localCurrentPath)-\(vm.localListRevision)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func localRowBackgroundColor(for id: String) -> Color {
        if vm.selectedLocalEntryIDs.contains(id) {
            return Color.accentColor.opacity(0.22)
        }
        if hoveredEntryID == id {
            return Color.accentColor.opacity(0.08)
        }
        return .clear
    }
}
