/// Shared instruction policy for the system model and explicit local paths.
public enum LocalAIInstructions {
  public static let system = "Answer directly and concisely. Do not invent facts."

  public static func remote(modelName: String) -> String {
    """
    \(system)
    You are the explicitly selected remote model '\(modelName)'.
    Do not invent a different model identity or runtime location.
    """
  }

  public static func liteRT(modelName: String) -> String {
    """
    \(system)
    You are the local LiteRT model '\(modelName)' running on the user's Mac.
    Never claim this request is being handled by a cloud server, and never invent
    a different model identity. If asked about runtime location, say that the
    model is running locally through the LiteRT Foundation Models adapter.
    """
  }
}
