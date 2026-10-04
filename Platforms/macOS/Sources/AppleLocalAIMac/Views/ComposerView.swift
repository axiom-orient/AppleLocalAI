#if os(macOS)

  import AppKit
  import AppleLocalAIHost
  import SwiftUI
  import UniformTypeIdentifiers

  struct ComposerView: View {
    @Bindable var model: AppleIntelligenceModel
    let promptIsFocused: FocusState<Bool>.Binding

    @State private var isImageImporterPresented = false
    @State private var extractedText: String?
    @State private var extractionError: String?
    @State private var extractionRevision = 0
    @State private var extractionTask: Task<Void, Never>?

    private var isExtractingText: Bool {
      extractionTask != nil
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        if let pendingImage = model.pendingImage {
          pendingImageView(image: pendingImage)
        }

        HStack(alignment: .bottom, spacing: 10) {
          Button {
            isImageImporterPresented = true
          } label: {
            Image(systemName: "photo.on.rectangle.angled")
              .font(.system(size: 17, weight: .medium))
              .frame(width: 28, height: 44)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .disabled(!model.canAttachImage)
          .help(model.imageInputLabel)
          .accessibilityLabel("이미지 추가")

          Divider()
            .frame(height: 32)

          TextEditor(text: $model.prompt)
            .font(.system(size: 15))
            .scrollContentBackground(.hidden)
            .padding(.vertical, 7)
            .frame(minHeight: 48, maxHeight: 120)
            .focused(promptIsFocused)
            .onSubmit {
              guard model.canSend else { return }
              model.respond()
            }
            .disabled(model.isBusy)

          if !model.isBusy {
            Text("⌘↩")
              .font(.system(size: 12, weight: .medium, design: .rounded))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 9)
              .padding(.vertical, 6)
              .background(.quaternary.opacity(0.55), in: Capsule())
              .accessibilityLabel("Command Return")
          }

          Button {
            if model.isResponding {
              model.stopResponding()
            } else if !model.isCancelling {
              model.respond()
            }
          } label: {
            Image(systemName: model.isBusy ? "hourglass" : "paperplane.fill")
              .font(.system(size: 16, weight: .semibold))
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.white)
          .background(
            Color.accentColor,
            in: RoundedRectangle(cornerRadius: InterfaceMetrics.controlCornerRadius)
          )
          .keyboardShortcut(.return, modifiers: [.command])
          .disabled(!model.canSend && !model.isResponding)
          .help(model.isResponding ? "응답 중단" : model.isCancelling ? "중단 중" : "보내기")
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.background.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
      .overlay {
        RoundedRectangle(cornerRadius: 16)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }
      .padding(.horizontal, InterfaceMetrics.contentHorizontalPadding)
      .padding(.vertical, 18)
      .onChange(of: model.prompt) { _, _ in
        model.schedulePrewarm()
      }
      .onChange(of: model.pendingImage?.url) { _, _ in
        extractionRevision &+= 1
        extractionTask?.cancel()
        extractionTask = nil
        extractedText = nil
        extractionError = nil
      }
      .onDisappear {
        extractionRevision &+= 1
        extractionTask?.cancel()
        extractionTask = nil
      }
      .fileImporter(
        isPresented: $isImageImporterPresented,
        allowedContentTypes: [.image],
        allowsMultipleSelection: false
      ) { result in
        guard case .success(let urls) = result, let url = urls.first else { return }
        model.selectImage(url)
      }
    }

    private func pendingImageView(image: ConversationImage) -> some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .center, spacing: 12) {
          ImageThumbnailView(url: image.url)

          VStack(alignment: .leading, spacing: 4) {
            Text("이미지 첨부")
              .font(.system(size: 12, weight: .semibold))

            Text(image.fileName)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.secondary)
              .lineLimit(1)

            if isExtractingText {
              Label("텍스트를 찾는 중…", systemImage: "hourglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            } else if extractedText != nil {
              Label("텍스트를 추출했습니다", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
            }
          }

          Spacer(minLength: 8)

          Button {
            extractText(from: image)
          } label: {
            Label(
              isExtractingText ? "추출 중…" : "텍스트 추출",
              systemImage: isExtractingText ? "hourglass" : "doc.text.magnifyingglass"
            )
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(isExtractingText)
          .accessibilityIdentifier("composer.extract-text")
          .help("VisionKit으로 이미지에서 텍스트를 추출합니다")

          Button {
            model.removePendingImage()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 15))
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("이미지 제거")
          .help("첨부 이미지 제거")
        }

        if let extractedText {
          extractedTextView(extractedText)
        }

        if let extractionError {
          Label(extractionError, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }
      }
      .padding(10)
      .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(Color.primary.opacity(0.1), lineWidth: 1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func extractedTextView(_ text: String) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Label("추출된 텍스트", systemImage: "text.alignleft")
            .font(.system(size: 12, weight: .semibold))

          Spacer(minLength: 8)

          Button("질문에 추가") {
            let separator =
              model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              ? ""
              : "\n\n"
            model.prompt += separator + text
          }
          .buttonStyle(.link)
          .font(.system(size: 12, weight: .medium))
          .accessibilityHint("추출한 텍스트를 현재 질문 입력창에 추가합니다")
        }

        Text(text)
          .font(.system(size: 13))
          .lineSpacing(2)
          .textSelection(.enabled)
          .lineLimit(8)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(10)
      .background(.background.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
    }

    private func extractText(from image: ConversationImage) {
      guard extractionTask == nil else { return }
      extractionRevision &+= 1
      let revision = extractionRevision
      extractionError = nil
      extractedText = nil
      let imageURL = image.url

      extractionTask = Task { @MainActor in
        defer {
          if extractionRevision == revision {
            extractionTask = nil
          }
        }

        do {
          let text = try await VisionKitTextExtractor().extractText(from: imageURL)
          guard !Task.isCancelled, extractionRevision == revision,
            model.pendingImage?.url == imageURL
          else { return }
          extractedText = text
        } catch is CancellationError {
          return
        } catch {
          guard !Task.isCancelled, extractionRevision == revision,
            model.pendingImage?.url == imageURL
          else { return }
          extractionError = error.localizedDescription
        }
      }
    }
  }

  private struct ImageThumbnailView: View {
    let url: URL

    @State private var image: NSImage?

    var body: some View {
      Group {
        if let image {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: "photo")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(width: 96, height: 72)
      .background(.background.opacity(0.6))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }
      .accessibilityElement()
      .accessibilityLabel("첨부 이미지 미리보기")
      .task(id: url) {
        image = SecurityScopedResource.withAccess(
          to: url,
          using: SystemSecurityScopedResourceAccess()
        ) {
          NSImage(contentsOf: url)
        }
      }
    }
  }

#endif
