#if os(macOS)

  import AppleLocalAIHost
  import SwiftUI

  struct MacSidebarView: View {
    let model: AppleIntelligenceModel
    let onNewConversation: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
      List {
        conversationSection
        providerSection
      }
      .listStyle(.sidebar)
      .safeAreaInset(edge: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
          brandHeader
          Button(action: onNewConversation) {
            Label("새 대화", systemImage: "square.and.pencil")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .padding(.horizontal, InterfaceMetrics.sidebarHorizontalPadding)
        .padding(.top, 16)
        .padding(.bottom, 10)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
          Divider()
          SettingsSidebarButton()
            .padding(.horizontal, InterfaceMetrics.sidebarHorizontalPadding)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
      }
    }

    private var brandHeader: some View {
      HStack(spacing: 10) {
        Image(systemName: "brain")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.tint)
          .frame(width: 30, height: 30)
          .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))

        VStack(alignment: .leading, spacing: 2) {
          Text(AppIdentity.displayName)
            .font(.headline)
        }

        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var conversationSection: some View {
      if model.hasConversation {
        Section("대화") {
          Label(model.conversationTitle, systemImage: "bubble.left.fill")
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
      }
    }

    private var providerSection: some View {
      Section("모델") {
        ForEach(model.providerSnapshots) { snapshot in
          SidebarProviderButton(
            choice: snapshot.provider,
            snapshot: snapshot,
            isSelected: model.provider == snapshot.provider
          ) {
            model.selectProvider(snapshot.provider)
            if !snapshot.readiness.canSend { openSettings() }
          }
        }
      }
    }
  }

  private struct SidebarProviderButton: View {
    let choice: LocalProviderChoice
    let snapshot: ProviderSnapshot
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
      Button(action: action) {
        HStack(spacing: 10) {
          Image(systemName: choice.systemImage)
            .frame(width: 18)

          VStack(alignment: .leading, spacing: 2) {
            Text(choice.title)
            Text(snapshot.status)
              .font(.caption)
              .foregroundStyle(ProviderReadinessPresentation.color(for: snapshot.readiness))
              .lineLimit(1)
          }

          Spacer(minLength: 0)

          if isSelected {
            Image(systemName: "checkmark")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.tint)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(
            isSelected
              ? Color.accentColor.opacity(0.14)
              : isHovered ? Color.primary.opacity(0.08) : Color.clear
          )
      )
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .animation(.easeOut(duration: 0.12), value: isSelected)
      .accessibilityLabel("\(choice.title), \(snapshot.status)")
      .accessibilityHint("선택하면 이 Provider를 기본으로 사용합니다.")
    }
  }

  private struct SettingsSidebarButton: View {
    @State private var isHovered = false

    var body: some View {
      SettingsLink {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text("설정")
            Text("모델·백엔드 설정")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        } icon: {
          Image(systemName: "gearshape")
            .frame(width: 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
      )
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .accessibilityHint("모델과 백엔드 설정을 엽니다.")
    }
  }

#endif
