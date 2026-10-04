import AppleLocalAIHost
import Testing

private let routingCandidates = [
  ModelCandidate(id: "system", location: .system, available: true, capabilities: [.vision]),
  ModelCandidate(
    id: "coreai", location: .customLocal, available: true,
    capabilities: [.guidedGeneration, .toolCalling]),
  ModelCandidate(
    id: "pcc", location: .privateCloud, available: true,
    capabilities: [.vision, .guidedGeneration, .reasoning, .toolCalling]),
  ModelCandidate(id: "mlx", location: .externalServer, available: true, capabilities: []),
]

@Test func automaticRoutingStaysLocalEvenWithCloudConsent() throws {
  let decision = try ModelSelectionPolicy.select(
    workload: .automaticLocal, requirements: [.guidedGeneration],
    candidates: routingCandidates, allowPrivateCloud: true)
  #expect(decision.id == "coreai")
  #expect(throws: ModelSelectionError.noEligibleModel) {
    try ModelSelectionPolicy.select(
      workload: .automaticLocal, requirements: [.reasoning],
      candidates: routingCandidates, allowPrivateCloud: true)
  }
}

@Test func privateCloudRequiresConsentEvenWhenManuallySelected() throws {
  for workload in [ModelWorkload.deepReasoning, .manual] {
    #expect(throws: ModelSelectionError.noEligibleModel) {
      try ModelSelectionPolicy.select(
        workload: workload, requirements: [.reasoning], candidates: routingCandidates,
        allowPrivateCloud: false, manualSelection: "pcc")
    }
    let decision = try ModelSelectionPolicy.select(
      workload: workload, requirements: [.reasoning], candidates: routingCandidates,
      allowPrivateCloud: true, manualSelection: "pcc")
    #expect(decision.id == "pcc")
  }
}

@Test func workloadAndAllCapabilitiesMustMatch() throws {
  let vision = try ModelSelectionPolicy.select(
    workload: .visionTools, requirements: [.vision], candidates: routingCandidates,
    allowPrivateCloud: false)
  #expect(vision.id == "system")
  #expect(throws: ModelSelectionError.noEligibleModel) {
    try ModelSelectionPolicy.select(
      workload: .offlineCustom, requirements: [.vision], candidates: routingCandidates,
      allowPrivateCloud: true)
  }
  #expect(throws: ModelSelectionError.noEligibleModel) {
    try ModelSelectionPolicy.select(
      workload: .visionTools, requirements: [.vision, .toolCalling], candidates: routingCandidates,
      allowPrivateCloud: true)
  }
}

@Test func unavailableLocalDoesNotEscapeToAnExternalServer() throws {
  let candidates = [
    ModelCandidate(id: "system", location: .system, available: false, capabilities: []),
    routingCandidates[3],
  ]
  #expect(throws: ModelSelectionError.noEligibleModel) {
    try ModelSelectionPolicy.select(
      workload: .automaticLocal, requirements: [], candidates: candidates, allowPrivateCloud: true)
  }
  let explicit = try ModelSelectionPolicy.select(
    workload: .manual, requirements: [], candidates: candidates, allowPrivateCloud: false,
    manualSelection: "mlx")
  #expect(explicit.id == "mlx")
}

@Test func manualSelectionStillRequiresRequestCapabilities() {
  let candidates = [
    ModelCandidate(
      id: "text-only", location: .customLocal, available: true, capabilities: [])
  ]

  #expect(throws: ModelSelectionError.noEligibleModel) {
    try ModelSelectionPolicy.select(
      workload: .manual,
      requirements: [.toolCalling],
      candidates: candidates,
      allowPrivateCloud: false,
      manualSelection: "text-only")
  }
}
