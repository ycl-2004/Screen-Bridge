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
            LogManager.shared.log("VideoRenderer: Layer failed, flushing")
            videoLayer.flush()
        }

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
    }

    /// Toggle between aspect-fill (full screen) and aspect-fit (letterbox)
    var isAspectFill: Bool = false {
        didSet {
            videoLayer.videoGravity = isAspectFill ? .resizeAspectFill : .resizeAspect
        }
    }
}
#endif
