import Foundation

#if os(macOS)
  import AppleLocalAIWire
  import Darwin

  @main
  struct ProviderMain {
    @MainActor static func main() async {
      do {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments.isEmpty {
          print(
            "Usage: AppleLocalAIProvider --config <provider.json> [--check-config]\nModels stay behind FoundationModels.LanguageModelSession. Bind address is fixed to 127.0.0.1. Set the configured tokenEnvironment before serving."
          )
          return
        }
        guard arguments.count == 2 || arguments.count == 3, arguments[0] == "--config",
          arguments.count == 2 || arguments[2] == "--check-config"
        else {
          throw WireError.invalid("Use --config <path> [--check-config]")
        }
        let url = URL(fileURLWithPath: arguments[1])
        let data: Data
        do {
          let file = try FileHandle(forReadingFrom: url)
          defer { try? file.close() }
          let maximumConfigurationBytes = ProviderConfiguration.maximumConfigurationBytes
          guard let readData = try file.read(upToCount: maximumConfigurationBytes + 1),
            readData.count <= maximumConfigurationBytes
          else {
            throw WireError.invalid("Configuration exceeds the 4 MiB limit")
          }
          data = readData
        }
        let configuration = try ProviderConfiguration.decode(data)
        if arguments.count == 3 {
          print(
            "Configuration syntax and policy valid. Weights, native SDK APIs, credentials, model availability and client interoperability are NOT validated by this command."
          )
          return
        }
        let environment = ProcessInfo.processInfo.environment
        let token = try configuration.token(environment: environment)
        let provider = NativeProvider(configuration: configuration, environment: environment)
        try await ProviderHTTPServer(configuration: configuration, token: token, provider: provider)
          .run()
      } catch {
        FileHandle.standardError.write(
          Data("AppleLocalAIProvider failed: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
    }
  }
#else
  #error("This executable requires macOS 27 or later.")
#endif
