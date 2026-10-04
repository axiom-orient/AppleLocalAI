#if os(macOS)

  import AppleLocalAIHost
  import SwiftUI

  enum ProviderReadinessPresentation {
    static func color(for readiness: LocalAIProviderReadiness) -> Color {
      switch readiness {
      case .checking:
        return .secondary
      case .ready:
        return .green
      case .configured:
        return .blue
      case .unavailable:
        return .orange
      case .quotaExceeded:
        return .orange
      case .unsupportedLocale:
        return .orange
      case .invalidConfiguration:
        return .red
      }
    }

    static func systemImage(for readiness: LocalAIProviderReadiness) -> String {
      switch readiness {
      case .checking:
        return "hourglass"
      case .ready:
        return "checkmark.circle"
      case .configured:
        return "circle.dotted"
      case .unavailable:
        return "exclamationmark.triangle"
      case .quotaExceeded:
        return "exclamationmark.octagon"
      case .unsupportedLocale:
        return "globe.badge.chevron.backward"
      case .invalidConfiguration:
        return "xmark.circle"
      }
    }
  }

  struct ProviderStatusLabel: View {
    let model: AppleIntelligenceModel

    var body: some View {
      HStack(spacing: 8) {
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)

        Text(model.availabilityLabel)
          .foregroundStyle(.secondary)
      }
    }

    private var statusColor: Color {
      ProviderReadinessPresentation.color(for: model.readiness)
    }
  }

#endif
