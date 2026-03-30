import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let usageStore = UsageStore(provider: CodexUsageProvider())
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configurePopover()
        configureStatusItem()
        bindUsageStore()
        updateStatusItemTitle()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView(usageStore: usageStore)
        )
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else {
            return
        }

        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    private func bindUsageStore() {
        usageStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemTitle()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else {
            return
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let labelColor = resolvedColor(.labelColor, for: button)
        let title: NSAttributedString

        if usageStore.refreshState == .enabled {
            let attributedTitle = NSMutableAttributedString(
                string: "\(usageStore.primaryPercent)",
                attributes: [
                    .foregroundColor: usageColor(for: usageStore.primaryPercent),
                    .font: font,
                ]
            )

            attributedTitle.append(
                NSAttributedString(
                    string: " - ",
                    attributes: [
                        .foregroundColor: labelColor,
                        .font: font,
                    ]
                )
            )

            attributedTitle.append(
                NSAttributedString(
                    string: "\(usageStore.secondaryPercent)",
                    attributes: [
                        .foregroundColor: usageColor(for: usageStore.secondaryPercent),
                        .font: font,
                    ]
                )
            )

            title = attributedTitle
        } else {
            title = NSAttributedString(
                string: "Codex",
                attributes: [
                    .foregroundColor: labelColor,
                    .font: font,
                ]
            )
        }

        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        button.image = renderStatusImage(for: title)
    }

    private func resolvedColor(_ color: NSColor, for button: NSStatusBarButton) -> NSColor {
        var resolvedColor = color
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = color
        }
        return resolvedColor
    }

    private func usageColor(for percentUsed: Int) -> NSColor {
        switch percentUsed {
        case 0..<50:
            return NSColor(calibratedRed: 0.16, green: 0.54, blue: 0.34, alpha: 1)
        case 50..<80:
            return NSColor(calibratedRed: 0.95, green: 0.60, blue: 0.05, alpha: 1)
        default:
            return NSColor(calibratedRed: 0.78, green: 0.23, blue: 0.18, alpha: 1)
        }
    }

    private func renderStatusImage(for title: NSAttributedString) -> NSImage? {
        let textSize = title.size()
        let imageSize = NSSize(width: ceil(textSize.width), height: NSStatusBar.system.thickness)
        let image = NSImage(size: imageSize)
        image.isTemplate = false

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.set()
        NSRect(origin: .zero, size: imageSize).fill()

        let origin = NSPoint(
            x: 0,
            y: round((imageSize.height - textSize.height) / 2)
        )
        title.draw(at: origin)

        return image
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
