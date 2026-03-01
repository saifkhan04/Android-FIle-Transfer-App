import SwiftUI

struct IndeterminateProgressBar: View {
    @State private var animate = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let segmentWidth = max(28, width * 0.28)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.06), Color.black.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.9), Color.cyan.opacity(0.9)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: segmentWidth)
                    .offset(x: animate ? width - segmentWidth : 0)
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: true), value: animate)
            }
        }
        .frame(height: 16)
        .onAppear {
            animate = true
        }
    }
}
