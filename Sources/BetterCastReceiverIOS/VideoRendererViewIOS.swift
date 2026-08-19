#if canImport(UIKit)
import UIKit
import AVFoundation
import CoreMedia

// Just a protocol to match what NetworkListenerIOS expects
@MainActor
protocol VideoRendererIOS: AnyObject {
    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool
}

class VideoRendererViewIOS: UIView, VideoRendererIOS {

    // The display layer is a replaceable sublayer rather than the view's root
    // layer. A root `AVSampleBufferDisplayLayer` that enters `.failed` cannot
    // be swapped out from under UIKit, but Apple's contract for `.failed` is
    // exactly that: recovery requires a fresh layer instance. In-place
    // flush/timebase resets only produced a flush→enqueue→fail loop.
    private var videoLayer = AVSampleBufferDisplayLayer()

    /// Format description of the last sample actually enqueued. Enqueuing a
    /// sample whose format differs from the queued one without a flush in
    /// between wedges the layer into `.failed` — the in-stream resolution
    /// change (iPad rotation triggers a sender pipeline rebuild on the same
    /// connection) used to hit exactly that.
    private var lastEnqueuedFormatDescription: CMVideoFormatDescription?

    /// Tracks repeated failures so a poisoned stream cannot thrash layer
    /// replacement at frame rate.
    private var consecutiveLayerFailures = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        isUserInteractionEnabled = false
        configure(videoLayer)
        layer.addSublayer(videoLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // CATransaction disables implicit animation for frame changes; layout
        // passes during rotation must not animate the video bounds.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        if videoLayer.status == .failed {
            consecutiveLayerFailures += 1
            if consecutiveLayerFailures > 25 {
                // Replacement keeps failing; stop thrashing and let the
                // liveness watchdog (renderer stall) tear the session down.
                return false
            }
            LogManager.shared.log("VideoRenderer: Layer failed (\(consecutiveLayerFailures)x) — replacing display layer")
            replaceVideoLayerForRecovery()
        } else {
            consecutiveLayerFailures = 0
        }

        // Format-change guard: flush before the first sample of a new format
        // so the layer never holds samples with mixed format descriptions.
        if let formatDescription = sampleBuffer.formatDescription {
            if let lastFormat = lastEnqueuedFormatDescription,
               !Self.describesSameFormat(lastFormat, formatDescription) {
                LogManager.shared.log("VideoRenderer: Stream format changed — flushing display layer")
                videoLayer.flushAndRemoveImage()
            }
            lastEnqueuedFormatDescription = formatDescription
        }

        // Backpressure: enqueueing while the layer is still digesting floods it
        // and (with a blocked main thread) pins VideoToolbox's fixed-size pixel
        // buffer pool. Drop the frame instead — liveness sees the renderer
        // stall and the sender gets a keyframe request.
        guard videoLayer.isReadyForMoreMediaData else { return false }

        // Force immediate display — no queue buildup since each frame renders instantly
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let dict = attachments.first {
            dict[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        videoLayer.enqueue(sampleBuffer)
        return videoLayer.status != .failed
    }

    /// Remove the last decoded frame so a disconnected session never lingers
    /// on screen looking like a frozen stream.
    func clear() {
        videoLayer.flushAndRemoveImage()
        lastEnqueuedFormatDescription = nil
        consecutiveLayerFailures = 0
    }

    /// Toggle between aspect-fill (full screen) and aspect-fit (letterbox)
    var isAspectFill: Bool = false {
        didSet {
            videoLayer.videoGravity = isAspectFill ? .resizeAspectFill : .resizeAspect
        }
    }

    // MARK: - Layer management

    private func configure(_ displayLayer: AVSampleBufferDisplayLayer) {
        displayLayer.videoGravity = isAspectFill ? .resizeAspectFill : .resizeAspect
        displayLayer.frame = bounds
        // Use timebase for smooth playback (standard remote desktop technique)
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let tb = controlTimebase {
            displayLayer.controlTimebase = tb
            CMTimebaseSetTime(tb, time: CMTime.zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }
    }

    /// A `.failed` display layer is unrecoverable in place. Swap in a fresh
    /// instance; the next keyframe (the listener keeps requesting them on
    /// failure) repopulates the picture.
    private func replaceVideoLayerForRecovery() {
        let staleLayer = videoLayer
        let freshLayer = AVSampleBufferDisplayLayer()
        configure(freshLayer)
        videoLayer = freshLayer
        layer.addSublayer(freshLayer)
        staleLayer.flushAndRemoveImage()
        staleLayer.removeFromSuperlayer()
        lastEnqueuedFormatDescription = nil
    }

    /// Dimension/codec comparison instead of raw pointer equality: successive
    /// samples carry distinct `CMFormatDescription` instances even when the
    /// actual format is unchanged, so identity comparison would flush every
    /// frame.
    private static func describesSameFormat(
        _ lhs: CMVideoFormatDescription,
        _ rhs: CMVideoFormatDescription
    ) -> Bool {
        let lhsDimensions = CMVideoFormatDescriptionGetDimensions(lhs)
        let rhsDimensions = CMVideoFormatDescriptionGetDimensions(rhs)
        guard lhsDimensions.width == rhsDimensions.width,
              lhsDimensions.height == rhsDimensions.height,
              CMFormatDescriptionGetMediaSubType(lhs) == CMFormatDescriptionGetMediaSubType(rhs) else {
            return false
        }
        return lhs.extensions == rhs.extensions
    }
}
#endif
