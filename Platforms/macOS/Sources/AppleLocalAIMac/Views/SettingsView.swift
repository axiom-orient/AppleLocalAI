#if os(macOS)

  import AppleLocalAIFoundationModels
  import AppleLocalAIHost
  import AppleLocalAILiteRT
  import SwiftUI
  import UniformTypeIdentifiers

  struct SettingsView: View {
    @Environment(AppleIntelligenceModel.self) private var model

    var body: some View {
      @Bindable var model = model

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          settingsHeader(model: model)

          if let message = model.settingsPersistenceErrorMessage {
            SettingsFeedback(message: message, systemImage: "exclamationmark.triangle")
          }
          providerSettings(model: model)
        }
        .padding(28)
        .frame(maxWidth: 720, alignment: .topLeading)
      }
      .scrollIndicators(.hidden)
      .navigationTitle("설정")
    }

    private func settingsHeader(model: AppleIntelligenceModel) -> some View {
      HStack(spacing: 12) {
        Image(systemName: model.provider.systemImage)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.tint)
          .frame(width: 36, height: 36)
          .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

        VStack(alignment: .leading, spacing: 2) {
          Text(model.provider.title)
            .font(.headline)
          Text(model.provider.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 12)
      }
      .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func providerSettings(model: AppleIntelligenceModel) -> some View {
      RoutingSettingsCard(model: model)

      switch model.provider {
      case .apple:
        AppleProviderSettingsCard(model: model)
      case .privateCloud:
        PrivateCloudProviderSettingsCard(model: model)
      case .coreAI:
        CoreAISettingsCard(model: model)
      case .mlx:
        MLXProviderSettingsCard(model: model)
      case .liteRT:
        LiteRTProviderSettingsCard(model: model)
      case .remote:
        RemoteProviderSettingsCard(model: model)
      }

      DisclosureGroup {
        FoundationModelsControlsCard(model: model)
          .padding(.top, 8)
      } label: {
        Label("고급 응답 설정", systemImage: "slider.horizontal.3")
          .font(.headline)
      }
      .padding(.top, 4)
    }
  }

  private struct RoutingSettingsCard: View {
    @Bindable var model: AppleIntelligenceModel

    var body: some View {
      SettingsCard {
        VStack(alignment: .leading, spacing: 14) {
          SettingsCardHeader(title: "모델 선택", systemImage: "square.stack.3d.up")

          Picker("작업 프로필", selection: $model.workload) {
            ForEach(ModelWorkload.allCases, id: \.self) { workload in
              Text(workload.title).tag(workload)
            }
          }

          if model.workload == .manual {
            Picker(
              "Provider",
              selection: Binding(
                get: { model.provider },
                set: { model.selectProvider($0) }
              )
            ) {
              ForEach(LocalProviderChoice.allCases) { provider in
                Label(provider.title, systemImage: provider.systemImage).tag(provider)
              }
            }
          }

          Toggle(
            "Private Cloud Compute 사용 허용",
            isOn: $model.allowPrivateCloud
          )

          Text("PCC는 자동 fallback이 아니며, 허용하더라도 routing policy 또는 직접 선택으로만 사용합니다.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

          SettingsStatusRow(
            title: "현재 상태",
            value: model.availabilityLabel,
            color: ProviderReadinessPresentation.color(for: model.readiness)
          )

          Text(model.routingReason)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private struct CoreAISettingsCard: View {
    @Bindable var model: AppleIntelligenceModel

    var body: some View {
      SettingsCard {
        VStack(alignment: .leading, spacing: 12) {
          SettingsCardHeader(title: "Core AI 모델", systemImage: "shippingbox")
          TextField("내보낸 Core AI 리소스 폴더 경로", text: $model.coreAIModelPath)
          Button("Core AI 모델 로드") { model.loadCoreAIModel() }
            .disabled(model.isBusy || model.coreAILoading || model.coreAIModelPath.isEmpty)
          Text(model.coreAIStatus).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private struct AppleProviderSettingsCard: View {
    let model: AppleIntelligenceModel

    var body: some View {
      SettingsCard {
        VStack(alignment: .leading, spacing: 14) {
          SettingsCardHeader(title: "Apple Intelligence", systemImage: "apple.logo")

          SettingsStatusRow(
            title: "상태",
            value: model.providerSnapshot(for: .apple).status,
            color: ProviderReadinessPresentation.color(
              for: model.providerSnapshot(for: .apple).readiness)
          )

          Divider()

          SettingsValueRow(title: "모델", value: model.providerSnapshot(for: .apple).model)
          SettingsValueRow(title: "접근", value: "SystemLanguageModel")
          SettingsValueRow(title: "실행", value: "Apple Intelligence")
          SettingsValueRow(
            title: "Capability", value: model.providerSnapshot(for: .apple).capabilities)
          SettingsValueRow(title: "이미지", value: model.providerSnapshot(for: .apple).imageInput)
        }
      }
    }
  }

  private struct PrivateCloudProviderSettingsCard: View {
    @Bindable var model: AppleIntelligenceModel

    var body: some View {
      SettingsCard {
        VStack(alignment: .leading, spacing: 14) {
          SettingsCardHeader(title: "Private Cloud Compute", systemImage: "cloud")

          SettingsStatusRow(
            title: "상태",
            value: model.availabilityLabel,
            color: ProviderReadinessPresentation.color(for: model.readiness)
          )

          Divider()

          SettingsValueRow(title: "모델", value: model.modelIdentityTitle)
          SettingsValueRow(title: "Capability", value: model.foundationCapabilitiesLabel)
          SettingsValueRow(title: "컨텍스트", value: model.contextLabel)
          SettingsValueRow(title: "이미지", value: model.imageInputLabel)
          SettingsValueRow(title: "사용량", value: model.privateCloudQuotaLabel)

          HStack(spacing: 10) {
            Button("상태 새로 고침", systemImage: "arrow.clockwise") {
              model.refreshPrivateCloudRuntime()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if model.hasPrivateCloudQuotaSuggestion {
              Button("사용량 제안 보기", systemImage: "info.circle") {
                model.showPrivateCloudQuotaSuggestion()
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
          }

          if let message = model.privateCloudRuntimeErrorMessage {
            SettingsFeedback(message: message, systemImage: "exclamationmark.triangle")
          }

          Text("PCC는 명시적으로 허용·선택된 경우에만 사용합니다. Apple 시스템 모델로 자동 전환하지 않습니다.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private struct RemoteProviderSettingsCard: View {
    @Bindable var model: AppleIntelligenceModel

    var body: some View {
      SettingsCard {
        VStack(alignment: .leading, spacing: 14) {
          SettingsCardHeader(title: "Remote LanguageModel", systemImage: "network")

          SettingsStatusRow(
            title: "상태",
            value: model.availabilityLabel,
            color: ProviderReadinessPresentation.color(for: model.readiness)
          )

          Divider()

          SettingsTextField(title: "Base URL", text: $model.remoteBaseURL)
          SettingsTextField(title: "모델", text: $model.remoteModelName)

          VStack(alignment: .leading, spacing: 6) {
            Text("API Key")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.secondary)
            SecureField("선택 사항", text: $model.remoteAPIKey)
              .textFieldStyle(.roundedBorder)
          }

          if let error = model.remoteCredentialErrorMessage {
            Text(error)
              .font(.system(size: 11))
              .foregroundStyle(.red)
          }

          Text(
            "HTTPS endpoint 또는 loopback HTTP만 허용합니다. API key는 Keychain에 저장합니다. 실제 모델 capability만 명시적으로 켜세요."
          )
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          Divider()

          SettingsSectionLabel(title: "Capability")
          Toggle("Vision", isOn: $model.remoteVision)
          Toggle("Guided generation", isOn: $model.remoteGuidedGeneration)
          Toggle("Tool calling", isOn: $model.remoteToolCalling)
          Toggle("Reasoning", isOn: $model.remoteReasoning)
        }
      }
    }
  }

  private struct FoundationModelsControlsCard: View {
    @Bindable var model: AppleIntelligenceModel

    var body: some View {
      SettingsCard {
        VStack(alignment: .leading, spacing: 14) {
          SettingsCardHeader(title: "Foundation Models", systemImage: "sparkles")

          Picker("Use case", selection: $model.foundationModelUseCase) {
            ForEach(FoundationModelUseCase.allCases, id: \.self) { value in
              Text(value.title).tag(value)
            }
          }

          Picker("Guardrails", selection: $model.foundationModelGuardrails) {
            ForEach(FoundationModelGuardrails.allCases, id: \.self) { value in
              Text(value.title).tag(value)
            }
          }

          Picker("응답 형식", selection: $model.foundationResponseMode) {
            ForEach(FoundationModelResponseMode.allCases, id: \.self) { value in
              Text(value.title).tag(value)
            }
          }

          Picker("Reasoning", selection: $model.foundationReasoningLevel) {
            ForEach(FoundationModelReasoningLevel.allCases, id: \.self) { value in
              Text(value.title).tag(value)
            }
          }

          if model.foundationReasoningLevel == .custom {
            SettingsTextField(
              title: "Custom reasoning level",
              text: $model.foundationCustomReasoningLevel
            )
          }

          Picker("Tool calling", selection: $model.foundationToolCallingMode) {
            ForEach(FoundationModelToolCallingMode.allCases, id: \.self) { value in
              Text(value.title).tag(value)
            }
          }

          Picker("Sampling", selection: $model.foundationSamplingMode) {
            ForEach(FoundationModelSamplingMode.allCases, id: \.self) { value in
              Text(value.title).tag(value)
            }
          }

          if model.foundationSamplingMode == .randomTopK {
            Stepper(
              "Top K: \(model.foundationRandomTopK)",
              value: $model.foundationRandomTopK,
              in: FoundationModelsSettings
                .minimumRandomTopK...FoundationModelsSettings.maximumRandomTopK
            )
          }

          if model.foundationSamplingMode == .randomProbabilityThreshold {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text("확률 임계값")
                Spacer()
                Text(
                  model.foundationProbabilityThreshold.formatted(
                    .number.precision(.fractionLength(2)))
                )
                .foregroundStyle(.secondary)
              }
              Slider(
                value: $model.foundationProbabilityThreshold,
                in: FoundationModelsSettings
                  .minimumProbabilityThreshold...FoundationModelsSettings
                  .maximumProbabilityThreshold
              )
            }
          }

          SettingsTextField(title: "Temperature", text: $model.foundationTemperatureText)
          SettingsTextField(title: "Max tokens", text: $model.foundationMaximumResponseTokensText)
          SettingsTextField(title: "Random seed", text: $model.foundationRandomSeedText)

          Stepper(
            "History entries: \(model.foundationHistoryEntryLimit)",
            value: $model.foundationHistoryEntryLimit,
            in: FoundationModelsSettings
              .minimumHistoryEntryLimit...FoundationModelsSettings.maximumHistoryEntryLimit
          )

          Toggle("스키마를 prompt에 포함", isOn: $model.foundationIncludeSchemaInPrompt)

          SettingsValueRow(title: "실패·중지한 대화", value: "부분 기록 보존")

          Divider()

          SettingsSectionLabel(title: "현재 native readiness")
          SettingsValueRow(title: "지원 기능", value: model.foundationCapabilitiesLabel)
          SettingsValueRow(title: "응답 형식", value: model.foundationResponseModeLabel)
          SettingsValueRow(title: "활성 도구", value: model.foundationToolNamesLabel)

          Toggle(
            "OCRTool",
            isOn: $model.foundationEnableOCRTool
          )
          .disabled(!model.supportsImageInput)

          Toggle(
            "BarcodeReaderTool",
            isOn: $model.foundationEnableBarcodeReaderTool
          )
          .disabled(!model.supportsImageInput)

          Toggle(
            "ImageReference metadata tool",
            isOn: $model.foundationEnableImageMetadataTool
          )
          .disabled(!model.supportsImageInput)

          Toggle(
            "SpotlightSearchTool",
            isOn: $model.foundationEnableSpotlightSearchTool
          )

          Text(
            "도구 실행과 transcript 관리는 Apple의 native LanguageModelSession이 담당합니다. 이 앱은 provider이며 별도의 agent loop를 만들지 않습니다."
          )
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private struct MLXProviderSettingsCard: View {
    @Bindable var model: AppleIntelligenceModel

    var body: some View {
      SettingsCard {
        VStack(alignment: .leading, spacing: 16) {
          SettingsCardHeader(title: "MLX", systemImage: "cube")

          SettingsStatusRow(
            title: "상태",
            value: model.availabilityLabel,
            color: ProviderReadinessPresentation.color(for: model.readiness)
          )

          Divider()

          SettingsTextField(title: "로컬 모델 폴더", text: $model.mlxModelPath)

          Text(
            "앱 내부 추론은 HTTP 서버를 거치지 않고 MLXFoundationModels의 LanguageModel을 LanguageModelSession에 직접 연결합니다."
          )
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          Divider()

          SettingsSectionLabel(title: "Capability")
          Toggle("Guided generation", isOn: $model.mlxGuidedGeneration)
          Toggle("Tool calling", isOn: $model.mlxToolCalling)
          Toggle("Reasoning", isOn: $model.mlxReasoning)

          Text(
            "Tool calling과 reasoning은 모델/chat template이 실제 지원하는 경우에만 켜야 합니다. 이름으로 capability를 추측하지 않습니다."
          )
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private struct LiteRTProviderSettingsCard: View {
    @Bindable var model: AppleIntelligenceModel
    @State private var isModelImporterPresented = false

    var body: some View {
      SettingsCard {
        VStack(alignment: .leading, spacing: 14) {
          SettingsCardHeader(title: "LiteRT", systemImage: "cpu")

          SettingsStatusRow(
            title: "상태",
            value: model.availabilityLabel,
            color: ProviderReadinessPresentation.color(for: model.readiness)
          )

          Divider()

          HStack(spacing: 12) {
            SettingsValueRow(title: "모델", value: model.modelIdentityTitle)

            Button("모델 선택", systemImage: "folder") {
              isModelImporterPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          }

          Picker(
            "백엔드",
            selection: Binding(
              get: { model.liteRTBackend },
              set: { model.liteRTBackend = $0 }
            )
          ) {
            ForEach(LiteRTProviderBackendChoice.allCases, id: \.self) { backend in
              Text(backend.title).tag(backend)
            }
          }
          .pickerStyle(.segmented)
          .accessibilityLabel("LiteRT 백엔드")

          Picker(
            "Vision 백엔드",
            selection: Binding(
              get: { model.liteRTVisionBackend },
              set: { model.liteRTVisionBackend = $0 }
            )
          ) {
            ForEach(LiteRTProviderVisionBackendChoice.allCases, id: \.self) { backend in
              Text(backend.title).tag(backend)
            }
          }
          .pickerStyle(.segmented)
          .accessibilityLabel("LiteRT Vision 백엔드")

          Text(
            "Vision을 켜면 LiteRT-LM의 vision executor와 Foundation Models의 Attachment가 함께 사용됩니다. 모델 파일에 이미지 encoder가 없으면 요청 시 명시적으로 실패합니다."
          )
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .fileImporter(
        isPresented: $isModelImporterPresented,
        allowedContentTypes: [UTType(filenameExtension: "litertlm") ?? .data],
        allowsMultipleSelection: false
      ) { result in
        guard case .success(let urls) = result, let url = urls.first else { return }
        model.liteRTModelPath = url.path
      }
    }
  }

  private struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
      self.content = content()
    }

    var body: some View {
      content
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          .quaternary.opacity(0.32),
          in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(.quaternary.opacity(0.8), lineWidth: 1)
        }
    }
  }

  private struct SettingsCardHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.tint)
          .frame(width: 32, height: 32)
          .background(.quaternary.opacity(0.64), in: RoundedRectangle(cornerRadius: 9))

        Text(title)
          .font(.system(size: 17, weight: .semibold))

        Spacer(minLength: 0)
      }
    }
  }

  private struct SettingsSectionLabel: View {
    let title: String

    var body: some View {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
    }
  }

  private struct SettingsStatusRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
      HStack(spacing: 9) {
        Circle()
          .fill(color)
          .frame(width: 8, height: 8)

        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)

        Spacer(minLength: 0)

        Text(value)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
      }
    }
  }

  private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 14) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 58, alignment: .leading)

        Text(value)
          .font(.system(size: 13))
          .textSelection(.enabled)
          .lineLimit(2)

        Spacer(minLength: 0)
      }
    }
  }

  private struct SettingsTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
      HStack(spacing: 12) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 58, alignment: .leading)

        TextField(title, text: $text)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 13))
      }
    }
  }

  private struct SettingsFeedback: View {
    let message: String
    let systemImage: String

    var body: some View {
      Label(message, systemImage: systemImage)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
  }

#endif
