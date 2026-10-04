// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Parts of this implementation were originally authored by @john-rocky and
// ported from https://github.com/john-rocky/swift-litert-lm/tree/main.

#if canImport(FoundationModels) && compiler(>=6.4)

  import Foundation
  import FoundationModels
  @preconcurrency import LiteRTLM

  /// A LiteRT-LM model exposed as an Apple Foundation Models backend.
  @available(iOS 27.0, macOS 27.0, *)
  public struct LiteRTLanguageModel: LanguageModel {
    public typealias Executor = LiteRTLMExecutor

    public let capabilities: LanguageModelCapabilities
    public let executorConfiguration: LiteRTLMExecutor.Configuration
    public let visualTokenBudget: Int32?

    /// Builds a model from an engine configuration without initializing native weights.
    init(engineConfig: EngineConfig, visualTokenBudget: Int32? = nil) {
      self.visualTokenBudget = visualTokenBudget
      self.executorConfiguration = LiteRTLMExecutor.Configuration(
        engineConfig: engineConfig)
      self.capabilities = Self.metadataCapabilities(for: engineConfig)
    }

    private static func metadataCapabilities(for engineConfig: EngineConfig)
      -> LanguageModelCapabilities
    {
      guard
        let metadata = LiteRTModelInspector.capabilities(
          for: URL(fileURLWithPath: engineConfig.modelPath)),
        metadata.supportsText
      else { return LanguageModelCapabilities([]) }

      return metadata.foundationModelCapabilities(visionEnabled: engineConfig.visionBackend != nil)
    }

    /// Builds a model from an on-disk `.litertlm` path and explicit settings.
    init(
      modelPath: String,
      backend: Backend = .gpu,
      visionBackend: Backend? = nil,
      audioBackend: Backend? = nil,
      visualTokenBudget: Int32? = nil,
      maxTokens: Int? = 2048,
      cacheDir: String? = nil
    ) throws {
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      self.init(
        engineConfig: try EngineConfig(
          modelPath: modelPath,
          backend: backend,
          visionBackend: visionBackend,
          audioBackend: audioBackend,
          maxNumTokens: maxTokens,
          cacheDir: cacheDir ?? caches?.path),
        visualTokenBudget: visualTokenBudget)
    }

    /// Releases cached engines after active generations and warmups have settled.
    public static func releaseCachedEngines() async {
      await EngineCache.shared.purgeAll()
    }
  }

#endif
