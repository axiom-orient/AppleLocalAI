#if os(macOS)

  import SwiftUI

  struct MenuBarActionRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let action: () -> Void
    let isProminent: Bool
    let isDestructive: Bool
    let showsChevron: Bool

    @State private var isHovered = false

    var body: some View {
      Button(
        role: isDestructive ? .destructive : nil,
        action: action
      ) {
        MenuBarActionLabel(
          title: title,
          subtitle: subtitle,
          systemImage: systemImage,
          showsChevron: showsChevron
        )
      }
      .buttonStyle(.plain)
      .foregroundStyle(isDestructive ? .red : .primary)
      .background(
        backgroundColor,
        in: RoundedRectangle(cornerRadius: InterfaceMetrics.controlCornerRadius)
      )
      .overlay {
        if isProminent {
          RoundedRectangle(cornerRadius: InterfaceMetrics.controlCornerRadius)
            .stroke(Color.accentColor.opacity(0.58), lineWidth: 1)
        }
      }
      .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
      if isProminent {
        return Color.accentColor.opacity(isHovered ? 0.34 : 0.24)
      }
      return isHovered ? Color.primary.opacity(0.08) : .clear
    }
  }

  struct MenuBarActionLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let showsChevron: Bool

    var body: some View {
      HStack(spacing: 14) {
        Image(systemName: systemImage)
          .font(.system(size: 20, weight: .medium))
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.system(size: 16, weight: .medium))

          if let subtitle {
            Text(subtitle)
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)

        if showsChevron {
          Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
  }

#endif
