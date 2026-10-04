import SwiftUI

@main
struct SystemModel27SampleApp: App {
  @State private var model = SystemModel27SampleModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      SystemModel27View(model: model)
        .task {
          if ProcessInfo.processInfo.arguments.contains("--verify-system-model27") {
            model.startVerification()
          }
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .background { model.stop() }
        }
    }
  }
}

private struct SystemModel27View: View {
  @Bindable var model: SystemModel27SampleModel

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("AppleLocalAI · Apple 온디바이스 모델 · iOS 27+")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(model.availabilityMessage)
            .accessibilityIdentifier("availability")
          TextField("질문", text: $model.prompt, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...5)
            .disabled(model.isWorking || model.isSessionBusy)
            .accessibilityIdentifier("prompt")
          HStack {
            Button("실행") { model.run() }
              .buttonStyle(.borderedProminent)
              .disabled(!model.canRun)
              .accessibilityIdentifier("run")
            Spacer()
            Button("중지") { model.stop() }
              .disabled(!model.isWorking || model.isStopping)
              .accessibilityIdentifier("stop")
          }
          if model.isWorking { ProgressView() }
          Text(model.status)
            .font(.subheadline)
            .accessibilityIdentifier("status")
          if let error = model.errorMessage {
            Text(error).foregroundStyle(.red)
              .accessibilityIdentifier("error")
          }
          Text(model.result.isEmpty ? "응답이 여기에 표시됩니다." : model.result)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier("response")
          if let report = model.report {
            Text("검증: \(report.outcome) · \(report.checks.count)개 단계")
              .font(.caption)
              .accessibilityIdentifier("verification-result")
          }
        }
        .padding()
      }
      .navigationTitle("Apple System Model 27")
    }
  }
}
