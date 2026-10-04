import FoundationModels

#if !targetEnvironment(simulator)
  import _Vision_FoundationModels
#endif

public enum AppleLocalAITools {
  /// Vision tools supplied by Apple. Qualify image workflows on a physical
  /// iOS 27 device because these tools are unavailable in Simulator targets.
  #if targetEnvironment(simulator)
    @available(
      *, unavailable,
      message: "Apple Vision Foundation Models tools require a physical iOS 27 device."
    )
    public static func vision(
      ocr: Bool = true,
      barcode: Bool = true,
      imageMetadata: Bool = true
    ) -> [any Tool] {
      []
    }
  #else
    public static func vision(
      ocr: Bool = true,
      barcode: Bool = true,
      imageMetadata: Bool = true
    ) -> [any Tool] {
      var tools: [any Tool] = []
      if ocr { tools.append(OCRTool()) }
      if barcode { tools.append(BarcodeReaderTool()) }
      if imageMetadata { tools.append(AppleLocalAIImageMetadataTool()) }
      return tools
    }
  #endif
}

#if !targetEnvironment(simulator)
  @Generable
  struct AppleLocalAIImageMetadataArguments {
    @Guide(description: "The image from the current prompt to inspect.")
    var image: ImageReference
  }

  struct AppleLocalAIImageMetadataTool: Tool, Sendable {
    let name = "inspect_image"
    let description =
      "Inspect the dimensions and orientation of an image attached to the current prompt."

    @SessionProperty(\.history) var history

    func call(arguments: AppleLocalAIImageMetadataArguments) async throws -> String {
      guard let attachment = arguments.image.resolved(in: history) else {
        return "The referenced image is no longer available in the session history."
      }
      let image = attachment.cgImage
      return
        "Image \(arguments.image.attachmentLabel): \(image.width)x\(image.height) pixels, orientation \(attachment.orientation.rawValue)."
    }
  }
#endif
