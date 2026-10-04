#if os(macOS)

  import SwiftUI

  struct ConversationPaneView: View {
    let model: AppleIntelligenceModel
    let promptIsFocused: FocusState<Bool>.Binding
    let onUseSuggestion: (String) -> Void
    let onCopy: (String) -> Void

    var body: some View {
      VStack(spacing: 0) {
        ConversationHeaderView(model: model)
        Divider()
        ConversationView(
          model: model,
          onUseSuggestion: onUseSuggestion,
          onCopy: onCopy
        )
        Divider()
        ComposerView(model: model, promptIsFocused: promptIsFocused)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
    }
  }

#endif
