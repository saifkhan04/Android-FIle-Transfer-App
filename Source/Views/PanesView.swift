import SwiftUI
import AppKit

struct RemotePaneView: View {
    @ObservedObject var vm: AppViewModel
    @Binding var hoveredEntryID: String?
    let onRequestDelete: () -> Void
    @Environment(\.colorScheme) private var colorScheme

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
                .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
                .padding(8)
                .background(controlChipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(vm.isBusy || !vm.canRemoteBack)

                Button {
                    Task { await vm.remoteForward() }
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .help("Forward")
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
                .padding(8)
                .background(controlChipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(vm.isBusy || !vm.canRemoteForward)

                Button {
                    onRequestDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected remote item(s)")
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
                .padding(8)
                .background(controlChipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(vm.isBusy || vm.selectedRemoteEntryIDs.isEmpty || vm.deviceSerial.isEmpty)

                Button {
                    Task { await vm.downloadSelectedRemoteToLocal() }
                } label: {
                    Image(systemName: "arrow.down.to.line.compact")
                }
                .help("Transfer selected Android item(s) to Mac folder")
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
                .padding(8)
                .background(Color.accentColor.opacity(colorScheme == .dark ? 0.32 : 0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(vm.isBusy || vm.selectedRemoteEntryIDs.isEmpty || vm.deviceSerial.isEmpty)

                Button {
                    Task { await vm.refreshRemoteDirectory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Android pane")
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
                .padding(8)
                .background(controlChipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(vm.isBusy || vm.deviceSerial.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(headerBackground)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(vm.remoteEntries) { entry in
                        HStack(spacing: 10) {
                            Button {
                                vm.toggleRemoteSelection(id: entry.id)
                            } label: {
                                Image(systemName: vm.selectedRemoteEntryIDs.contains(entry.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(vm.selectedRemoteEntryIDs.contains(entry.id) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 14, weight: .medium))

                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .font(.system(size: 15, weight: .medium))

                            Text(entry.name)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(rowFillColor(for: entry.id), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                .padding(8)
            }
            .id("remote-\(vm.remoteCurrentPath)-\(vm.remoteListRevision)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func rowFillColor(for id: String) -> Color {
        if vm.selectedRemoteEntryIDs.contains(id) {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.33 : 0.24)
        }
        if hoveredEntryID == id {
            return Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07)
        }
        return Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.42 : 0.78)
    }

    private var controlChipBackground: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08)
    }

    private var headerBackground: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05)
    }
}

struct LocalPaneView: View {
    @ObservedObject var vm: AppViewModel
    @Binding var hoveredEntryID: String?
    let onRequestDelete: () -> Void
    @Environment(\.colorScheme) private var colorScheme

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
                .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
                .padding(8)
                .background(controlChipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(vm.isBusy || !vm.canLocalBack)

                Button {
                    vm.localForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .help("Forward")
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
                .padding(8)
                .background(controlChipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(vm.isBusy || !vm.canLocalForward)

                Button {
                    onRequestDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected local item(s)")
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
                .padding(8)
                .background(controlChipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(vm.isBusy || vm.selectedLocalEntryIDs.isEmpty)

                Button {
                    Task { await vm.uploadSelectedLocalToRemote() }
                } label: {
                    Image(systemName: "arrow.up.to.line.compact")
                }
                .help("Transfer selected Mac item(s) to Android folder")
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
                .padding(8)
                .background(Color.accentColor.opacity(colorScheme == .dark ? 0.32 : 0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
                .padding(8)
                .background(controlChipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(vm.isBusy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(headerBackground)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(vm.localEntries) { entry in
                        HStack(spacing: 10) {
                            Button {
                                vm.toggleLocalSelection(id: entry.id)
                            } label: {
                                Image(systemName: vm.selectedLocalEntryIDs.contains(entry.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(vm.selectedLocalEntryIDs.contains(entry.id) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 14, weight: .medium))

                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .font(.system(size: 15, weight: .medium))

                            Text(entry.name)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(rowFillColor(for: entry.id), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                .padding(8)
            }
            .id("local-\(vm.localCurrentPath)-\(vm.localListRevision)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func rowFillColor(for id: String) -> Color {
        if vm.selectedLocalEntryIDs.contains(id) {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.33 : 0.24)
        }
        if hoveredEntryID == id {
            return Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07)
        }
        return Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.42 : 0.78)
    }

    private var controlChipBackground: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08)
    }

    private var headerBackground: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05)
    }
}
