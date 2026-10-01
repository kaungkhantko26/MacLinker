import Foundation

/// A dedicated, high-priority thread with its own run loop. Event taps, input injection and the
/// mouse-batching timer all live here, so a busy UI (the main thread) can never delay the pointer.
final class InputThread: Thread {
    private(set) var runLoop: CFRunLoop!
    private let ready = DispatchSemaphore(value: 0)

    override init() {
        super.init()
        name = "maclinker.input"
        qualityOfService = .userInteractive
        start()
        ready.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A run loop with no sources exits immediately; this keeps it alive until real sources arrive.
        RunLoop.current.add(Timer(timeInterval: 3600, repeats: true) { _ in }, forMode: .common)
        ready.signal()
        while !isCancelled { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    /// Runs `block` on the input thread, in order with everything else submitted here.
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}
