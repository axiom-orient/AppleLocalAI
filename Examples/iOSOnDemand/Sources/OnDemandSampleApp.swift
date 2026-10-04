import SwiftUI

@main
struct OnDemandSampleApp: App {
  @State private var model = OnDemandModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      OnDemandView(model: model)
        .task {
          if ProcessInfo.processInfo.arguments.contains("--verify-on-demand") {
            model.startVerification()
          }
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .background { model.stopAndRelease() }
        }
    }
  }
}

private struct OnDemandView: View {
  @Bindable var model: OnDemandModel

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("LFM2.5 230M · 149 MB")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text("첫 실행 때 모델을 다운로드합니다. 이후 기기 안에서 응답합니다.")
            .font(.subheadline)
          TextField("질문", text: $model.prompt, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...5)
            .disabled(model.isWorking)
            .accessibilityIdentifier("prompt")
          Button("실행") { model.run() }
            .buttonStyle(.borderedProminent)
            .disabled(
              model.isWorking
                || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityIdentifier("run")
          HStack {
            Button("중지") { model.stop() }
              .disabled(!model.isWorking || model.isStopping)
              .accessibilityIdentifier("stop")
            Spacer()
            Button("메모리 해제") { model.releaseMemory() }
              .disabled(model.isWorking || !model.isLoaded)
              .accessibilityIdentifier("release-memory")
          }
          if let progress = model.progress {
            ProgressView(value: progress)
              .accessibilityIdentifier("download-progress")
          }
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
          if let evidence = model.evidence {
            Text("검증: \(evidence.outcome) · \(evidence.checks.count)개 단계")
              .font(.caption)
              .accessibilityIdentifier("verification-result")
          }
        }
        .padding()
      }
      .navigationTitle("On-demand LLM")
    }
  }
}
