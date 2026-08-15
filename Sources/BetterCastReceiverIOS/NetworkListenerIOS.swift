#if canImport(UIKit)
import Foundation
import UIKit
import Network
import CoreMedia
import BetterCastShared

/// Single source of truth for the receiver's connection state.
/// The status text is derived alongside it for display.
enum ReceiverState {
    case waiting        // listening, no sender connected
    case connecting     // sender connected, pairing/authenticating
    case connected      // streaming session active
    case connectionLost // stream went silent without a clean disconnect (watchdog)
    case disconnected   // sender ended the session cleanly
}

protocol NetworkListenerDelegate: AnyObject {
    func networkListener(_ listener: NetworkListenerIOS, didUpdate state: ReceiverState, statusText: String)
    func networkListener(_ listener: NetworkListenerIOS, didReceiveInput event: InputEvent) // If we were receiving input
}

class NetworkListenerIOS {
    weak var delegate: NetworkListenerDelegate?
    
    private var tcpListener: NWListener?       // Wi-Fi — reachable by all devices
    private var tcpP2PListener: NWListener?    // AWDL — low-latency for Apple devices
    private var udpListener: NWListener?
    
    private var connectedClients: [NWConnection] = []
    private var connectionSessionKeys: [ObjectIdentifier: Data] = [:]
    private let pairingSecretStore: PairingSecretStoring = KeychainPairingSecretStore()
    
    // Dependencies
    weak var videoDecoder: VideoDecoder?
    weak var videoRenderer: VideoRendererIOS?
    private var audioPlayer: AudioPlayerIOS?
    
    private let networkQueue = DispatchQueue(label: "com.bettercast.network.ios", qos: .userInteractive)
    
    // UDP Reassembly
    private var udpBuffer: [UInt32: (total: Int, chunks: [UInt16: Data], time: Date)] = [:]
    private let udpLock = NSLock()
    private var lastDecodedFrameId: UInt32 = 0
    private var lastKeyframeRequest = Date.distantPast
    
    // Stats
    private var udpPacketsReceived = 0
    
    // Heartbeat
    private var heartbeatTimer: Timer?
    private var inputSequence: UInt64 = 0

    // Stream-health watchdog: a connected sender streams frames continuously,
    // so prolonged silence means the connection died without a clean close
    // (Mac force quit, power loss, network drop).
    private var lastDataReceived = Date()

    /// Liveness of the *video* stream specifically.
    ///
    /// The watchdog used to look only at `lastDataReceived`, which any body
    /// updates — including audio frames arriving on the second connection. So a
    /// frozen picture with healthy audio never tripped it: the iPad sat on a
    /// stale frame still reporting "Connected".
    private var lastVideoReceived = Date()
    private let streamSilenceTimeout: TimeInterval = 8.0
    private var pendingLossNotification = false

    private var isStarted = false

    init() {}

    func setup(decoder: VideoDecoder, renderer: VideoRendererIOS) {
        self.videoDecoder = decoder
        self.videoRenderer = renderer
        self.audioPlayer = AudioPlayerIOS()
        decoder.delegate = self
    }

    func start() {
        // Idempotent: saving the pairing code repeatedly must not stack
        // listeners (duplicate Bonjour records confuse the sender's first
        // dial) or heartbeat timers.
        guard !isStarted else {
            LogManager.shared.log("ReceiverIOS: start() ignored — already running")
            return
        }
        isStarted = true
        startPrivateP2P()
        startHeartbeat()
    }

    private func notifyState(_ state: ReceiverState, _ text: String) {
        DispatchQueue.main.async {
            self.delegate?.networkListener(self, didUpdate: state, statusText: text)
        }
    }

    /// Called by the view controller when the app returns to the foreground so
    /// the watchdog doesn't count suspended time as stream silence.
    func noteForegroundResumed() {
        lastDataReceived = Date()
        lastVideoReceived = Date()
    }

    private func startPrivateP2P() {
        let deviceName = UserDefaults.standard.string(forKey: "customDeviceName")
            ?? UIDevice.current.name

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let p2pParams = NWParameters(tls: nil, tcp: tcpOptions)
            p2pParams.includePeerToPeer = true
            p2pParams.serviceClass = .interactiveVideo

            let p2pListener = try NWListener(using: p2pParams)
            p2pListener.service = NWListener.Service(
                name: "\(deviceName) Private",
                type: PrivateBetterCastConstants.serviceType
            )

            p2pListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "TCP-P2P")
            }
            p2pListener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("ReceiverIOS (TCP-P2P): New private AWDL connection")
                self?.handleNewConnection(connection, type: "TCP")
            }

            p2pListener.start(queue: networkQueue)
            self.tcpP2PListener = p2pListener
        } catch {
            LogManager.shared.log("ReceiverIOS (TCP-P2P): Error \(error)")
            notifyState(.waiting, "Waiting for network access...")
        }
    }

    private func startTCP() {
        // Use custom name from settings, fall back to system device name
        let deviceName = UserDefaults.standard.string(forKey: "customDeviceName")
            ?? UIDevice.current.name

        // 1. Wi-Fi listener — reachable by ALL devices (Windows, Linux, Android, Mac)
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.serviceClass = .interactiveVideo

            // Try preferred port first for consistency with Mac/Windows receivers
            var listener: NWListener
            do {
                listener = try NWListener(using: parameters, on: 51820)
            } catch {
                LogManager.shared.log("ReceiverIOS (TCP): Port 51820 unavailable, using system-assigned port")
                listener = try NWListener(using: parameters)
            }
            listener.service = NWListener.Service(name: deviceName, type: BCConstants.tcpServiceType)

            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "TCP")
            }
            listener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("ReceiverIOS (TCP): New connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, type: "TCP")
            }

            listener.start(queue: networkQueue)
            self.tcpListener = listener
        } catch {
            LogManager.shared.log("ReceiverIOS (TCP): Error \(error)")
        }

        // 2. AWDL/P2P listener — low-latency direct link for Apple devices (Mac sender)
        //    Uses dynamic port (Apple devices resolve via Bonjour, don't need fixed port)
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let p2pParams = NWParameters(tls: nil, tcp: tcpOptions)
            p2pParams.includePeerToPeer = true
            p2pParams.serviceClass = .interactiveVideo

            let p2pListener = try NWListener(using: p2pParams) // dynamic port — OK for Apple
            p2pListener.service = NWListener.Service(name: "\(deviceName) P2P", type: BCConstants.tcpServiceType)

            p2pListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "TCP-P2P")
            }
            p2pListener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("ReceiverIOS (TCP-P2P): New AWDL connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, type: "TCP")
            }

            p2pListener.start(queue: networkQueue)
            self.tcpP2PListener = p2pListener
        } catch {
            LogManager.shared.log("ReceiverIOS (TCP-P2P): Error \(error)")
        }
    }
    
    private func startUDP() {
        do {
            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true
            
            let listener = try NWListener(using: parameters)
            let udpDeviceName = UIDevice.current.name
            listener.service = NWListener.Service(name: udpDeviceName, type: BCConstants.udpServiceType)
            
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "UDP")
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("ReceiverIOS (UDP): New connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, type: "UDP")
            }
            
            listener.start(queue: networkQueue)
            self.udpListener = listener
        } catch {
            LogManager.shared.log("ReceiverIOS (UDP): Error \(error)")
        }
    }
    
    private func handleListenerState(_ state: NWListener.State, type: String) {
        switch state {
        case .ready:
            let listener: NWListener? = {
                switch type {
                case "TCP": return self.tcpListener
                case "TCP-P2P": return self.tcpP2PListener
                default: return self.udpListener
                }
            }()
            if let port = listener?.port {
                LogManager.shared.log("ReceiverIOS (\(type)): Ready on port \(port)")
            } else {
                LogManager.shared.log("ReceiverIOS (\(type)): Ready")
            }
            // Only announce "waiting" while no session is active — the listener
            // also reports ready on restarts during a live session.
            if connectedClients.isEmpty {
                notifyState(.waiting, "Ready. Waiting for Sender...")
            }
        case .failed(let error):
            LogManager.shared.log("ReceiverIOS (\(type)): Failed \(error) — restarting...")
            if connectedClients.isEmpty {
                notifyState(.waiting, "Restarting listener...")
            }
            // Auto-restart the failed listener
            switch type {
            case "TCP":
                self.tcpListener?.cancel()
                self.tcpListener = nil
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.startTCP()
                }
            case "TCP-P2P":
                // Private build starts only this listener — it MUST come back after a
                // failure (Wi-Fi transition, AWDL teardown), or the iPad stays
                // undiscoverable until the app is relaunched.
                self.tcpP2PListener?.cancel()
                self.tcpP2PListener = nil
                LogManager.shared.log("ReceiverIOS (TCP-P2P): Listener stopped — restarting in 1s...")
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.startPrivateP2P()
                }
            default:
                self.udpListener?.cancel()
                self.udpListener = nil
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.startUDP()
                }
            }
        default:
            break
        }
    }
    
    /// A peer that connects but never completes pairing must not be able to sit
    /// there indefinitely, nor to accumulate half-open sessions.
    private static let handshakeTimeout: TimeInterval = 10
    private static let maxPendingHandshakes = 4
    private var pendingHandshakes = 0

    private func handleNewConnection(_ connection: NWConnection, type: String) {
        if pendingHandshakes >= Self.maxPendingHandshakes {
            LogManager.shared.log("ReceiverIOS: Refusing \(type) connection — \(pendingHandshakes) handshakes already pending")
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                LogManager.shared.log("ReceiverIOS: \(type) Connection ready")
                self.notifyState(.connecting, "Authenticating...")

                self.pendingHandshakes += 1
                var settled = false
                let settle: () -> Bool = {
                    if settled { return false }
                    settled = true
                    self.pendingHandshakes = max(0, self.pendingHandshakes - 1)
                    return true
                }

                self.networkQueue.asyncAfter(deadline: .now() + Self.handshakeTimeout) {
                    guard settle() else { return }
                    LogManager.shared.log("ReceiverIOS: Pairing timed out after \(Int(Self.handshakeTimeout))s — closing connection")
                    self.notifyState(.waiting, "Pairing timed out")
                    connection.cancel()
                }

                self.performPairingHandshake(on: connection) { [weak self] result in
                    guard let self = self else { return }
                    guard settle() else { return }
                    switch result {
                    case .success(let sessionKey):
                        let connectionId = ObjectIdentifier(connection)
                        self.connectionSessionKeys[connectionId] = sessionKey

                        if !self.connectedClients.contains(where: { $0 === connection }) {
                            self.connectedClients.append(connection)
                        }

                        self.lastDataReceived = Date()
                        self.lastVideoReceived = Date()
                        self.notifyState(.connected, "Connected")

                        if type == "UDP" {
                            self.receiveUDP(on: connection)
                        } else {
                            self.receiveTCP(on: connection)
                        }
                    case .failure(let error):
                        LogManager.shared.log("ReceiverIOS: Pairing failed: \(error.localizedDescription)")
                        self.notifyState(.waiting, "Pairing failed — check that both devices use the same code")
                        connection.cancel()
                    }
                }
            case .failed(let error):
                LogManager.shared.log("ReceiverIOS: Connection failed \(error)")
                self.removeConnection(connection)
            case .cancelled:
                self.removeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }
    
    private func removeConnection(_ connection: NWConnection) {
        let wasConnected = connectedClients.contains { $0 === connection }
        if let index = connectedClients.firstIndex(where: { $0 === connection }) {
            connectedClients.remove(at: index)
        }
        connectionFormat.removeValue(forKey: ObjectIdentifier(connection))
        connectionSessionKeys.removeValue(forKey: ObjectIdentifier(connection))

        if wasConnected && connectedClients.isEmpty {
            audioPlayer?.stop()
            // Start the next session from a clean decoder. Reusing the previous
            // session's SPS/PPS and decompression session showed artifacts until
            // the next GOP after every reconnect.
            videoDecoder?.reset()
            if pendingLossNotification {
                pendingLossNotification = false
                notifyState(.connectionLost, "Connection lost")
            } else {
                notifyState(.disconnected, "Device disconnected")
            }
        }
    }

    private func loadPairingSecret() -> Data? {
        do {
            return try pairingSecretStore.loadSecret()
        } catch {
            LogManager.shared.log("ReceiverIOS: Unable to load pairing secret")
            return nil
        }
    }

    private func sendLengthPrefixedData(_ data: Data, on connection: NWConnection, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !data.isEmpty else {
            completion(.failure(PairingAuthError.invalidEnvelope))
            return
        }

        var packet = Data()
        var length = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &length, count: 4))
        packet.append(data)

        connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        })
    }

    private func receiveLengthPrefixedData(on connection: NWConnection, completion: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { content, _, _, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let content, content.count == 4 else {
                completion(.failure(PairingAuthError.invalidEnvelope))
                return
            }

            let rawLength = content.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            let bodyLength: Int
            do {
                bodyLength = try StreamFraming.validateBodyLength(rawLength, limit: StreamFraming.maxHandshakeFrameBytes)
            } catch {
                completion(.failure(PairingAuthError.invalidEnvelope))
                return
            }

            connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, _, _, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let body, body.count == bodyLength else {
                    completion(.failure(PairingAuthError.invalidEnvelope))
                    return
                }
                completion(.success(body))
            }
        }
    }

    private func sendCodable<T: Encodable>(_ value: T, on connection: NWConnection, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let data = try JSONEncoder().encode(value)
            sendLengthPrefixedData(data, on: connection, completion: completion)
        } catch {
            completion(.failure(error))
        }
    }

    private func receiveCodable<T: Decodable>(_ type: T.Type, on connection: NWConnection, completion: @escaping (Result<T, Error>) -> Void) {
        receiveLengthPrefixedData(on: connection) { result in
            switch result {
            case .success(let data):
                do {
                    completion(.success(try JSONDecoder().decode(T.self, from: data)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func performPairingHandshake(on connection: NWConnection, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let secret = loadPairingSecret() else {
            completion(.failure(PairingAuthError.invalidProof))
            return
        }

        receiveCodable(SenderHello.self, on: connection) { [weak self] helloResult in
            guard let self = self else { return }
            switch helloResult {
            case .success(let hello):
                guard hello.version == PrivateBetterCastConstants.protocolVersion else {
                    completion(.failure(PairingAuthError.invalidProof))
                    return
                }

                let receiverNonce = PairingAuthenticator.randomNonce()
                let receiverHello = ReceiverHello(
                    receiverNonce: receiverNonce,
                    receiverProof: PairingAuthenticator.receiverProof(
                        secret: secret,
                        senderNonce: hello.senderNonce,
                        receiverNonce: receiverNonce
                    )
                )

                self.sendCodable(receiverHello, on: connection) { [weak self] sendResult in
                    guard let self = self else { return }
                    if case .failure(let error) = sendResult {
                        completion(.failure(error))
                        return
                    }

                    self.receiveCodable(SenderProof.self, on: connection) { proofResult in
                        switch proofResult {
                        case .success(let proof):
                            guard PairingAuthenticator.verifySenderProof(
                                proof.senderProof,
                                secret: secret,
                                senderNonce: hello.senderNonce,
                                receiverNonce: receiverNonce
                            ) else {
                                completion(.failure(PairingAuthError.invalidProof))
                                return
                            }

                            completion(.success(PairingAuthenticator.deriveSessionKey(
                                secret: secret,
                                senderNonce: hello.senderNonce,
                                receiverNonce: receiverNonce
                            )))
                        case .failure(let error):
                            completion(.failure(error))
                        }
                    }
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    // Per-connection framing format: nil = not yet detected, true = type-byte (desktop), false = legacy (Swift/Android)
    private var connectionFormat: [ObjectIdentifier: Bool] = [:]

    private func receiveTCP(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("ReceiverIOS (TCP): Error \(error)")
                self?.removeConnection(connection)
                return
            }

            if let content = content, content.count == 4 {
                let rawLength = content.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

                // The sender is authenticated, but the length it sends is still
                // untrusted input: an unbounded value here asked the socket for up
                // to ~4 GiB and stalled the receiver under memory pressure.
                let bodyLength: Int
                do {
                    bodyLength = try StreamFraming.validateBodyLength(rawLength, limit: StreamFraming.maxMediaFrameBytes)
                } catch {
                    LogManager.shared.log("ReceiverIOS (TCP): Rejected frame length \(rawLength) (\(error)) — closing connection")
                    self?.removeConnection(connection)
                    return
                }

                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, bodyContext, isComplete, error in
                    if let error = error {
                        LogManager.shared.log("ReceiverIOS (TCP): Body error \(error)")
                        self?.removeConnection(connection)
                        return
                    }

                    if let body = body, body.count == bodyLength {
                        self?.handleReceivedBody(body, connection: connection)
                        self?.receiveTCP(on: connection)
                    } else if isComplete || body != nil {
                        // A body shorter than its header promised means the stream
                        // ended mid-frame; decoding it would feed the decoder a
                        // partial access unit.
                        if let body, body.count != bodyLength {
                            LogManager.shared.log("ReceiverIOS (TCP): Frame truncated (expected \(bodyLength), got \(body.count))")
                        }
                        self?.removeConnection(connection)
                    } else {
                        self?.receiveTCP(on: connection)
                    }
                }
            } else if isComplete {
                self?.removeConnection(connection)
            } else {
                self?.receiveTCP(on: connection)
            }
        }
    }

    private func handleReceivedBody(_ body: Data, connection: NWConnection) {
        lastDataReceived = Date()
        let connId = ObjectIdentifier(connection)
        let firstByte = body[body.startIndex]

        // Auto-detect framing on first frame
        if connectionFormat[connId] == nil {
            if firstByte == 0x01 || firstByte == 0x02 || firstByte == 0x03 {
                connectionFormat[connId] = true
                LogManager.shared.log("ReceiverIOS: Detected type-byte framing (desktop sender)")
            } else {
                connectionFormat[connId] = false
                LogManager.shared.log("ReceiverIOS: Detected legacy framing (Swift/Android sender)")
            }
        }

        if connectionFormat[connId] == true {
            // Type-byte framing: [0x01=video | 0x02=audio][payload]
            let payload = body.dropFirst(1)
            if firstByte == 0x01 {
                lastVideoReceived = Date()
                videoDecoder?.decode(data: payload)
            } else if firstByte == 0x02 {
                audioPlayer?.decode(aacData: payload)
            } else if firstByte == 0x03 {
                LogManager.shared.log("ReceiverIOS: Sender stopped sharing")
                removeConnection(connection)
            }
        } else {
            // Legacy framing: raw video data (with 8-byte PTS prefix handled by decoder)
            lastVideoReceived = Date()
            videoDecoder?.decode(data: body)
        }
    }
    
    private func receiveUDP(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, contentContext, isComplete, error in
            if error != nil { return }
            if let content = content, !content.isEmpty {
                 self?.handleUDPPacket(content)
            }
            self?.receiveUDP(on: connection)
        }
    }
    
    private func handleUDPPacket(_ data: Data) {
        guard data.count > 8 else { return }
        
        let header = data.prefix(8)
        let payload = data.dropFirst(8)
        
        let frameID = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        let chunkID = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
        let totalChunks = header.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).bigEndian }
        
        udpLock.lock()
        defer { udpLock.unlock() }
        
        if lastDecodedFrameId == 0 { lastDecodedFrameId = frameID &- 1 }
        
        if udpBuffer[frameID] == nil {
            udpBuffer[frameID] = (total: Int(totalChunks), chunks: [:], time: Date())
        }
        
        udpBuffer[frameID]?.chunks[chunkID] = payload
        
        if let entry = udpBuffer[frameID], entry.chunks.count == entry.total {
            
            // Gap Detection
            let diff = Int(frameID) - Int(lastDecodedFrameId)
            if diff > 1 && diff < 1000 {
                 // Throttle to 2.0s
                 if Date().timeIntervalSince(lastKeyframeRequest) > 2.0 {
                     LogManager.shared.log("ReceiverIOS: Gap Detected. Requesting IDR.")
                     sendInputEvent(InputEvent(type: .command, keyCode: 999))
                     lastKeyframeRequest = Date()
                 }
            }
            
            lastDecodedFrameId = frameID
            
            let sortedChunks = entry.chunks.sorted { $0.key < $1.key }
            var fullData = Data()
            for (_, chunkData) in sortedChunks {
                fullData.append(chunkData)
            }
            
            self.videoDecoder?.decode(data: fullData)
            udpBuffer.removeValue(forKey: frameID)
            
            // Aggressive cleanup to prevent memory buildup on iOS
            udpPacketsReceived += 1
            if udpPacketsReceived % 30 == 0 || udpBuffer.count > 10 {
                 for (key, val) in udpBuffer {
                    if val.time.timeIntervalSinceNow < -0.5 {
                        udpBuffer.removeValue(forKey: key)
                    }
                }
            }
        }
    }
    
    private func startHeartbeat() {
        LogManager.shared.log("ReceiverIOS: Starting heartbeat timer (0.5s interval)")
        DispatchQueue.main.async { [weak self] in
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.sendHeartbeat()
                self?.checkStreamHealth()
            }
            // Allow coalescing so a busy main thread doesn't starve heartbeats outright,
            // and keep firing during UI tracking (scrolling/gesture interaction).
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self?.heartbeatTimer = timer
        }
    }

    private func sendHeartbeat() {
        // Don't log each beat (2 lines/sec drowns the log) and don't bother
        // building envelopes when no sender is connected.
        guard !connectedClients.isEmpty else { return }
        // While backgrounded, stay silent on purpose: the sender is holding the
        // session in its background grace period, and any authenticated message
        // (including a heartbeat) would end that grace early. Heartbeats resume
        // automatically when the app becomes active again.
        if UIApplication.shared.applicationState == .background { return }
        let heartbeat = InputEvent(
            type: .command,
            keyCode: 888 // Special code for heartbeat
        )
        sendInputEvent(heartbeat)
    }

    /// Tell the sender we are entering the background (command 555) so it holds
    /// the session and virtual display in a grace period instead of tearing down
    /// after the 15s heartbeat timeout. Sent inside a short background task from
    /// ViewController so it flushes before iPadOS suspends the app.
    func sendBackgroundHold(completion: (() -> Void)? = nil) {
        guard !connectedClients.isEmpty else {
            completion?()
            return
        }
        LogManager.shared.log("ReceiverIOS: Sending background hold notice (keyCode 555)")
        sendInputEvent(InputEvent(type: .command, keyCode: 555))
        // sendInputEvent hops to networkQueue; signal completion after the send
        // has been enqueued and given a moment to flush.
        networkQueue.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion?()
            }
        }
    }

    /// Watchdog: a live sender streams frames continuously, so prolonged
    /// silence while we are in the foreground means the connection died
    /// without a clean close. Surface "connection lost" and drop the dead
    /// connections instead of freezing on the last frame forever.
    private func checkStreamHealth() {
        guard !connectedClients.isEmpty else { return }
        // Backgrounded: the sender pauses the stream during its grace period,
        // so silence is expected. The clock is reset on foreground return.
        guard UIApplication.shared.applicationState == .active else { return }
        // Judge on video liveness, not on "any bytes arrived". Audio keeps
        // flowing on its own connection while the picture is frozen.
        guard Date().timeIntervalSince(lastVideoReceived) > streamSilenceTimeout else { return }

        LogManager.shared.log("ReceiverIOS: No video for \(Int(streamSilenceTimeout))s — declaring connection lost")
        pendingLossNotification = true
        let stale = connectedClients
        networkQueue.async {
            for connection in stale {
                connection.cancel()
            }
        }
        // Reset so we don't re-trigger every tick while cancels propagate.
        lastDataReceived = Date()
        lastVideoReceived = Date()
    }

    /// Request a keyframe (command 999) from the sender, throttled to one request
    /// per 2 seconds. Used for decode-error recovery on the TCP path.
    func requestKeyframeThrottled(reason: String) {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 2.0 else { return }
        lastKeyframeRequest = Date()
        LogManager.shared.log("ReceiverIOS: Requesting keyframe (\(reason))")
        sendInputEvent(InputEvent(type: .command, keyCode: 999))
    }
    
    func sendInputEvent(_ event: InputEvent) {
        guard let payload = try? JSONEncoder().encode(event) else { return }

        networkQueue.async { [weak self] in
            guard let self = self else { return }
            for connection in self.connectedClients {
                guard let sessionKey = self.connectionSessionKeys[ObjectIdentifier(connection)] else {
                    LogManager.shared.log("ReceiverIOS: Refusing to send input before pairing auth")
                    continue
                }

                self.inputSequence &+= 1
                let envelope = AuthenticatedEnvelope.seal(
                    sequence: self.inputSequence,
                    payload: payload,
                    sessionKey: sessionKey
                )
                guard let data = try? JSONEncoder().encode(envelope) else { continue }

                var packet = Data()
                var length32 = UInt32(data.count).bigEndian
                packet.append(Data(bytes: &length32, count: 4))
                packet.append(data)

                connection.send(content: packet, completion: .contentProcessed { _ in })
            }
        }
    }
}

// Conformance to VideoDecoderDelegate
extension NetworkListenerIOS: VideoDecoderDelegate {
    func didDecode(sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async {
            self.videoRenderer?.enqueue(sampleBuffer)
        }
    }

    func didFailToDecodeFrame(status: OSStatus) {
        // Broken reference chain (e.g. sender dropped a P-frame under WiFi
        // backpressure). Ask for a fresh keyframe instead of waiting out the GOP.
        requestKeyframeThrottled(reason: "decode error \(status)")
    }
}
#endif
