#if os(macOS)

  import AppleLocalAIHost

  /// Model identities for configuration and routing diagnostics, not session owners.
  enum LocalProviderChoice: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case coreAI = "core-ai"
    case apple
    case privateCloud = "private-cloud"
    case mlx
    case liteRT = "lite-rt"
    case remote

    var id: Self { self }

    var title: String {
      switch self {
      case .coreAI: "Core AI"
      case .apple: "Apple Intelligence"
      case .privateCloud: "Private Cloud"
      case .mlx: "MLX"
      case .liteRT: "LiteRT"
      case .remote: "Remote"
      }
    }

    var subtitle: String {
      switch self {
      case .coreAI: "Core AI · 이 Mac에서 실행"
      case .apple: "Apple Intelligence · 시스템 모델"
      case .privateCloud: "Apple Private Cloud · 명시적 전송 동의"
      case .mlx: "MLX · 이 Mac의 로컬 모델"
      case .liteRT: "LiteRT · 이 Mac의 로컬 모델"
      case .remote: "사용자 지정 원격 endpoint"
      }
    }

    var systemImage: String {
      switch self {
      case .coreAI: "shippingbox"
      case .apple: "apple.logo"
      case .privateCloud: "cloud"
      case .mlx: "cube"
      case .liteRT: "cpu"
      case .remote: "network"
      }
    }
  }

  extension ModelWorkload {
    var title: String {
      switch self {
      case .automaticLocal: "자동 · 로컬 우선"
      case .fastLocal: "빠르게 · 로컬"
      case .deepReasoning: "깊이 생각하기"
      case .offlineCustom: "오프라인 · 사용자 모델"
      case .visionTools: "이미지·도구 · 로컬"
      case .manual: "직접 선택"
      }
    }
  }

#endif
