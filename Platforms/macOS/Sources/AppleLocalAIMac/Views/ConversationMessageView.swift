#if os(macOS)

  import AppleLocalAIHost
  import SwiftUI

  struct EmptyConversationView: View {
    let onUseSuggestion: (String) -> Void

    var body: some View {
      VStack(spacing: 28) {
        Text("무엇을 도와드릴까요?")
          .font(.system(size: 32, weight: .semibold))
          .foregroundStyle(.primary)

        HStack(spacing: 12) {
          ForEach(ConversationSuggestion.allCases) { suggestion in
            ConversationSuggestionButton(suggestion: suggestion, action: onUseSuggestion)
          }
        }
      }
      .frame(maxWidth: .infinity, minHeight: 480)
      .padding(.horizontal, 28)
    }
  }

  private struct ConversationSuggestionButton: View {
    let suggestion: ConversationSuggestion
    let action: (String) -> Void

    var body: some View {
      Button {
        action(suggestion.prompt)
      } label: {
        Label(suggestion.title, systemImage: suggestion.systemImage)
          .font(.system(size: 14, weight: .medium))
          .frame(maxWidth: .infinity)
          .frame(height: 64)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.primary)
      .background(.clear, in: RoundedRectangle(cornerRadius: InterfaceMetrics.controlCornerRadius))
      .overlay {
        RoundedRectangle(cornerRadius: InterfaceMetrics.controlCornerRadius)
          .stroke(Color.primary.opacity(0.09), lineWidth: 1)
      }
      .accessibilityHint("입력창에 이 요청을 채웁니다")
    }
  }

  private enum ConversationSuggestion: CaseIterable, Identifiable {
    case organizeNotes
    case summarizeContent
    case planSteps

    var id: Self { self }

    var title: String {
      switch self {
      case .organizeNotes: "메모 정리"
      case .summarizeContent: "내용 요약"
      case .planSteps: "실행 계획"
      }
    }

    var systemImage: String {
      switch self {
      case .organizeNotes: "waveform.path.ecg"
      case .summarizeContent: "doc.text"
      case .planSteps: "checklist"
      }
    }

    var prompt: String {
      switch self {
      case .organizeNotes: "다음 메모를 핵심 항목, 결정 사항, 할 일로 정리해줘:\n"
      case .summarizeContent: "다음 내용을 세 문장으로 요약해줘:\n"
      case .planSteps: "다음 목표를 실행 단계와 우선순위로 정리해줘:\n"
      }
    }
  }

  struct UserMessageView: View {
    let prompt: String
    let image: ConversationImage?

    var body: some View {
      HStack {
        Spacer(minLength: 80)

        VStack(alignment: .trailing, spacing: 8) {
          if let image {
            Link(destination: image.url) {
              Label(image.fileName, systemImage: "photo")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
          }

          Text(prompt)
            .font(.system(size: 15))
            .textSelection(.enabled)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(
          Color.accentColor.opacity(0.16),
          in: RoundedRectangle(cornerRadius: InterfaceMetrics.messageCornerRadius)
        )
      }
    }
  }

  struct AssistantProgressView: View {
    let onStop: () -> Void

    var body: some View {
      HStack(alignment: .center, spacing: 14) {
        AssistantMark()

        ProgressView()
          .controlSize(.small)

        Text("생성 중…")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)

        Spacer()

        Button("중단", systemImage: "stop.fill", action: onStop)
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
    }
  }

  struct AssistantStreamingView: View {
    let answer: String
    let onStop: () -> Void

    var body: some View {
      HStack(alignment: .top, spacing: 14) {
        AssistantMark()

        VStack(alignment: .leading, spacing: 16) {
          Text(answer)
            .font(.system(size: 15))
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)

          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)

            Text("생성 중…")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(.secondary)

            Spacer()

            Button("중단", systemImage: "stop.fill", action: onStop)
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
    }
  }

  struct AssistantCancellationView: View {
    var body: some View {
      HStack(alignment: .center, spacing: 14) {
        AssistantMark()

        ProgressView()
          .controlSize(.small)

        Text("중단 중…")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)

        Spacer()
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
    }
  }

  struct AssistantMessageView: View {
    let answer: String
    let onCopy: (String) -> Void
    let onRetry: () -> Void
    let onPositiveFeedback: () -> Void
    let onNegativeFeedback: (FoundationModelsFeedbackIssueCategory?) -> Void
    let feedbackLabel: String?

    var body: some View {
      HStack(alignment: .top, spacing: 14) {
        AssistantMark()

        VStack(alignment: .leading, spacing: 18) {
          Text(answer)
            .font(.system(size: 15))
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)

          HStack(spacing: 18) {
            Button("복사", systemImage: "doc.on.doc") {
              onCopy(answer)
            }
            .buttonStyle(.plain)

            Button("다시 생성", systemImage: "arrow.clockwise") {
              onRetry()
            }
            .buttonStyle(.plain)

            Button("도움이 됨", systemImage: "hand.thumbsup") {
              onPositiveFeedback()
            }
            .buttonStyle(.plain)

            Button("개선 필요", systemImage: "hand.thumbsdown") {
              onNegativeFeedback(nil)
            }
            .buttonStyle(.plain)

            Menu {
              ForEach(FoundationModelsFeedbackIssueCategory.allCases, id: \.self) { category in
                Button(category.title) {
                  onNegativeFeedback(category)
                }
              }
            } label: {
              Label("개선 이유", systemImage: "exclamationmark.bubble")
            }
            .menuStyle(.borderlessButton)

            Spacer()
          }
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)

          if let feedbackLabel {
            Text(feedbackLabel)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
    }
  }

  struct ConversationErrorView: View {
    let message: String

    var body: some View {
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.system(size: 14))
        .foregroundStyle(.orange)
        .textSelection(.enabled)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
  }

  struct ConversationCancelledView: View {
    var body: some View {
      Label("응답을 중단했습니다.", systemImage: "stop.circle")
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
    }
  }

  struct ConversationHistoryMessageView: View {
    let message: ConversationHistoryProjection.Message

    var body: some View {
      switch message.content {
      case .user(let prompt, let attachments):
        userMessage(prompt: prompt, attachments: attachments)
      case .assistant(let answer):
        assistantMessage(answer: answer)
      case .tool(let title, let detail):
        toolMessage(title: title, detail: detail)
      }
    }

    private func userMessage(
      prompt: String,
      attachments: [ConversationHistoryProjection.Attachment]
    ) -> some View {
      HStack {
        Spacer(minLength: 80)

        VStack(alignment: .trailing, spacing: 8) {
          ForEach(attachments) { attachment in
            Label(attachment.title, systemImage: "photo")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          if !prompt.isEmpty {
            Text(prompt)
              .font(.system(size: 15))
              .textSelection(.enabled)
          }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(
          Color.accentColor.opacity(0.16),
          in: RoundedRectangle(cornerRadius: InterfaceMetrics.messageCornerRadius)
        )
      }
    }

    private func assistantMessage(answer: String) -> some View {
      HStack(alignment: .top, spacing: 14) {
        AssistantMark()

        Text(answer)
          .font(.system(size: 15))
          .lineSpacing(4)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(20)
          .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
      }
    }

    private func toolMessage(title: String, detail: String) -> some View {
      Label {
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 12, weight: .semibold))
          Text(detail)
            .font(.system(size: 12))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      } icon: {
        Image(systemName: "wrench.and.screwdriver")
          .accessibilityHidden(true)
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }
  }

  struct ConversationHistoryNotice: View {
    let omittedEntryCount: Int

    var body: some View {
      Label(
        "이전 기록 \(omittedEntryCount)개는 화면에서 생략했습니다. 원본은 현재 세션에 유지됩니다.",
        systemImage: "ellipsis"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .accessibilityElement(children: .combine)
    }
  }

  private struct AssistantMark: View {
    var body: some View {
      Image(systemName: "sparkles")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.tint)
        .frame(width: 38, height: 38)
        .background(Color.accentColor.opacity(0.12), in: Circle())
        .accessibilityHidden(true)
    }
  }

#endif
