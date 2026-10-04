#if os(macOS)

  import AppKit
  import SwiftUI

  final class AppleLocalAIMacDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
      // The main window is the macOS workspace. The menu-bar extra remains a
      // fast secondary entry point for opening it and changing the workload.
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  @main
  struct AppleLocalAIMac: App {
    @NSApplicationDelegateAdaptor(AppleLocalAIMacDelegate.self) private var appDelegate
    @State private var model = AppleIntelligenceModel()

    var body: some Scene {
      MenuBarExtra(AppIdentity.displayName, systemImage: "brain") {
        MenuBarView()
          .environment(model)
      }
      .menuBarExtraStyle(.window)

      Window(AppIdentity.displayName, id: "main") {
        ContentView()
          .environment(model)
      }
      .defaultLaunchBehavior(.presented)
      .defaultSize(
        width: InterfaceMetrics.defaultWindowWidth,
        height: InterfaceMetrics.defaultWindowHeight
      )

      Settings {
        SettingsView()
          .environment(model)
      }
      .defaultSize(width: 740, height: 760)
    }
  }

#else
  #error("This executable requires macOS 27 or later.")
#endif
