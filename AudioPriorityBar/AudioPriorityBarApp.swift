import SwiftUI
import AppKit

@main
struct AudioPriorityBarApp: App {
    @StateObject private var audioManager = AudioManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(audioManager)
        } label: {
            Image(nsImage: MenuBarIcon.image(autoEnabled: audioManager.isAutoEnabled))
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon: a waveform while auto-switching is on, a slashed one while it is off.
enum MenuBarIcon {
    private static let autoOn = symbol(["waveform.badge.microphone", "waveform"])
    private static let autoOff = symbol(["waveform.slash", "waveform"])

    static func image(autoEnabled: Bool) -> NSImage {
        autoEnabled ? autoOn : autoOff
    }

    /// The first of `names` this macOS version has. Newer symbols are missing on macOS 13.
    private static func symbol(_ names: [String]) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Audio Priority Bar")?
                .withSymbolConfiguration(config) {
                image.isTemplate = true
                return image
            }
        }
        return NSImage()
    }
}
