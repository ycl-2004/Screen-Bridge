#if canImport(UIKit)
import Foundation
import UIKit
import Network
import CoreMedia
import BetterCastShared

private final class ReceiverTransfer<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Single source of truth for the receiver's connection state.
/// The status text is derived alongside it for display.
enum ReceiverState {
    case pairingRequired // no secret; listener intentionally stopped
    case waiting        // listening, no sender connected
    case connecting     // sender connected, pairing/authenticating
    case connected      // streaming session active
    case connectionLost // stream went silent without a clean disconnect (watchdog)
    case disconnected   // sender ended the session cleanly
}

@MainActor
protocol NetworkListenerDelegate: AnyObject {
    func networkListener(_ listener: NetworkListenerIOS, didUpdate state: ReceiverState, statusText: String)
    func networkListener(_ listener: NetworkListenerIOS, didReceiveInput event: InputEvent) // If we were receiving input
}

final class NetworkListenerIOS: @unchecked Sendable {
    weak var delegate: NetworkListenerDelegate?

    /// The only listener this build runs. Declared with peer-to-peer enabled,
    /// which still accepts connections over ordinary interfaces as well.
    private var tcpP2PListener: NWListener?

    /// One logical receiver session owns one media/control connection and may
    /// attach one auxiliary audio connection. Auxiliary transport state must
    /// never drive the global receiver UI.
    private var mainConnection: NWConnection?
    private var audioConnection: NWConnection?
    private var activeSessionID: UUID?
    private var connectionSessionKeys: [ObjectIdentifier: Data] = [:]
    private let pairingSecretStore: PairingSecretStoring = KeychainPairingSecretStore()
    
    // Dependencies
    weak var videoDecoder: VideoDecoder?
    weak var videoRenderer: VideoRendererIOS?
    private var audioPlayer: AudioPlayerIOS?
    
    private let networkQueue = DispatchQueue(label: "com.bettercast.network.ios", qos: .userInteractive)
    
    private var lastKeyframeRequest = Date.distantPast
    
    // Heartbeat
    private var heartbeatTimer: Timer?
    private var inputSequence: UInt64 = 0

    // Transport, decoder, and renderer health are deliberately independent.
    // A static desktop may produce no new video frame, so an explicit media
    // heartbeat proves that the sender pipeline is alive without pretending a
    // byte was successfully decoded or rendered.
    private var lastDataReceived = Date()
    private var sessionStartedAt = Date()
    private var lastMediaHeartbeat = Date()
    private var lastVideoAccessUnitReceived = Date.distantPast
    private var lastVideoDecoded = Date.distantPast
    private var lastVideoRendered = Date.distantPast
    private var hasDecodedFrame = false
    private var hasRenderedFrame = false
    /// Deduplicates the "not authenticated yet" log emitted by the 0.5s heartbeat.
    private var hasLoggedUnauthenticatedSend = false
    private let streamSilenceTimeout: TimeInterval = 8.0
    private var pendingLossNotification = false

    private var isStarted = false
    private var privateListenerRetryAttempt = 0
    private var privateListenerRestartWork: DispatchWorkItem?
    private var useDynamicPortForNextListener = false
    private var activeListenerUsesDynamicPort = false
    private static let preferredPortNumber: UInt16 = 51820

    private let capabilitiesLock = NSLock()
    private var receiverCapabilities: ReceiverCapabilities?

    init() {}

    func setup(decoder: VideoDecoder, renderer: VideoRendererIOS) {
        self.videoDecoder = decoder
        self.videoRenderer = renderer
        self.audioPlayer = AudioPlayerIOS()
        decoder.delegate = self
    }

    func start() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            // Idempotent: saving the pairing code repeatedly must not stack
            // listeners (duplicate Bonjour records confuse the sender's first
            // dial) or heartbeat timers.
            guard !self.isStarted else {
                LogManager.shared.log("ReceiverIOS: start() ignored — already running")
                return
            }
            self.isStarted = true
            self.startPrivateP2P()
            self.startHeartbeat()
        }
    }

    func updateReceiverCapabilities(pixelWidth: Int, pixelHeight: Int) {
        let capabilities = ReceiverCapabilities(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        capabilitiesLock.lock()
        receiverCapabilities = capabilities.isValid ? capabilities : nil
        capabilitiesLock.unlock()
    }

    private func currentReceiverCapabilities() -> ReceiverCapabilities? {
        capabilitiesLock.lock()
        defer { capabilitiesLock.unlock() }
        return receiverCapabilities
    }

    /// Revoke the complete logical session and stop accepting new connections.
    /// The listener starts again only after the user stores a new pairing code.
    func resetPairingSession(completion: (@MainActor @Sendable () -> Void)? = nil) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.privateListenerRestartWork?.cancel()
            self.privateListenerRestartWork = nil
            self.privateListenerRetryAttempt = 0

            self.tcpP2PListener?.stateUpdateHandler = nil
            self.tcpP2PListener?.newConnectionHandler = nil
            self.tcpP2PListener?.serviceRegistrationUpdateHandler = nil
            self.tcpP2PListener?.cancel()
            self.tcpP2PListener = nil
            self.useDynamicPortForNextListener = false
            self.activeListenerUsesDynamicPort = false

            var connectionsByID = self.pendingConnections
            if let main = self.mainConnection {
                connectionsByID[ObjectIdentifier(main)] = main
            }
            if let audio = self.audioConnection {
                connectionsByID[ObjectIdentifier(audio)] = audio
            }

            self.pendingConnections.removeAll()
            self.mainConnection = nil
            self.audioConnection = nil
            self.activeSessionID = nil
            self.connectionSessionKeys.removeAll()
            self.connectionFormat.removeAll()
            self.inputSequence = 0
            self.pendingLossNotification = false
            self.lastDataReceived = Date()
            self.sessionStartedAt = Date()
            self.lastMediaHeartbeat = Date()
            self.lastVideoAccessUnitReceived = .distantPast
            self.lastVideoDecoded = .distantPast
            self.lastVideoRendered = .distantPast
            self.hasDecodedFrame = false
            self.hasRenderedFrame = false

            for connection in connectionsByID.values {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }

            self.audioPlayer?.stop()
            self.videoDecoder?.reset()
            self.notifyState(.pairingRequired, "Enter pairing code")
            DispatchQueue.main.async {
                self.heartbeatTimer?.invalidate()
                self.heartbeatTimer = nil
                completion?()
            }
        }
    }

    private func notifyState(_ state: ReceiverState, _ text: String) {
        DispatchQueue.main.async {
            self.delegate?.networkListener(self, didUpdate: state, statusText: text)
        }
    }

    /// Called by the view controller when the app returns to the foreground so
    /// the watchdog doesn't count suspended time as stream silence.
    func noteForegroundResumed() {
        networkQueue.async { [weak self] in
            self?.lastDataReceived = Date()
            self?.lastMediaHeartbeat = Date()
        }
    }

    private func startPrivateP2P() {
        guard isStarted else { return }
        guard tcpP2PListener == nil else { return }
        let deviceName = UserDefaults.standard.string(forKey: "customDeviceName")
            ?? ProcessInfo.processInfo.hostName

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let p2pParams = NWParameters(tls: nil, tcp: tcpOptions)
            p2pParams.includePeerToPeer = true
            p2pParams.serviceClass = .interactiveVideo

            let requestedPort: NWEndpoint.Port
            if useDynamicPortForNextListener {
                requestedPort = .any
                activeListenerUsesDynamicPort = true
            } else if let fixedPort = NWEndpoint.Port(rawValue: Self.preferredPortNumber) {
                requestedPort = fixedPort
                activeListenerUsesDynamicPort = false
            } else {
                LogManager.shared.log("ReceiverIOS: Invalid preferred port \(Self.preferredPortNumber); using a dynamic port")
                requestedPort = .any
                activeListenerUsesDynamicPort = true
            }

            let p2pListener = try NWListener(using: p2pParams, on: requestedPort)
            p2pListener.service = NWListener.Service(
                name: "\(deviceName) Private",
                type: PrivateBetterCastConstants.serviceType
            )

            p2pListener.serviceRegistrationUpdateHandler = { change in
                switch change {
                case .add(let endpoint):
                    LogManager.shared.log("ReceiverIOS: Bonjour service registered at \(endpoint)")
                case .remove(let endpoint):
                    LogManager.shared.log("ReceiverIOS: Bonjour service removed from \(endpoint)")
                @unknown default:
                    LogManager.shared.log("ReceiverIOS: Unknown Bonjour registration change")
                }
            }

            p2pListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "TCP-P2P")
            }
            p2pListener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("ReceiverIOS: New connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, type: "TCP")
            }

            p2pListener.start(queue: networkQueue)
            self.tcpP2PListener = p2pListener
        } catch {
            LogManager.shared.log("ReceiverIOS (TCP-P2P): Error \(error)")
            if !activeListenerUsesDynamicPort,
               let networkError = error as? NWError,
               case .posix(let code) = networkError,
               code == .EADDRINUSE {
                useDynamicPortForNextListener = true
                LogManager.shared.log(
                    "ReceiverIOS: Preferred port \(Self.preferredPortNumber) could not bind; retrying with a dynamic port"
                )
            }
            notifyState(.waiting, "Waiting for network access...")
            schedulePrivateListenerRestart(reason: error.localizedDescription)
        }
    }

    private func schedulePrivateListenerRestart(reason: String) {
        guard isStarted, privateListenerRestartWork == nil else { return }
        privateListenerRetryAttempt += 1
        let delay = min(pow(2.0, Double(privateListenerRetryAttempt - 1)), 8.0)
        LogManager.shared.log("ReceiverIOS (TCP-P2P): Retry in \(Int(delay))s after \(reason)")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.privateListenerRestartWork = nil
            guard self.isStarted, self.tcpP2PListener == nil else { return }
            self.startPrivateP2P()
        }
        privateListenerRestartWork = work
        networkQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    
    private func handleListenerState(_ state: NWListener.State, type: String) {
        switch state {
        case .ready:
            if type == "TCP-P2P" {
                privateListenerRetryAttempt = 0
                privateListenerRestartWork?.cancel()
                privateListenerRestartWork = nil
            }
            let listener = self.tcpP2PListener
            if let port = listener?.port {
                let strategy = activeListenerUsesDynamicPort ? "dynamic fallback" : "preferred fixed"
                LogManager.shared.log("ReceiverIOS (\(type)): Ready on port \(port) (\(strategy))")
            } else {
                LogManager.shared.log("ReceiverIOS (\(type)): Ready")
            }
            useDynamicPortForNextListener = false
            // Only announce "waiting" while no session is active — the listener
            // also reports ready on restarts during a live session.
            if mainConnection == nil {
                notifyState(.waiting, "Ready. Waiting for Sender...")
            }
        case .failed(let error):
            LogManager.shared.log("ReceiverIOS (\(type)): Failed \(error) — restarting...")
            if !activeListenerUsesDynamicPort,
               case .posix(let code) = error,
               code == .EADDRINUSE {
                useDynamicPortForNextListener = true
                LogManager.shared.log(
                    "ReceiverIOS: Preferred port \(Self.preferredPortNumber) is in use; next listener will use a dynamic port"
                )
            }
            if mainConnection == nil {
                notifyState(.waiting, "Restarting listener...")
            }
            // Auto-restart the failed listener
            // This build starts exactly one listener, and it MUST come back after
            // a failure (Wi-Fi transition, AWDL teardown) or the iPad stays
            // undiscoverable until the app is relaunched.
            self.tcpP2PListener?.stateUpdateHandler = nil
            self.tcpP2PListener?.newConnectionHandler = nil
            self.tcpP2PListener?.serviceRegistrationUpdateHandler = nil
            self.tcpP2PListener?.cancel()
            self.tcpP2PListener = nil
            schedulePrivateListenerRestart(reason: error.localizedDescription)
        default:
            break
        }
    }
    
    /// A peer that connects but never completes pairing must not be able to sit
    /// there indefinitely, nor to accumulate half-open sessions.
    private static let handshakeTimeout: TimeInterval = 10
    private static let maxPendingHandshakes = 4
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]

    private struct AuthenticatedReceiverConnection: Sendable {
        let role: StreamConnectionRole
        let sessionID: UUID
        let sessionKey: Data
    }

    private func handleNewConnection(_ connection: NWConnection, type: String) {
        let connectionID = ObjectIdentifier(connection)
        if pendingConnections.count >= Self.maxPendingHandshakes {
            LogManager.shared.log("ReceiverIOS: Refusing \(type) connection — \(pendingConnections.count) handshakes already pending")
            connection.cancel()
            return
        }
        // Reserve the slot before the transport becomes ready. Checking first
        // and incrementing later allowed simultaneous cold connections to all
        // pass a limit of four.
        pendingConnections[connectionID] = connection

        networkQueue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard self.pendingConnections.removeValue(forKey: connectionID) != nil else { return }
            LogManager.shared.log("ReceiverIOS: Pairing timed out after \(Int(Self.handshakeTimeout))s — closing connection")
            if self.mainConnection == nil {
                self.notifyState(.waiting, "Pairing timed out")
            }
            connection.cancel()
        }

        connection.viabilityUpdateHandler = { viable in
            LogManager.shared.log("ReceiverIOS: Connection viability changed to \(viable)")
        }
        connection.pathUpdateHandler = { path in
            LogManager.shared.log("ReceiverIOS: Path changed — \(Self.pathDescription(path))")
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                guard self.pendingConnections[connectionID] != nil else {
                    connection.cancel()
                    return
                }
                LogManager.shared.log("ReceiverIOS: \(type) connection ready — \(Self.pathDescription(connection.currentPath))")

                self.performPairingHandshake(on: connection) { [weak self] result in
                    guard let self = self else { return }
                    guard self.pendingConnections.removeValue(forKey: connectionID) != nil else { return }
                    switch result {
                    case .success(let authenticated):
                        guard self.activateAuthenticatedConnection(authenticated, connection: connection) else {
                            connection.cancel()
                            return
                        }

                        self.receiveTCP(on: connection)
                    case .failure(let error):
                        LogManager.shared.log("ReceiverIOS: Pairing failed: \(error.localizedDescription)")
                        if self.mainConnection == nil {
                            self.notifyState(.waiting, "Pairing failed — check that both devices use the same code")
                        }
                        connection.cancel()
                    }
                }
            case .failed(let error):
                LogManager.shared.log("ReceiverIOS: Connection failed — \(error); \(Self.pathDescription(connection.currentPath))")
                self.pendingConnections.removeValue(forKey: connectionID)
                self.removeConnection(connection)
            case .cancelled:
                LogManager.shared.log("ReceiverIOS: Connection cancelled; \(Self.pathDescription(connection.currentPath))")
                self.pendingConnections.removeValue(forKey: connectionID)
                self.removeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    private static func pathDescription(_ path: NWPath?) -> String {
        guard let path else { return "path unavailable" }
        var usedTypes: [String] = []
        if path.usesInterfaceType(.wiredEthernet) { usedTypes.append("wiredEthernet") }
        if path.usesInterfaceType(.wifi) { usedTypes.append("wifi-family") }
        if path.usesInterfaceType(.cellular) { usedTypes.append("cellular") }
        if path.usesInterfaceType(.loopback) { usedTypes.append("loopback") }
        if usedTypes.isEmpty { usedTypes.append("other") }
        let available = path.availableInterfaces
            .map { "\($0.name)[\($0.type)]" }
            .joined(separator: ", ")
        return "status=\(path.status), usedTypes=\(usedTypes.joined(separator: "+")), available=[\(available)]"
    }

    private func activateAuthenticatedConnection(
        _ authenticated: AuthenticatedReceiverConnection,
        connection: NWConnection
    ) -> Bool {
        let connectionID = ObjectIdentifier(connection)

        switch authenticated.role {
        case .mediaControl:
            let staleConnections = [mainConnection, audioConnection].compactMap { $0 }
            mainConnection = nil
            audioConnection = nil
            activeSessionID = nil
            for stale in staleConnections where stale !== connection {
                clearConnectionMetadata(stale)
                stale.stateUpdateHandler = nil
                stale.cancel()
            }

            mainConnection = connection
            activeSessionID = authenticated.sessionID
            connectionSessionKeys[connectionID] = authenticated.sessionKey
            lastDataReceived = Date()
            sessionStartedAt = Date()
            lastMediaHeartbeat = Date()
            lastVideoAccessUnitReceived = .distantPast
            lastVideoDecoded = .distantPast
            lastVideoRendered = .distantPast
            hasDecodedFrame = false
            hasRenderedFrame = false
            inputSequence = 0
            lastKeyframeRequest = .distantPast
            pendingLossNotification = false
            notifyState(.connected, "Connected")
            LogManager.shared.log("ReceiverIOS: Media session \(authenticated.sessionID) authenticated")
            return true

        case .audio:
            guard ReceiverSessionPolicy.mayAttach(
                role: authenticated.role,
                sessionID: authenticated.sessionID,
                activeSessionID: activeSessionID,
                hasMainTransport: mainConnection != nil
            ) else {
                LogManager.shared.log("ReceiverIOS: Refusing audio transport for inactive session \(authenticated.sessionID)")
                return false
            }
            if let previousAudio = audioConnection, previousAudio !== connection {
                clearConnectionMetadata(previousAudio)
                previousAudio.stateUpdateHandler = nil
                previousAudio.cancel()
            }
            audioConnection = connection
            connectionSessionKeys[connectionID] = authenticated.sessionKey
            LogManager.shared.log("ReceiverIOS: Audio transport joined session \(authenticated.sessionID)")
            return true
        }
    }

    private func clearConnectionMetadata(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        connectionFormat.removeValue(forKey: connectionID)
        connectionSessionKeys.removeValue(forKey: connectionID)
    }

    private func removeConnection(_ connection: NWConnection) {
        pendingConnections.removeValue(forKey: ObjectIdentifier(connection))
        clearConnectionMetadata(connection)

        if mainConnection === connection {
            let attachedAudio = audioConnection
            mainConnection = nil
            audioConnection = nil
            activeSessionID = nil
            if let attachedAudio {
                clearConnectionMetadata(attachedAudio)
                attachedAudio.stateUpdateHandler = nil
                attachedAudio.cancel()
            }
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
        } else if audioConnection === connection {
            audioConnection = nil
            audioPlayer?.stop()
            // The media/control transport remains authoritative. Protocol v3
            // never falls back to audio on it, so do not publish a disconnect;
            // the sender will reattach a fresh auxiliary connection.
            LogManager.shared.log("ReceiverIOS: Auxiliary audio transport disconnected; media session remains active")
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

    private func sendLengthPrefixedData(_ data: Data, on connection: NWConnection, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
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

    private func receiveLengthPrefixedData(on connection: NWConnection, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
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

    private func sendCodable<T: Encodable>(_ value: T, on connection: NWConnection, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        do {
            let data = try JSONEncoder().encode(value)
            sendLengthPrefixedData(data, on: connection, completion: completion)
        } catch {
            completion(.failure(error))
        }
    }

    private func receiveCodable<T: Decodable & Sendable>(_ type: T.Type, on connection: NWConnection, completion: @escaping @Sendable (Result<T, Error>) -> Void) {
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

    private func performPairingHandshake(
        on connection: NWConnection,
        completion: @escaping @Sendable (Result<AuthenticatedReceiverConnection, Error>) -> Void
    ) {
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

                let receiverSessionID: UUID
                switch hello.role {
                case .mediaControl:
                    guard hello.sessionID == nil else {
                        completion(.failure(PairingAuthError.invalidEnvelope))
                        return
                    }
                    receiverSessionID = UUID()
                case .audio:
                    guard let requestedSessionID = hello.sessionID,
                          requestedSessionID == self.activeSessionID,
                          self.mainConnection != nil else {
                        completion(.failure(PairingAuthError.invalidProof))
                        return
                    }
                    receiverSessionID = requestedSessionID
                }

                let receiverNonce = PairingAuthenticator.randomNonce()
                let receiverHello = ReceiverHello(
                    receiverNonce: receiverNonce,
                    receiverProof: PairingAuthenticator.receiverProof(
                        secret: secret,
                        senderNonce: hello.senderNonce,
                        receiverNonce: receiverNonce
                    ),
                    sessionID: receiverSessionID,
                    capabilities: self.currentReceiverCapabilities()
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

                            completion(.success(AuthenticatedReceiverConnection(
                                role: hello.role,
                                sessionID: receiverSessionID,
                                sessionKey: PairingAuthenticator.deriveSessionKey(
                                    secret: secret,
                                    senderNonce: hello.senderNonce,
                                    receiverNonce: receiverNonce
                                )
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
        // A replaced session can still have one receive callback already queued.
        // Never let that callback keep reading into the newly active session.
        guard mainConnection === connection || audioConnection === connection else {
            connection.cancel()
            return
        }
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
                let frameLimit = self?.audioConnection === connection
                    ? StreamFraming.maxAudioFrameBytes
                    : StreamFraming.maxMediaFrameBytes
                let bodyLength: Int
                do {
                    bodyLength = try StreamFraming.validateBodyLength(rawLength, limit: frameLimit)
                } catch {
                    LogManager.shared.log("ReceiverIOS (TCP): Rejected frame length \(rawLength) (\(error)) — closing connection")
                    self?.removeConnection(connection)
                    return
                }

                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { [weak self] body, bodyContext, isComplete, error in
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
        // Activation of a new media session revokes both transports from the
        // previous one. Ignore any body whose completion raced with that swap.
        guard mainConnection === connection || audioConnection === connection else { return }
        lastDataReceived = Date()
        let connId = ObjectIdentifier(connection)
        let firstByte = body[body.startIndex]

        if audioConnection === connection && firstByte != 0x02 {
            LogManager.shared.log("ReceiverIOS: Closing auxiliary transport that sent non-audio data")
            connection.cancel()
            return
        }

        // Auto-detect framing on first frame
        if connectionFormat[connId] == nil {
            if firstByte == 0x01 || firstByte == 0x02 || firstByte == 0x03 || firstByte == 0x04 {
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
                lastMediaHeartbeat = Date()
                lastVideoAccessUnitReceived = Date()
                videoDecoder?.decode(data: payload)
            } else if firstByte == 0x02 {
                do {
                    audioPlayer?.decode(packet: try FramedAudioPacket.decode(Data(payload)))
                } catch {
                    LogManager.shared.log("ReceiverIOS: Rejected malformed audio packet: \(error)")
                }
            } else if firstByte == 0x03 {
                LogManager.shared.log("ReceiverIOS: Sender stopped sharing")
                removeConnection(connection)
            } else if firstByte == 0x04 {
                lastMediaHeartbeat = Date()
            }
        } else {
            // Legacy framing: raw video data (with 8-byte PTS prefix handled by decoder)
            lastMediaHeartbeat = Date()
            lastVideoAccessUnitReceived = Date()
            videoDecoder?.decode(data: body)
        }
    }
    
    private func startHeartbeat() {
        LogManager.shared.log("ReceiverIOS: Starting heartbeat timer (0.5s interval)")
        DispatchQueue.main.async { [weak self] in
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sendHeartbeat()
                    self?.checkStreamHealth()
                }
            }
            // Allow coalescing so a busy main thread doesn't starve heartbeats outright,
            // and keep firing during UI tracking (scrolling/gesture interaction).
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self?.heartbeatTimer = timer
        }
    }

    @MainActor
    private func sendHeartbeat() {
        // Don't log each beat (2 lines/sec drowns the log) and don't bother
        // building envelopes when no sender is connected; sendInputEvent checks
        // that on the network queue that owns the connection.
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
    func sendBackgroundHold(completion: (@MainActor @Sendable () -> Void)? = nil) {
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

    /// Evaluate transport, decode, and renderer health independently. A static
    /// screen is healthy when the explicit media heartbeat continues even if
    /// ScreenCaptureKit has no changed frame to send.
    @MainActor
    private func checkStreamHealth() {
        let appIsActive = UIApplication.shared.applicationState == .active
        networkQueue.async { [weak self] in
            self?.evaluateStreamHealth(appIsActive: appIsActive)
        }
    }

    private func evaluateStreamHealth(appIsActive: Bool) {
        guard mainConnection != nil else { return }
        // Backgrounded: the sender pauses the stream during its grace period,
        // so silence is expected. The clock is reset on foreground return.
        guard appIsActive else { return }

        let now = Date()
        let snapshot = MediaLivenessSnapshot(
            sessionStartedAt: sessionStartedAt,
            lastMediaHeartbeat: lastMediaHeartbeat,
            lastVideoAccessUnitReceived: lastVideoAccessUnitReceived,
            lastVideoDecoded: lastVideoDecoded,
            lastVideoRendered: lastVideoRendered,
            hasDecodedFrame: hasDecodedFrame,
            hasRenderedFrame: hasRenderedFrame
        )
        guard let failure = MediaLivenessEvaluator.failure(
            for: snapshot,
            now: now,
            timeout: streamSilenceTimeout
        ) else { return }
        LogManager.shared.log("ReceiverIOS: Stream unhealthy (\(failure.rawValue)) — declaring connection lost")
        pendingLossNotification = true
        let stale = [mainConnection, audioConnection].compactMap { $0 }
        for connection in stale {
            connection.cancel()
        }
        // Reset so we don't re-trigger every tick while cancels propagate.
        lastDataReceived = now
        lastMediaHeartbeat = now
    }

    /// Request a keyframe (command 999) from the sender, throttled to one request
    /// per 2 seconds. Used for decode-error recovery on the TCP path.
    func requestKeyframeThrottled(reason: String) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastKeyframeRequest) > 2.0 else { return }
            self.lastKeyframeRequest = Date()
            LogManager.shared.log("ReceiverIOS: Requesting keyframe (\(reason))")
            self.sendInputEventOnNetworkQueue(InputEvent(type: .command, keyCode: 999))
        }
    }
    
    func sendInputEvent(_ event: InputEvent) {
        networkQueue.async { [weak self] in
            self?.sendInputEventOnNetworkQueue(event)
        }
    }

    private func sendInputEventOnNetworkQueue(_ event: InputEvent) {
        guard let payload = try? JSONEncoder().encode(event) else { return }
        guard let connection = mainConnection,
              let sessionKey = connectionSessionKeys[ObjectIdentifier(connection)] else {
            // The heartbeat keeps firing while unpaired, so logging every
            // refusal buried the rest of the log under two lines per second.
            // Report the transition once and stay quiet until it changes.
            if !hasLoggedUnauthenticatedSend {
                hasLoggedUnauthenticatedSend = true
                LogManager.shared.log("ReceiverIOS: Refusing to send input before media session auth")
            }
            return
        }
        hasLoggedUnauthenticatedSend = false

        inputSequence &+= 1
        let envelope = AuthenticatedEnvelope.seal(
            sequence: inputSequence,
            payload: payload,
            sessionKey: sessionKey
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }

        var packet = Data()
        var length32 = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &length32, count: 4))
        packet.append(data)

        connection.send(content: packet, completion: .contentProcessed { _ in })
    }
}

// Conformance to VideoDecoderDelegate
extension NetworkListenerIOS: VideoDecoderDelegate {
    func didDecode(sampleBuffer: CMSampleBuffer) {
        networkQueue.async { [weak self] in
            self?.hasDecodedFrame = true
            self?.lastVideoDecoded = Date()
        }
        let transferredSample = ReceiverTransfer(sampleBuffer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.videoRenderer?.enqueue(transferredSample.value) == true {
                self.networkQueue.async { [weak self] in
                    self?.hasRenderedFrame = true
                    self?.lastVideoRendered = Date()
                }
            }
        }
    }

    func didFailToDecodeFrame(status: OSStatus) {
        // Broken reference chain (e.g. sender dropped a P-frame under WiFi
        // backpressure). Ask for a fresh keyframe instead of waiting out the GOP.
        requestKeyframeThrottled(reason: "decode error \(status)")
    }
}
#endif
