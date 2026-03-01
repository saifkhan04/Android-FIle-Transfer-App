import SwiftUI
import AppKit

struct TransferQueueView: View {
    @ObservedObject var vm: AppViewModel
    @Binding var footerHeight: CGFloat
    @Binding var footerDragStartHeight: CGFloat?

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
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    if vm.hasTransferQueue {
                        Button("Clear Queue") {
                            vm.clearQueue()
                        }
                        .font(.caption)
                        .disabled(vm.isBusy)
                    }
                    if vm.isBusy {
                        Button("Cancel All") {
                            vm.cancelAllTransfers()
                        }
                        .font(.caption)
                    }
                }

                if vm.hasTransferQueue {
                    Text("Transfer Queue")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(vm.transferTasks) { task in
                                HStack(spacing: 8) {
                                    Image(systemName: task.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text(task.direction.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Text(task.name)
                                        .font(.caption)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(task.state.label)
                                        .font(.caption2)
                                        .foregroundStyle(stateColor(task.state))

                                    if task.state == .pending {
                                        Button("Cancel") {
                                            vm.cancelPendingTransfer(id: task.id)
                                        }
                                        .font(.caption2)
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
