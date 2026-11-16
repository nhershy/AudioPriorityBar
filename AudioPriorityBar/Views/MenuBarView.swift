import SwiftUI
import CoreAudio
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var audioManager: AudioManager

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                AutoSwitchHeader()
                VolumeSliderView()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.02))

            Divider()
                .padding(.horizontal, 12)

            // Showing every remembered device can outgrow the screen, so the lists scroll
            // past a maximum height and otherwise take exactly the height they need.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    DeviceSectionView(title: "Output", icon: "speaker.wave.2.fill", type: .output)
                    DeviceSectionView(title: "Input", icon: "mic.fill", type: .input)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.horizontal, 12)

            FooterView()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 320)
    }
}

struct AutoSwitchHeader: View {
    @EnvironmentObject var audioManager: AudioManager

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-switch")
                    .font(.system(size: 13, weight: .semibold))
                Text(audioManager.isAutoEnabled
                     ? "Uses the top connected device"
                     : "Off: click a device to use it")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("Auto-switch", isOn: Binding(
                get: { audioManager.isAutoEnabled },
                set: { audioManager.setAutoEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
    }
}

struct VolumeSliderView: View {
    @EnvironmentObject var audioManager: AudioManager

    var volumeIcon: String {
        if audioManager.isOutputMuted || audioManager.volume <= 0 {
            return "speaker.slash.fill"
        } else if audioManager.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if audioManager.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: volumeIcon)
                .font(.system(size: 13))
                .foregroundColor(audioManager.volumeSupported ? .primary : .secondary.opacity(0.5))
                .frame(width: 20)

            Slider(
                value: Binding(
                    get: { Double(audioManager.volume) },
                    set: { audioManager.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .disabled(!audioManager.volumeSupported)
            .opacity(audioManager.volumeSupported ? 1 : 0.4)

            if audioManager.volumeSupported {
                Text("\(Int(audioManager.volume * 100))%")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Text("N/A")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(width: 40, alignment: .trailing)
                    .help("This device has no volume control")
            }
        }
        .onScrollWheel { delta in
            guard audioManager.volumeSupported else { return }
            let newVolume = audioManager.volume + Float(delta * 0.02)
            audioManager.setVolume(max(0, min(1, newVolume)))
        }
    }
}

// Scroll wheel modifier
struct ScrollWheelModifier: ViewModifier {
    let onScroll: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            ScrollWheelReceiver(onScroll: onScroll)
        )
    }
}

struct ScrollWheelReceiver: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.deltaY)
    }
}

extension View {
    func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View {
        modifier(ScrollWheelModifier(onScroll: action))
    }
}

/// One ranked list (outputs or inputs) with its heading, and its ignored devices while
/// "not connected · ignored" is open.
struct DeviceSectionView: View {
    @EnvironmentObject var audioManager: AudioManager
    let title: String
    let icon: String
    let type: AudioDeviceType

    private var devices: [AudioDevice] {
        type == .input ? audioManager.inputDevices : audioManager.outputDevices
    }

    private var ignoredDevices: [AudioDevice] {
        type == .input ? audioManager.ignoredInputDevices : audioManager.ignoredOutputDevices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title, icon: icon)

            if devices.isEmpty {
                Text(type == .input ? "No input devices connected" : "No output devices connected")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                DeviceListView(devices: devices, type: type)
            }

            if !ignoredDevices.isEmpty {
                SectionLabel(text: "Ignored", icon: "eye.slash")
                    .padding(.top, 4)
                DeviceListView(devices: ignoredDevices, type: type, isIgnoredList: true)
            }
        }
    }
}

struct SectionLabel: View {
    let text: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 4)
    }
}

struct FooterView: View {
    @EnvironmentObject var audioManager: AudioManager
    @StateObject private var launchManager = LaunchAtLoginManager.shared

    /// "3 not connected · 4 ignored", leaving out whichever is zero.
    private var hiddenSummary: String? {
        var parts: [String] = []
        if audioManager.notConnectedCount > 0 {
            parts.append("\(audioManager.notConnectedCount) not connected")
        }
        if audioManager.ignoredCount > 0 {
            parts.append("\(audioManager.ignoredCount) ignored")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            if let hiddenSummary {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        audioManager.setShowAllDevices(!audioManager.showAllDevices)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(audioManager.showAllDevices ? 90 : 0))
                        Text(hiddenSummary)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(audioManager.showAllDevices
                      ? "Show connected devices only"
                      : "Show devices that are not connected or ignored")
            }

            Spacer(minLength: 8)

            InfoButton()

            Menu {
                Toggle("Launch at Login", isOn: $launchManager.isEnabled)
                Divider()
                Button("Quit Audio Priority Bar") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
    }
}

struct InfoButton: View {
    @State private var showInfo = false

    var body: some View {
        Button {
            showInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("How it works")
        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Audio Priority Bar")
                    .font(.system(size: 14, weight: .bold))

                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(icon: "arrow.up.arrow.down", text: "Drag devices to rank them. The highest-ranked device that is connected gets used.")
                    InfoRow(icon: "arrow.triangle.2.circlepath", text: "With Auto-switch on, that device stays selected even if macOS or another app changes it. Turn it off to choose a device yourself by clicking it.")
                    InfoRow(icon: "plus.circle", text: "A device you connect for the first time starts at the bottom of its list.")
                    InfoRow(icon: "eye.slash", text: "Hover over a device and click ••• (or right-click it) to ignore it. Ignored devices are hidden and never selected.")
                    InfoRow(icon: "chevron.right", text: "Open “not connected · ignored” at the bottom to rank devices that are not plugged in, stop ignoring a device, or forget one.")
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }
}

struct InfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
