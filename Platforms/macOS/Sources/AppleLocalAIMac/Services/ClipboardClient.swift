#if os(macOS)

  import AppKit

  @MainActor
  protocol ClipboardClient {
    @discardableResult
    func copy(_ value: String) -> Bool
  }

  @MainActor
  struct SystemClipboardClient: ClipboardClient {
    @discardableResult
    func copy(_ value: String) -> Bool {
      NSPasteboard.general.clearContents()
      return NSPasteboard.general.setString(value, forType: .string)
    }
  }

#endif
