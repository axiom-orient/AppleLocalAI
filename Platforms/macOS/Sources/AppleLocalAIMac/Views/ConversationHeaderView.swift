#if os(macOS)

  import SwiftUI
  import AppleLocalAIHost

  struct ConversationHeaderView: View {
    let model: AppleIntelligenceModel

    @State private var showingDiagnostics = false

    var body: some View {
      HStack(spacing: 12) {
        Text(model.conversationTitle)
          .font(.system(size: 20, weight: .semibold))
          .lineLimit(1)

        Spacer()

        providerBadge

        Menu {
          Label(
            "연결 상태 · \(model.availabilityLabel)",
            systemImage: ProviderReadinessPresentation.systemImage(for: model.readiness)
          )

          Button("진단 정보", systemImage: "doc.text.magnifyingglass") {
            showingDiagnostics = true
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 44, height: 40)
            .contentShape(RoundedRectangle(cornerRadius: InterfaceMetrics.controlCornerRadius))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .background(
          .quaternary.opacity(0.42),
          in: RoundedRectangle(cornerRadius: InterfaceMetrics.controlCornerRadius)
        )
        .accessibilityLabel("추가 메뉴")
      }
      .padding(.horizontal, InterfaceMetrics.contentHorizontalPadding)
      .padding(.vertical, 22)
      .sheet(isPresented: $showingDiagnostics) {
        DiagnosticsView(model: model)
      }
    }

    private var providerBadge: some View {
      HStack(spacing: 9) {
        Text(model.providerBadgeTitle)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)

        Circle()
          .fill(statusColor)
          .frame(width: 9, height: 9)

        Text(model.availabilityLabel)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(.horizontal, 15)
      .frame(height: 40)
      .background(.quaternary.opacity(0.52), in: Capsule())
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Provider \(model.providerBadgeTitle), 상태 \(model.availabilityLabel)")
    }

    private var statusColor: Color {
      ProviderReadinessPresentation.color(for: model.readiness)
    }
  }

#endif
