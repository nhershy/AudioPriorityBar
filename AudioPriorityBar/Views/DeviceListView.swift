import SwiftUI
import CoreAudio

/// A list of device rows. The ranked lists can be reordered by dragging; the ignored list cannot.
struct DeviceListView: View {
    @EnvironmentObject var audioManager: AudioManager
    let devices: [AudioDevice]
    let type: AudioDeviceType
    var isIgnoredList: Bool = false

    /// Row being dragged, and the gap it would be dropped into (0 = above the first row,
    /// `devices.count` = below the last). Nil while the drop would not move anything.
    @State private var draggingIndex: Int? = nil
    @State private var targetGap: Int? = nil

    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 2

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            // Identity is the UID: every disconnected device has the same AudioObjectID.
            ForEach(Array(devices.enumerated()), id: \.element.uid) { index, device in
                DeviceRow(
                    device: device,
                    rank: index + 1,
                    isIgnoredRow: isIgnoredList,
                    isDragging: draggingIndex == index,
                    showDropAbove: draggingIndex != nil && targetGap == index,
                    showDropBelow: draggingIndex != nil && targetGap == devices.count && index == devices.count - 1,
                    onDragChanged: { pointerY in
                        draggingIndex = index
                        let gap = dropGap(forRow: index, pointerY: pointerY)
                        if gap != targetGap {
                            targetGap = gap
                        }
                    },
                    onDragEnded: {
                        if let gap = targetGap {
                            audioManager.moveDevice(type: type, from: index, to: gap)
                        }
                        draggingIndex = nil
                        targetGap = nil
                    }
                )
                .zIndex(draggingIndex == index ? 100 : 0)
            }
        }
    }

    /// The gap nearest the pointer. `pointerY` is measured from the top of the dragged row.
    private func dropGap(forRow index: Int, pointerY: CGFloat) -> Int? {
        let pitch = Self.rowHeight + Self.rowSpacing
        let listY = CGFloat(index) * pitch + pointerY
        let gap = min(max(Int((listY / pitch).rounded()), 0), devices.count)
        // The gaps directly above and below the dragged row leave it where it is.
        return (gap == index || gap == index + 1) ? nil : gap
    }
}

struct DeviceRow: View {
    @EnvironmentObject var audioManager: AudioManager
    let device: AudioDevice
    let rank: Int
    let isIgnoredRow: Bool
    let isDragging: Bool
    let showDropAbove: Bool
    let showDropBelow: Bool
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var isHovering = false

    private var isActive: Bool {
        !isIgnoredRow && audioManager.isActive(device)
    }

    /// A click picks the device only while auto-switching is off.
    private var isSelectable: Bool {
        !isIgnoredRow && device.isConnected && !audioManager.isAutoEnabled
    }

    private var isDimmed: Bool {
        isIgnoredRow || !device.isConnected
    }

    private var helpText: String {
        if isIgnoredRow {
            return "\(device.name) (ignored)"
        } else if !device.isConnected {
            return "\(device.name) (not connected)"
        } else if isSelectable && !isActive {
            return "\(device.name)\nClick to use, drag to rank"
        }
        return "\(device.name)\nDrag to rank"
    }

    var body: some View {
        HStack(spacing: 6) {
            rankOrHandle

            // The device in use gets a filled accent circle, like the sound list in Control Center.
            Image(systemName: device.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isActive ? .white : (isDimmed ? .secondary : .primary))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(isActive ? Color.accentColor : Color.primary.opacity(isDimmed ? 0.05 : 0.1))
                )

            Text(device.name)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(isDimmed ? .secondary : .primary)

            if let lastSeen = audioManager.lastSeenText(for: device) {
                Text(lastSeen)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                    .fixedSize()
            }

            if audioManager.isMuted(device) {
                Text("Muted")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .fixedSize()
            }

            Spacer(minLength: 4)

            actionsMenu
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .frame(height: DeviceListView.rowHeight)
        .opacity(isDragging ? 0.5 : (isDimmed ? 0.6 : 1))
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Color.accentColor.opacity(0.2) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isDragging ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .overlay(alignment: .top) {
            if showDropAbove {
                DropIndicatorLine()
                    .offset(y: -(DeviceListView.rowSpacing / 2 + 1))
            }
        }
        .overlay(alignment: .bottom) {
            if showDropBelow {
                DropIndicatorLine()
                    .offset(y: DeviceListView.rowSpacing / 2 + 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(helpText)
        .onTapGesture {
            if isSelectable {
                audioManager.selectDevice(device)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { onDragChanged($0.location.y) }
                .onEnded { _ in onDragEnded() },
            including: isIgnoredRow ? .subviews : .all
        )
        .contextMenu { menuItems }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .animation(.easeInOut(duration: 0.1), value: showDropAbove)
        .animation(.easeInOut(duration: 0.1), value: showDropBelow)
    }

    /// The rank number, replaced by a drag handle while hovering. Ignored rows have neither.
    private var rankOrHandle: some View {
        ZStack {
            if !isIgnoredRow {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .opacity(isHovering || isDragging ? 1 : 0)

                Text("\(rank)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(isActive ? .accentColor : .secondary)
                    .opacity(isHovering || isDragging ? 0 : 1)
            }
        }
        .frame(width: 20)
    }

    /// The ••• button, visible while hovering. Its space is always reserved so rows do not shift.
    private var actionsMenu: some View {
        ZStack {
            if isHovering && !isDragging {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .transition(.opacity)
            }
        }
        .frame(width: 26, height: 24)
    }

    @ViewBuilder
    private var menuItems: some View {
        if isIgnoredRow {
            Button {
                audioManager.setIgnored(device, false)
            } label: {
                Label("Stop Ignoring", systemImage: "eye")
            }
        } else {
            Button {
                audioManager.setIgnored(device, true)
            } label: {
                Label("Ignore", systemImage: "eye.slash")
            }
        }

        if !device.isConnected {
            Divider()
            Button(role: .destructive) {
                audioManager.forgetDevice(device)
            } label: {
                Label("Forget Device", systemImage: "trash")
            }
        }
    }
}

/// The line showing where a dragged row would be dropped.
struct DropIndicatorLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        .padding(.horizontal, 2)
    }
}
