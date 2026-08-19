import Foundation
@preconcurrency import Network
import BetterCastShared

/// Owns AAC framing, bounded FIFO backpressure, and Network.framework sends on
/// a dedicated serial queue. UI/main-actor state only receives failure signals;
/// encoded audio bytes never transit the main queue.
final class AudioPacketSender: AudioEncoderDelegate, @unchecked Sendable {
    /// A healthy 48 kHz AAC stream completes a packet send in milliseconds.
    /// Bound an unacknowledged Network.framework send so a half-open auxiliary
    /// socket cannot leave selected apps muted while packets are only dropped.
    private static let sendCompletionTimeout: TimeInterval = 3.0

    private let connection: NWConnection
    private let connectionId: UUID
    private let serviceName: String
    private let failureHandler: @Sendable (NWError) -> Void
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()

    private var pendingPackets = BoundedAudioPacketFIFO()
    private var sendInProgress = false
    private var invalidated = false
    private var paused = false
    private var failureReported = false
    private var sendGeneration: UInt64 = 0
    private var nextSequence: UInt32 = 0
    private var nextSampleTime: UInt64 = 0
    private var sentPackets = 0
    private var droppedPackets = 0
    private var sendLatencyEWMA: TimeInterval = 0

    init(
        connection: NWConnection,
        connectionId: UUID,
        serviceName: String,
        failureHandler: @escaping @Sendable (NWError) -> Void
    ) {
        self.connection = connection
        self.connectionId = connectionId
        self.serviceName = serviceName
        self.failureHandler = failureHandler
        self.queue = DispatchQueue(
            label: "com.screenbridge.audio-send.\(connectionId.uuidString)",
            qos: .userInteractive
        )
        queue.setSpecific(key: queueKey, value: ())
    }

    func audioEncoder(
        _ encoder: AudioEncoder,
        didEncode data: Data,
        sampleTime: UInt64?,
        for connectionId: UUID
    ) {
        guard connectionId == self.connectionId else { return }
        queue.async { [weak self] in
            self?.enqueueEncodedAAC(data, sampleTime: sampleTime)
        }
    }

    func invalidate() {
        let work = { [self] in
            invalidated = true
            sendGeneration &+= 1
            sendInProgress = false
            pendingPackets.removeAll()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            guard let self, !self.invalidated else { return }
            self.paused = paused
            if paused {
                self.pendingPackets.removeAll()
            }
        }
    }

    private func enqueueEncodedAAC(_ data: Data, sampleTime: UInt64?) {
        guard !invalidated, !paused else { return }

        // The receiver validates this against the codec's frame size; derive it
        // from the same constant the encoder uses instead of a second literal.
        let sampleCount = UInt16(BCConstants.aacFrameSize)
        let packetSampleTime = sampleTime ?? nextSampleTime
        let framedAudio = FramedAudioPacket(
            header: AudioPacketHeader(
                sequence: nextSequence,
                sampleTime: packetSampleTime,
                sampleCount: sampleCount,
                codec: .aacLC,
                flags: sampleTime == nil ? 0 : AudioPacketFlags.sampleTimeValid
            ),
            payload: data
        ).encoded()
        nextSequence &+= 1
        nextSampleTime = packetSampleTime &+ UInt64(sampleCount)

        var body = Data([StreamFraming.SenderControlTypeByte.audio])
        body.append(framedAudio)
        guard body.count <= StreamFraming.maxAudioFrameBytes else {
            droppedPackets += 1
            LogManager.shared.log("AudioSend: Rejected oversized AAC packet for \(serviceName)")
            return
        }

        var lengthPrefix = UInt32(body.count).bigEndian
        var packet = Data(bytes: &lengthPrefix, count: MemoryLayout<UInt32>.size)
        packet.append(body)

        if sendInProgress {
            if pendingPackets.enqueue(packet) != nil {
                droppedPackets += 1
                if droppedPackets == 1 || droppedPackets % 25 == 0 {
                    logStatistics(reason: "FIFO full; dropped oldest pending packet")
                }
            }
            return
        }

        send(packet)
    }

    private func send(_ packet: Data) {
        guard !invalidated else { return }
        sendInProgress = true
        sendGeneration &+= 1
        let generation = sendGeneration
        let startedAt = DispatchTime.now().uptimeNanoseconds

        queue.asyncAfter(deadline: .now() + Self.sendCompletionTimeout) { [weak self] in
            self?.handleSendTimeout(generation: generation)
        }

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            self?.queue.async { [weak self] in
                self?.finishSend(generation: generation, startedAt: startedAt, error: error)
            }
        })
    }

    private func finishSend(generation: UInt64, startedAt: UInt64, error: NWError?) {
        guard !invalidated, sendInProgress, generation == sendGeneration else { return }
        sendInProgress = false

        if let error {
            pendingPackets.removeAll()
            guard !failureReported else { return }
            failureReported = true
            LogManager.shared.log("AudioSend: Send failed for \(serviceName): \(error)")
            failureHandler(error)
            return
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        let latency = TimeInterval(elapsed) / 1_000_000_000
        sendLatencyEWMA = sendLatencyEWMA == 0
            ? latency
            : (sendLatencyEWMA * 0.8) + (latency * 0.2)
        sentPackets += 1

        if sentPackets == 1 || sentPackets % 100 == 0 {
            logStatistics(reason: "send progress")
        }

        if let next = pendingPackets.dequeue() {
            send(next)
        }
    }

    private func handleSendTimeout(generation: UInt64) {
        guard !invalidated,
              sendInProgress,
              generation == sendGeneration,
              !failureReported else { return }

        invalidated = true
        sendInProgress = false
        failureReported = true
        pendingPackets.removeAll()
        let error = NWError.posix(.ETIMEDOUT)
        LogManager.shared.log(
            "AudioSend: Send stalled for \(serviceName) beyond \(Int(Self.sendCompletionTimeout))s; restoring local audio"
        )
        failureHandler(error)
    }

    private func logStatistics(reason: String) {
        let totalDepth = pendingPackets.count + (sendInProgress ? 1 : 0)
        LogManager.shared.log(
            "AudioSend: \(serviceName) \(reason) — queue=\(totalDepth)/\(AudioSendQueuePolicy.maxBufferedPackets), "
                + "dropped=\(droppedPackets), latency=\(Int(sendLatencyEWMA * 1_000))ms"
        )
    }
}
