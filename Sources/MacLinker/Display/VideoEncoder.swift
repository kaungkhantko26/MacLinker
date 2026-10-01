import Foundation
import VideoToolbox
import CoreMedia

/// Hardware H.264 encoder tuned for latency: no frame reordering, real-time priority, periodic key frames.
/// Output is AVCC (each NAL unit prefixed by its 4-byte length), which the viewer's display layer decodes directly.
final class VideoEncoder {
    enum EncoderError: Error { case create(OSStatus), configure(OSStatus) }

    /// SPS/PPS, delivered whenever they change (at least once, before the first key frame).
    var onParameterSets: (([Data]) -> Void)?
    /// (isKeyframe, presentation time in ms, AVCC data)
    var onFrame: ((Bool, UInt64, Data) -> Void)?

    private var session: VTCompressionSession?
    private var lastParameterSets: [Data] = []
    private let lock = NSLock()
    private var forceKey = true

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: encoderOutput,
            refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw EncoderError.create(status) }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) throws {
            let s = VTSessionSetProperty(session, key: key, value: value)
            if s != noErr { throw EncoderError.configure(s) }
        }
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        try set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        // Cap bursts at 1.5x the average over one second so a key frame can't flood the link.
        try set(kVTCompressionPropertyKey_DataRateLimits, [bitrate * 3 / 16, 1] as CFArray)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    /// The next frame will be a key frame (a new viewer joined, or frames were dropped).
    func requestKeyframe() { lock.lock(); forceKey = true; lock.unlock() }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        lock.lock(); let force = forceKey; forceKey = false; lock.unlock()
        let props = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    /// Waits for frames still inside the encoder (used before stopping, and by tests).
    func flush() {
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
    }

    func invalidate() {
        guard let s = session else { return }
        session = nil
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
    }

    fileprivate func handle(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        let isKey = !notSync

        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            let sets = Self.parameterSets(from: format)
            if !sets.isEmpty, sets != lastParameterSets {
                lastParameterSets = sets
                onParameterSets?(sets)
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
        }
        guard copied == noErr else { return }
        let ms = UInt64(max(0, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000))
        onFrame?(isKey, ms, data)
    }

    static func parameterSets(from format: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: nil)
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                  parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                  nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                sets.append(Data(bytes: ptr, count: size))
            }
        }
        return sets
    }
}

private func encoderOutput(refcon: UnsafeMutableRawPointer?, sourceRefcon: UnsafeMutableRawPointer?,
                           status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
    guard status == noErr, let sample, CMSampleBufferDataIsReady(sample), let refcon else { return }
    Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue().handle(sample)
}

/// Builds the format description the viewer's display layer needs from SPS/PPS.
func makeH264FormatDescription(parameterSets: [Data]) -> CMVideoFormatDescription? {
    guard !parameterSets.isEmpty else { return nil }
    var format: CMVideoFormatDescription?
    var status: OSStatus = -1
    let pointers = parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
        set.copyBytes(to: p, count: set.count)
        return p
    }
    defer { pointers.forEach { $0.deallocate() } }
    let constPointers: [UnsafePointer<UInt8>] = pointers.map { UnsafePointer($0) }
    let sizes = parameterSets.map { $0.count }
    constPointers.withUnsafeBufferPointer { ptrs in
        sizes.withUnsafeBufferPointer { szs in
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: parameterSets.count, parameterSetPointers: ptrs.baseAddress!,
                parameterSetSizes: szs.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
    }
    return status == noErr ? format : nil
}

/// Wraps one AVCC frame in a sample buffer that AVSampleBufferDisplayLayer (or VTDecompressionSession) can decode.
func makeSampleBuffer(frame: Data, format: CMVideoFormatDescription, timestampMs: UInt64,
                      displayImmediately: Bool = true) -> CMSampleBuffer? {
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.count,
                                             blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                             dataLength: frame.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                             blockBufferOut: &block) == noErr, let block else { return nil }
    let replaced = frame.withUnsafeBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return -1 }
        return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.count)
    }
    guard replaced == noErr else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid,
                                    presentationTimeStamp: CMTime(value: Int64(timestampMs), timescale: 1000),
                                    decodeTimeStamp: .invalid)
    var size = frame.count
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                    sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                    sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
    if displayImmediately,
       let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
}
