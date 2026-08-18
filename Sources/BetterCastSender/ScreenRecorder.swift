import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import CoreMedia

protocol ScreenRecorderDelegate: AnyObject {
    func screenRecorderDidFailToStart(_ recorder: ScreenRecorder, reason: String)
    func screenRecorderDidStopUnexpectedly(_ recorder: ScreenRecorder)
}

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var videoEncoder: VideoEncoder?
    private var targetDisplayID: CGDirectDisplayID?
    var audioEncoder: AudioEncoder?
    var captureAudio: Bool = false
    weak var delegate: ScreenRecorderDelegate?
    /// ScreenCaptureKit may invoke different output queues concurrently. Video
    /// submission and its counters are single-owner to preserve frame order.
    private let videoSampleQueue = DispatchQueue(
        label: "com.yccast.capture.video",
        qos: .userInitiated
    )
    private let audioSampleQueue = DispatchQueue(
        label: "com.yccast.capture.audio",
        qos: .userInitiated
    )

    /// `startCapture()` can still be in flight when a stop arrives — the retry
    /// loop alone allows up to two seconds. `stream` is only assigned once start
    /// succeeds, so a stop in that window used to see `nil`, do nothing, and
    /// leave the capture that started afterwards running with nobody holding it.
    private let stateLock = NSLock()
    private var isStopRequested = false

    private var width: Int
    private var height: Int
    private var captureFPS: Int32

    init(videoEncoder: VideoEncoder, targetDisplayID: CGDirectDisplayID? = nil, width: Int = 1920, height: Int = 1080, captureFPS: Int32 = 120) {
        self.videoEncoder = videoEncoder
        self.targetDisplayID = targetDisplayID
        self.width = width
        self.height = height
        self.captureFPS = captureFPS
        super.init()
    }
    
    func startCapture() async {
        do {
            // Retry logic for Virtual Display availability (Race condition fix)
            var display: SCDisplay?
            
            if let targetID = targetDisplayID {
                LogManager.shared.log("ScreenRecorder: Searching for target display \(targetID)...")
                let maximumAttempts = 10 // Retry for at most 2 seconds.
                for i in 0..<maximumAttempts {
                    let stopWasRequested = stateLock.withLock { isStopRequested }
                    if stopWasRequested {
                        LogManager.shared.log("ScreenRecorder: Stop requested while waiting for target display")
                        return
                    }

                    let content = try await SCShareableContent.current
                    if let match = content.displays.first(where: { $0.displayID == targetID }) {
                        display = match
                        LogManager.shared.log("ScreenRecorder: Found target display on attempt \(i+1)")
                        break
                    }

                    if i == 0 || (i + 1).isMultiple(of: 10) {
                        LogManager.shared.log(
                            "ScreenRecorder: Target display \(targetID) not visible on attempt \(i + 1); "
                                + "shareable displays: \(content.displays.map(\.displayID))"
                        )
                    }

                    if i + 1 < maximumAttempts {
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                
                if display == nil {
                    // A display ScreenCaptureKit cannot see is not a capture
                    // backend problem — it is a display that WindowServer never
                    // published, so there is no desktop on it to capture. An
                    // alternate backend would only stream black frames and hide
                    // the real failure, so report it instead.
                    let reason = "Target display \(targetID) was never published to ScreenCaptureKit"
                    LogManager.shared.log("ScreenRecorder: \(reason). Not falling back to the main display.")
                    delegate?.screenRecorderDidFailToStart(self, reason: reason)
                    return
                }
            }
            
            // Fallback to Main Display explicitly if target not found or not specified
            if display == nil {
                 let content = try await SCShareableContent.current
                 // Use CGMainDisplayID to ensure we get the primary screen, not just 'first'
                 let mainID = CGMainDisplayID()
                 display = content.displays.first { $0.displayID == mainID }
                 
                 // Ultimate fallback
                 if display == nil { display = content.displays.first }
            }
            
            guard let display = display else {
                // Previously this returned silently, so the pipeline sat there
                // believing capture was starting.
                let reason = "No display was available to capture"
                LogManager.shared.log("ScreenRecorder: \(reason)")
                delegate?.screenRecorderDidFailToStart(self, reason: reason)
                return
            }

            let alreadyStopped = stateLock.withLock { isStopRequested }
            if alreadyStopped {
                LogManager.shared.log("ScreenRecorder: Stop requested before capture started — not starting")
                return
            }
            
            let filter = SCContentFilter(display: display, excludingWindows: [])
            
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: captureFPS)
            config.queueDepth = captureFPS > 60 ? 8 : 4
            config.capturesAudio = captureAudio
            config.sampleRate = Int(BCConstants.audioSampleRate)
            config.channelCount = Int(BCConstants.audioChannels)

            // Ask for the sharpest source ScreenCaptureKit can give us. Left at
            // `.automatic` it may hand back a downscaled surface on a HiDPI
            // display, which is exactly the detail this pipeline is trying to
            // preserve.
            config.captureResolution = .best

            // Pin the colour space. Without this the captured surface can be
            // tagged differently from what the receiver assumes, which shows up
            // as washed-out or oversaturated colour after the H.264 round trip.
            config.colorSpaceName = CGColorSpace.sRGB

            // The capture size is chosen to match the virtual display's backing
            // store exactly, so nothing should be rescaled on the way out.
            config.scalesToFit = false

            // This is a real extended display — the pointer belongs on it.
            config.showsCursor = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoSampleQueue)
            if captureAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioSampleQueue)
                LogManager.shared.log("ScreenRecorder: Audio capture enabled")
            }
            
            try await stream.startCapture()

            // A stop can land between the availability check above and here.
            let stoppedDuringStart = stateLock.withLock { () -> Bool in
                if isStopRequested { return true }
                self.stream = stream
                return false
            }

            if stoppedDuringStart {
                try? await stream.stopCapture()
                LogManager.shared.log("ScreenRecorder: Discarded capture that finished starting after stop was requested")
                return
            }

            LogManager.shared.log("ScreenRecorder: Started capture for display \(display.displayID)")

        } catch {
            LogManager.shared.log("ScreenRecorder: Failed to start capture: \(error.localizedDescription)")

            let stopWasRequested = stateLock.withLock { isStopRequested }
            if stopWasRequested {
                LogManager.shared.log("ScreenRecorder: Start ended after an intentional stop request")
                return
            }
            
            if let scError = error as? SCStreamError, scError.code == .userDeclined {
                 LogManager.shared.log("ScreenRecorder: PERMISSION DENIED. Go to System Settings > Privacy > Screen Recording")
            }
            delegate?.screenRecorderDidFailToStart(self, reason: error.localizedDescription)
        }
    }
    
    func stopCapture() {
        let current = stateLock.withLock { () -> SCStream? in
            isStopRequested = true
            let existing = stream
            stream = nil
            return existing
        }

        if let screenCaptureKitStream = current {
            Task {
                try? await screenCaptureKitStream.stopCapture()
            }
        }
    }

    // SCStreamOutput
    private var frameCount = 0
    private var audioFrameCount = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // ScreenCaptureKit also emits idle/blank/started/stopped status
            // samples. Only a valid, complete sample represents a generated
            // frame that VideoToolbox can safely encode.
            guard sampleBuffer.isValid,
                  let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                  ) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first,
                  let statusRawValue = attachments[.status] as? Int,
                  SCFrameStatus(rawValue: statusRawValue) == .complete else {
                return
            }
            frameCount += 1
            if frameCount % 300 == 0 {
                LogManager.shared.log("ScreenRecorder: Captured frame \(frameCount)")
            }
            videoEncoder?.encode(sampleBuffer: sampleBuffer)

        case .audio:
            guard sampleBuffer.isValid else { return }
            audioFrameCount += 1
            if audioFrameCount % 200 == 1 {
                LogManager.shared.log("ScreenRecorder: Audio frame \(audioFrameCount)")
            }
            audioEncoder?.encode(sampleBuffer: sampleBuffer)

        case .microphone:
            // Never requested. ScreenBridge routes selected app audio, not the mic.
            break

        @unknown default:
            break
        }
    }
    
    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        LogManager.shared.log("ScreenRecorder: Stream stopped with error: \(error.localizedDescription)")
        let stoppedIntentionally = stateLock.withLock { isStopRequested }
        if !stoppedIntentionally {
            delegate?.screenRecorderDidStopUnexpectedly(self)
        }
    }
}
