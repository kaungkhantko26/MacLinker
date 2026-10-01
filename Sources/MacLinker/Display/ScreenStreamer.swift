import Foundation
import ScreenCaptureKit
import CoreMedia

/// Captures one display with ScreenCaptureKit and feeds it to the H.264 encoder.
/// Needs the Screen Recording permission.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    enum StreamError: LocalizedError {
        case displayNotFound
        var errorDescription: String? { "The virtual display didn't appear in time." }
    }

    var onParameterSets: (([Data]) -> Void)?
    var onFrame: ((Bool, UInt64, Data) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private let queue = DispatchQueue(label: "maclinker.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var lastBuffer: CVPixelBuffer?
    private var lastPTS: Double = 0

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, bitrate: Int) async throws {
        let enc = try VideoEncoder(width: width, height: height, fps: fps, bitrate: bitrate)
        enc.onParameterSets = { [weak self] in self?.onParameterSets?($0) }
        enc.onFrame = { [weak self] in self?.onFrame?($0, $1, $2) }
        encoder = enc

        // The new display can take a moment to show up as shareable content.
        var target: SCDisplay?
        for _ in 0..<15 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        guard let display = target else { throw StreamError.displayNotFound }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 4
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.scalesToFit = true

        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        let s = stream
        stream = nil
        try? await s?.stopCapture()
        encoder?.flush()
        encoder?.invalidate()
        encoder = nil
        lock.lock(); lastBuffer = nil; lock.unlock()
    }

    /// A new viewer joined or frames were dropped. ScreenCaptureKit only delivers frames when the picture
    /// changes, so the last frame is re-encoded to give the viewer something to show right away.
    func requestKeyframe() {
        encoder?.requestKeyframe()
        lock.lock(); let buffer = lastBuffer; let pts = lastPTS; lock.unlock()
        if let buffer { encodeNext(buffer, after: pts) }
    }

    private func encodeNext(_ buffer: CVPixelBuffer, after previous: Double) {
        let now = max(CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())), previous + 0.001)
        lock.lock(); lastPTS = now; lock.unlock()
        encoder?.encode(buffer, pts: CMTime(seconds: now, preferredTimescale: 1000))
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        lock.lock(); lastBuffer = buffer; let previous = lastPTS; lock.unlock()
        encodeNext(buffer, after: previous)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}
