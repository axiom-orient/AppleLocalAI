import Foundation

private final class NativeTestResourceAnchor: NSObject {}

/// SwiftPM's testing helper dlopens this test image. Register its containing
/// bundle so upstream MLX can find its packaged Metal library via allBundles.
func registerNativeTestResources() {
  let bundle = Bundle(for: NativeTestResourceAnchor.self)
  _ = bundle.load()
  print("NATIVE_TEST_BUNDLE=\(bundle.bundleURL.path)")
}
