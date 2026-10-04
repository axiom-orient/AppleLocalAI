#if os(macOS)

  import SwiftUI

  @MainActor
  struct ContentView: View {
    @Environment(AppleIntelligenceModel.self) private var model
    @FocusState private var promptIsFocused: Bool

    let clipboard: any ClipboardClient

    init(clipboard: any ClipboardClient = SystemClipboardClient()) {
      self.clipboard = clipboard
    }

    var body: some View {
      NavigationSplitView {
        MacSidebarView(
          model: model,
          onNewConversation: startNewConversation
        )
        .navigationSplitViewColumnWidth(
          min: InterfaceMetrics.sidebarMinimumWidth,
          ideal: InterfaceMetrics.sidebarWidth,
          max: InterfaceMetrics.sidebarMaximumWidth
        )
      } detail: {
        ConversationPaneView(
          model: model,
          promptIsFocused: $promptIsFocused,
          onUseSuggestion: useSuggestion,
          onCopy: copy
        )
      }
      .navigationSplitViewStyle(.balanced)
      .frame(
        minWidth: InterfaceMetrics.minimumWindowWidth,
        minHeight: InterfaceMetrics.minimumWindowHeight
      )
      .onAppear {
        promptIsFocused = true
      }
    }

    private func startNewConversation() {
      model.newConversation()
      promptIsFocused = true
    }

    private func useSuggestion(_ suggestion: String) {
      model.prompt = suggestion
      promptIsFocused = true
    }

    private func copy(_ value: String) {
      _ = clipboard.copy(value)
    }
  }

#endif
