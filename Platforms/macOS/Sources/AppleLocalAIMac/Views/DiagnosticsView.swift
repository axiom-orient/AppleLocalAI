#if os(macOS)

  import SwiftUI

  struct DiagnosticsView: View {
    let model: AppleIntelligenceModel
    let showsDismissButton: Bool

    @Environment(\.dismiss) private var dismiss

    init(model: AppleIntelligenceModel, showsDismissButton: Bool = true) {
      self.model = model
      self.showsDismissButton = showsDismissButton
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Label("진단 정보", systemImage: "doc.text.magnifyingglass")
            .font(.system(size: 18, weight: .semibold))

          Spacer()

          if showsDismissButton {
            Button("완료") {
              dismiss()
            }
            .keyboardShortcut(.cancelAction)
          }
        }

        Divider()

        diagnosticRow("선택 이유", value: model.routingReason)
        diagnosticRow("최근 요청", value: model.lastRoutingLabel)
        diagnosticRow("런타임", value: model.runtimeRevisionLabel)
        diagnosticRow("Provider", value: model.providerBadgeTitle)
        diagnosticRow("모델", value: model.modelIdentityTitle)
        diagnosticRow("상태", value: model.availabilityLabel)
        diagnosticRow("실행 경로", value: model.contextLabel)
        diagnosticRow("Capability", value: model.foundationCapabilitiesLabel)
        diagnosticRow("응답 형식", value: model.foundationResponseModeLabel)
        diagnosticRow("도구", value: model.foundationToolNamesLabel)
        diagnosticRow("사용량", value: model.foundationUsageLabel)
        diagnosticRow("토큰 예상", value: model.foundationEstimatedTokenLabel)
        diagnosticRow("Transcript", value: model.foundationTranscriptLabel)

        if model.provider == .privateCloud {
          diagnosticRow("PCC 사용량", value: model.privateCloudQuotaLabel)
          Button("Private Cloud 상태 새로 고침", systemImage: "arrow.clockwise") {
            model.refreshPrivateCloudRuntime()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(minWidth: 560, minHeight: 560, alignment: .topLeading)
    }

    private func diagnosticRow(_ label: String, value: String) -> some View {
      HStack(alignment: .firstTextBaseline, spacing: 20) {
        Text(label)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 72, alignment: .leading)

        Text(value)
          .font(.system(size: 13))
          .textSelection(.enabled)
          .lineLimit(2)
      }
    }
  }

#endif
