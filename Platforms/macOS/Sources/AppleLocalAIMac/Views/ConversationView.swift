#if os(macOS)

  import AppleLocalAIHost
  import SwiftUI

  struct ConversationView: View {
    let model: AppleIntelligenceModel
    let onUseSuggestion: (String) -> Void
    let onCopy: (String) -> Void
    @State private var followsLatest = true

    private let bottomAnchorID = "conversation-bottom"

    var body: some View {
      let history = ConversationHistoryProjection.project(
        model.historyBeforeCurrentTurn,
        limit: model.foundationHistoryEntryLimit
      )

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            if history.omittedEntryCount > 0 {
              ConversationHistoryNotice(omittedEntryCount: history.omittedEntryCount)
            }

            ForEach(history.messages) { message in
              ConversationHistoryMessageView(message: message)
            }

            if let turn = model.submittedTurn {
              conversationContent(turn: turn)
            } else if let errorMessage = model.errorMessage {
              ConversationErrorView(message: errorMessage)
            } else if history.messages.isEmpty {
              EmptyConversationView(onUseSuggestion: onUseSuggestion)
            }

            Color.clear
              .frame(height: 1)
              .id(bottomAnchorID)
          }
          .frame(maxWidth: 860, alignment: .leading)
          .padding(.horizontal, InterfaceMetrics.contentHorizontalPadding)
          .padding(.vertical, 30)
          .frame(maxWidth: .infinity, alignment: .top)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.contentSize.height - geometry.visibleRect.maxY <= 48
        } action: { _, newValue in
          followsLatest = newValue
        }
        .onChange(of: model.isResponding) { _, isResponding in
          guard isResponding else { return }
          followsLatest = true
          proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
        .onChange(of: model.responseText) { _, _ in
          guard followsLatest else { return }
          proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
        .scrollIndicators(.automatic)
      }
    }

    @ViewBuilder
    private func conversationContent(turn: ConversationTurn) -> some View {
      VStack(alignment: .leading, spacing: 20) {
        UserMessageView(prompt: turn.prompt, image: turn.image)

        if model.isResponding {
          if model.responseText.isEmpty {
            AssistantProgressView(onStop: model.stopResponding)
          } else {
            AssistantStreamingView(
              answer: model.responseText,
              onStop: model.stopResponding
            )
          }
        } else if model.isCancelling {
          AssistantCancellationView()
        } else if !model.answer.isEmpty {
          AssistantMessageView(
            answer: model.answer,
            onCopy: onCopy,
            onRetry: model.retryLastResponse,
            onPositiveFeedback: { model.logFeedback(.positive) },
            onNegativeFeedback: { issue in model.logFeedback(.negative, issue: issue) },
            feedbackLabel: model.feedbackLabel
          )
        } else if let errorMessage = model.errorMessage {
          ConversationErrorView(message: errorMessage)
        } else if model.wasCancelled {
          ConversationCancelledView()
        }
      }
    }
  }

#endif
