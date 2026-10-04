#if os(macOS)

  import CoreGraphics

  enum InterfaceMetrics {
    static let sidebarWidth: CGFloat = 272
    static let sidebarMinimumWidth: CGFloat = 224
    static let sidebarMaximumWidth: CGFloat = 360
    static let minimumWindowWidth: CGFloat = 1_040
    static let minimumWindowHeight: CGFloat = 680
    static let defaultWindowWidth: CGFloat = 1_180
    static let defaultWindowHeight: CGFloat = 740
    static let menuBarPopoverWidth: CGFloat = 360
    static let sidebarHorizontalPadding: CGFloat = 18
    static let contentHorizontalPadding: CGFloat = 28
    static let controlCornerRadius: CGFloat = 12
    static let messageCornerRadius: CGFloat = 20
  }

#endif
