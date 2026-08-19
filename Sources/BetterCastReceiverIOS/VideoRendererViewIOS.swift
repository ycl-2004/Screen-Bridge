#if canImport(UIKit)
import UIKit
import AVFoundation

// Just a protocol to match what NetworkListenerIOS expects
@MainActor
protocol VideoRendererIOS: AnyObject {
    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool
}

class VideoRendererViewIOS: UIView, VideoRendererIOS {
    
    override class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }
    
    private var videoLayer: AVSampleBufferDisplayLayer {
        return layer as! AVSampleBufferDisplayLayer
    }
    
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
        videoLayer.videoGravity = .resizeAspect
        // Use timebase for smooth playback (standard remote desktop technique)
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let tb = controlTimebase {
            videoLayer.controlTimebase = tb
            CMTimebaseSetTime(tb, time: CMTime.zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }
    }
    
    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        if videoLayer.status == .failed {
            consecutiveLayerFailures += 1
            if consecutiveLayerFailures > 25 {
                // Flushing on every failure only produced a flush→enqueue→fail
                // loop with no way out. Past this many consecutive failures the
                // layer itself is wedged; reset it fully and let the next
                // keyframe repopulate it.
                consecutiveLayerFailures = 0
                LogManager.shared.log("VideoRenderer: Layer failed repeatedly — resetting display layer")
                resetLayerForRecovery()
                return false
            }
            LogManager.shared.log("VideoRenderer: Layer failed, flushing")
            videoLayer.flush()
        } else {
            consecutiveLayerFailures = 0
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

    private var consecutiveLayerFailures = 0

    /// In-place recovery for a layer stuck in `.failed`. The view's root layer
    /// cannot be swapped out from under UIKit, so recovery resets it: flush
    /// discards the poisoned queue, and rebuilding the control timebase clears
    /// the other half of the wedged state. The next keyframe (the listener
    /// keeps requesting them on failure) repopulates the picture.
    private func resetLayerForRecovery() {
        videoLayer.flushAndRemoveImage()
        videoLayer.controlTimebase = nil
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let tb = controlTimebase {
            videoLayer.controlTimebase = tb
            CMTimebaseSetTime(tb, time: CMTime.zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }
    }

    /// Remove the last decoded frame so a disconnected session never lingers
    /// on screen looking like a frozen stream.
    func clear() {
        videoLayer.flushAndRemoveImage()
    }

    /// Toggle between aspect-fill (full screen) and aspect-fit (letterbox)
    var isAspectFill: Bool = false {
        didSet {
            videoLayer.videoGravity = isAspectFill ? .resizeAspectFill : .resizeAspect
        }
    }
}
#endif
