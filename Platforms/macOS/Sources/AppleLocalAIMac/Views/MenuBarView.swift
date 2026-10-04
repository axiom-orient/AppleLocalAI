#if os(macOS)

  import AppKit
  import SwiftUI

  struct MenuBarView: View {
    @Environment(AppleIntelligenceModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        header

        Divider()
          .padding(.vertical, 18)

        ForEach(model.providerSnapshots) { snapshot in
          MenuBarActionRow(
            title: snapshot.provider.title,
            subtitle: snapshot.status,
            systemImage: snapshot.provider.systemImage,
            action: { selectProvider(snapshot) },
            isProminent: model.provider == snapshot.provider,
            isDestructive: false,
            showsChevron: true
          )
          .padding(.bottom, 6)
        }

        Divider()
          .padding(.vertical, 12)

        MenuBarActionRow(
          title: "설정",
          subtitle: "모델·백엔드 설정",
          systemImage: "gearshape",
          action: { openSettings() },
          isProminent: false,
          isDestructive: false,
          showsChevron: true
        )
        .padding(.bottom, 4)

        Divider()
          .padding(.bottom, 4)

        MenuBarActionRow(
          title: "종료",
          subtitle: nil,
          systemImage: "power",
          action: { terminate() },
          isProminent: false,
          isDestructive: true,
          showsChevron: false
        )
      }
      .padding(20)
      .frame(width: InterfaceMetrics.menuBarPopoverWidth)
    }

    private var header: some View {
      HStack(spacing: 12) {
        Image(systemName: "brain")
          .font(.system(size: 30, weight: .medium))
          .foregroundStyle(.tint)
          .frame(width: 36, height: 36)

        Text(AppIdentity.displayName)
          .font(.system(size: 20, weight: .semibold))

        Spacer(minLength: 0)
      }
    }

    private func showMainWindow() {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }

    private func selectProvider(_ snapshot: ProviderSnapshot) {
      model.selectProvider(snapshot.provider)
      if snapshot.readiness.canSend {
        showMainWindow()
      } else {
        openSettings()
      }
    }

    private func terminate() {
      NSApplication.shared.terminate(nil)
    }
  }

#endif
