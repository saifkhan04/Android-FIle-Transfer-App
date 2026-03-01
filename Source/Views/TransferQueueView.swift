import SwiftUI
import AppKit

struct TransferQueueView: View {
    @ObservedObject var vm: AppViewModel
    @Binding var footerHeight: CGFloat
    @Binding var footerDragStartHeight: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Divider()
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 12)
            }
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    NSCursor.resizeUpDown.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if footerDragStartHeight == nil {
                            footerDragStartHeight = footerHeight
                        }
                        let start = footerDragStartHeight ?? footerHeight
                        let resized = start - value.translation.height
                        footerHeight = min(max(resized, 90), 420)
                    }
                    .onEnded { _ in
                        footerDragStartHeight = nil
                    }
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(vm.status)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                    Spacer()
                    if vm.hasTransferQueue {
                        Button("Clear Queue") {
                            vm.clearQueue()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(Color.primary.opacity(colorScheme == .dark ? 0.5 : 0.25))
                        .disabled(vm.isBusy)
                    }
                    if vm.isBusy {
                        Button("Cancel All") {
                            vm.cancelAllTransfers()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.78, green: 0.33, blue: 0.25))
                    }
                }

                if vm.hasTransferQueue {
                    Text("Transfer Queue")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(vm.transferTasks) { task in
                                VStack(spacing: 6) {
                                    HStack(spacing: 8) {
                                        Image(systemName: task.direction == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.secondary)

                                        Text(task.direction.rawValue)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)

                                        Text(task.name)
                                            .font(.caption)
                                            .lineLimit(1)

                                        Spacer()

                                        Text(task.state.label)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(stateColor(task.state))

                                        if task.state == .pending {
                                            Button("Cancel") {
                                                vm.cancelPendingTransfer(id: task.id)
                                            }
                                            .font(.caption2.weight(.semibold))
                                            .buttonStyle(.bordered)
                                        }
                                    }

                                    if task.state == .inProgress {
                                        IndeterminateProgressBar()
                                            .frame(maxWidth: .infinity)
                                    } else if task.state == .completed {
                                        ProgressView(value: 100, total: 100)
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .padding(8)
                                .background(
                                    Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.42 : 0.82),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                                )
                            }
                        }
                    }
                    .frame(minHeight: 60, maxHeight: .infinity)
                }
            }
            .padding(12)
        }
        .frame(height: vm.hasTransferQueue ? footerHeight : 90)
    }

    private func stateColor(_ state: TransferTaskState) -> Color {
        switch state {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }
}
