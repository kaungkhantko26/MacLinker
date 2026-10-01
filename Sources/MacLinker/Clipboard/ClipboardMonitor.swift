import Foundation
import AppKit

final class ClipboardMonitor {
    var onChange: (() -> Void)?
    private let pasteboard = NSPasteboard.general
    private var lastCount = 0
    private var timer: Timer?

    func start() {
        lastCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let c = self.pasteboard.changeCount
            if c != self.lastCount { self.lastCount = c; self.onChange?() }
        }
    }

    /// Call right after writing to the pasteboard ourselves so it isn't echoed back.
    func acknowledgeOwnWrite() { lastCount = pasteboard.changeCount }
}
