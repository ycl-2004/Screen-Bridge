#if canImport(UIKit)
import UIKit
import Network
import BetterCastShared

class ViewController: UIViewController, NetworkListenerDelegate {

    private var renderer: VideoRendererViewIOS!
    private var settingsOverlay: UIView!

    private var videoDecoder: VideoDecoder?
    private var networkListener: NetworkListenerIOS?

    // Onboarding
    private var onboardingView: UIView!
    private var statusLabel: UILabel!
    private var pulseView: UIView!
    private var deviceNameField: UITextField!
    private var pairingCodeField: UITextField!
    private var isConnected = false
    private let pairingSecretStore: PairingSecretStoring = KeychainPairingSecretStore()

    /// Kept so the onboarding column can move clear of the software keyboard.
    private var onboardingCenterY: NSLayoutConstraint!
    private static let settingsButtonHiddenKey = "settingsButtonHidden"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // 1. Setup Renderer
        renderer = VideoRendererViewIOS(frame: view.bounds)
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(renderer)

        // 2. Setup Onboarding Screen
        setupOnboarding()

        // 3. Setup Settings Button & Overlay
        setupSettingsButton()
        setupSettingsOverlay()
        setupShowSettingsGesture()

        // 4. Setup Core Logic
        let decoder = VideoDecoder()
        let listener = NetworkListenerIOS()

        self.videoDecoder = decoder
        self.networkListener = listener

        listener.delegate = self
        listener.setup(decoder: decoder, renderer: renderer)
        publishReceiverCapabilities()

        startListenerIfPaired()

        // Sleep is only prevented while actually showing a stream — see
        // `updateIdleTimer`. Holding it from launch kept the iPad awake on the
        // pairing screen and while merely waiting for a sender.
        updateIdleTimer(isStreaming: false)

        // Listen for orientation changes to update sender's virtual display
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        // Background/foreground transitions: while the app is backgrounded (app
        // switcher, swipe home) heartbeats are suspended, so the Mac will drop the
        // connection after its 15s heartbeat timeout. Log the transition so drops
        // are attributable, and resync on return.
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The scene/window relationship is authoritative only after the view is
        // onscreen. Republish in case the early handshake used the bounds-based
        // fallback during launch.
        publishReceiverCapabilities()
    }

    // Background grace: tell the sender we're backgrounding so it holds the
    // session (and the Mac virtual display) for its grace period instead of
    // tearing down on heartbeat timeout. A short background task keeps the app
    // alive long enough to flush the notice before iPadOS suspends us.
    private var backgroundNoticeTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundEnteredAt: Date?

    @objc private func appDidEnterBackground() {
        backgroundEnteredAt = Date()
        LogManager.shared.log("ViewController: App entered background — sending hold notice; sender grace period starts")

        endBackgroundNoticeTask() // Defensive: never stack tasks
        backgroundNoticeTask = UIApplication.shared.beginBackgroundTask(withName: "YCCast.BackgroundHoldNotice") { [weak self] in
            // Expiry handler — iPadOS is about to suspend us regardless.
            self?.endBackgroundNoticeTask()
        }

        networkListener?.sendBackgroundHold { [weak self] in
            self?.endBackgroundNoticeTask()
        }
    }

    private func endBackgroundNoticeTask() {
        guard backgroundNoticeTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundNoticeTask)
        backgroundNoticeTask = .invalid
    }

    @objc private func appWillEnterForeground() {
        endBackgroundNoticeTask()
        let awaySeconds = backgroundEnteredAt.map { Int(Date().timeIntervalSince($0)) }
        backgroundEnteredAt = nil
        LogManager.shared.log("ViewController: App returning to foreground after \(awaySeconds.map(String.init) ?? "?")s — resuming session (screen info + keyframe)")
        // Reset the stream watchdog so suspended time isn't counted as silence.
        networkListener?.noteForegroundResumed()
        // Heartbeats resume automatically once active; the first authenticated
        // message ends the sender's grace period. Refresh the sender's view of
        // our screen and recover the picture without restarting the pipeline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendScreenInfo()
            self?.networkListener?.requestKeyframeThrottled(reason: "returned to foreground")
        }
    }

    // MARK: - Screen Info (command 777)

    /// Send full iPad screen dimensions to the sender so the Mac virtual display
    /// remains stable even when iPadOS presents this app in a resizable window.
    func sendScreenInfo() {
        let screenSize = fullScreenPixelSizeForCurrentOrientation()
        let width = Int(screenSize.width)
        let height = Int(screenSize.height)
        networkListener?.updateReceiverCapabilities(pixelWidth: width, pixelHeight: height)
        LogManager.shared.log("ViewController: Sending screen info \(width)x\(height)")
        let event = InputEvent(type: .command, keyCode: 777, deltaX: Double(width), deltaY: Double(height))
        networkListener?.sendInputEvent(event)
    }

    private func publishReceiverCapabilities() {
        let screenSize = fullScreenPixelSizeForCurrentOrientation()
        networkListener?.updateReceiverCapabilities(
            pixelWidth: Int(screenSize.width),
            pixelHeight: Int(screenSize.height)
        )
    }

    /// The scene backing this receiver, usable before `view.window` is set.
    ///
    /// Capabilities are published from `viewDidLoad`, which runs while the root
    /// view controller is being installed and therefore before it has a window.
    /// Falling straight through to the bounds-based estimate there reported
    /// points instead of pixels, and the sender sized the Mac's virtual display
    /// from that wrong number.
    private func activeWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private func fullScreenPixelSizeForCurrentOrientation() -> CGSize {
        let nativeSize: CGSize
        if let screen = view.window?.windowScene?.screen ?? activeWindowScene()?.screen {
            nativeSize = screen.nativeBounds.size
        } else {
            let scale = max(traitCollection.displayScale, 1)
            nativeSize = CGSize(
                width: view.bounds.width * scale,
                height: view.bounds.height * scale
            )
        }
        let longEdge = max(nativeSize.width, nativeSize.height)
        let shortEdge = min(nativeSize.width, nativeSize.height)

        return isCurrentInterfaceLandscape
            ? CGSize(width: longEdge, height: shortEdge)
            : CGSize(width: shortEdge, height: longEdge)
    }

    private var isCurrentInterfaceLandscape: Bool {
        if let orientation = view.window?.windowScene?.interfaceOrientation
            ?? activeWindowScene()?.interfaceOrientation {
            return orientation.isLandscape
        }

        let deviceOrientation = UIDevice.current.orientation
        if deviceOrientation.isLandscape {
            return true
        }
        if deviceOrientation.isPortrait {
            return false
        }

        return view.bounds.width > view.bounds.height
    }

    @objc private func orientationChanged() {
        let orientation = UIDevice.current.orientation
        // Only respond to flat orientations that change the layout
        guard orientation == .portrait || orientation == .landscapeLeft || orientation == .landscapeRight || orientation == .portraitUpsideDown else { return }
        // Small delay to let UIKit update bounds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendScreenInfo()
        }
    }

    // MARK: - Onboarding

    private func setupOnboarding() {
        onboardingView = UIView()
        onboardingView.backgroundColor = .black
        onboardingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(onboardingView)

        NSLayoutConstraint.activate([
            onboardingView.topAnchor.constraint(equalTo: view.topAnchor),
            onboardingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            onboardingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            onboardingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // App icon
        let iconView = UIImageView()
        if let appIcon = UIImage(named: "AppIcon") {
            iconView.image = appIcon
        } else {
            // Fallback: use a system symbol
            let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .light)
            iconView.image = UIImage(systemName: "display.2", withConfiguration: config)
            iconView.tintColor = UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        }
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 22
        iconView.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // Title
        let titleLabel = UILabel()
        titleLabel.text = "Screen Bridge"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Subtitle
        let subtitleLabel = UILabel()
        subtitleLabel.text = "iPad Display Receiver · v1.1.0"
        subtitleLabel.textColor = UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        subtitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        subtitleLabel.textAlignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Device name field
        let nameContainer = UIView()
        nameContainer.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = UILabel()
        nameLabel.text = "Device Name"
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        deviceNameField = UITextField()
        let savedName = UserDefaults.standard.string(forKey: "customDeviceName")
        deviceNameField.text = savedName ?? UIDevice.current.name
        deviceNameField.textColor = .white
        deviceNameField.font = .systemFont(ofSize: 16, weight: .medium)
        deviceNameField.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        deviceNameField.layer.cornerRadius = 10
        deviceNameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 0))
        deviceNameField.leftViewMode = .always
        deviceNameField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 0))
        deviceNameField.rightViewMode = .always
        deviceNameField.returnKeyType = .done
        // 0.25 white on near-black fell well below the contrast needed to read a
        // hint you are being asked to act on.
        deviceNameField.attributedPlaceholder = NSAttributedString(
            string: "e.g. My iPad",
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.45)]
        )
        deviceNameField.addTarget(self, action: #selector(deviceNameChanged), for: .editingDidEnd)
        deviceNameField.addTarget(self, action: #selector(deviceNameReturnPressed), for: .editingDidEndOnExit)
        deviceNameField.translatesAutoresizingMaskIntoConstraints = false

        nameContainer.addSubview(nameLabel)
        nameContainer.addSubview(deviceNameField)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: nameContainer.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: nameContainer.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: nameContainer.trailingAnchor),

            deviceNameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            deviceNameField.leadingAnchor.constraint(equalTo: nameContainer.leadingAnchor),
            deviceNameField.trailingAnchor.constraint(equalTo: nameContainer.trailingAnchor),
            deviceNameField.heightAnchor.constraint(equalToConstant: 40),
            deviceNameField.bottomAnchor.constraint(equalTo: nameContainer.bottomAnchor),
        ])

        // Divider
        let divider = UIView()
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Instructions
        let instructionsLabel = UILabel()
        instructionsLabel.numberOfLines = 0
        instructionsLabel.textAlignment = .left
        instructionsLabel.translatesAutoresizingMaskIntoConstraints = false

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 10

        let bodyFont = UIFont.systemFont(ofSize: 15, weight: .regular)
        let boldFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let dimColor = UIColor.white.withAlphaComponent(0.55)
        let brightColor = UIColor.white.withAlphaComponent(0.9)

        let instructions = NSMutableAttributedString()

        let stepAttrs: [NSAttributedString.Key: Any] = [
            .font: boldFont,
            .foregroundColor: brightColor,
            .paragraphStyle: paragraphStyle
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: dimColor,
            .paragraphStyle: paragraphStyle
        ]

        instructions.append(NSAttributedString(string: "1. Pair with your Mac\n", attributes: stepAttrs))
        instructions.append(NSAttributedString(string: "Enter the same pairing code shown in Screen Bridge on your Mac.\n\n", attributes: bodyAttrs))

        instructions.append(NSAttributedString(string: "2. Select this iPad\n", attributes: stepAttrs))
        instructions.append(NSAttributedString(string: "Keep this app open, then connect from Screen Bridge on your Mac.", attributes: bodyAttrs))

        instructionsLabel.attributedText = instructions

        let pairingContainer = UIView()
        pairingContainer.translatesAutoresizingMaskIntoConstraints = false

        let pairingLabel = UILabel()
        pairingLabel.text = "Pairing Code"
        pairingLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        pairingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        pairingLabel.translatesAutoresizingMaskIntoConstraints = false

        pairingCodeField = UITextField()
        pairingCodeField.attributedPlaceholder = NSAttributedString(
            string: "Same code as your Mac",
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.45)]
        )
        pairingCodeField.textColor = .white
        pairingCodeField.font = .systemFont(ofSize: 16, weight: .medium)
        pairingCodeField.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        pairingCodeField.layer.cornerRadius = 10
        pairingCodeField.isSecureTextEntry = true
        pairingCodeField.autocapitalizationType = .none
        pairingCodeField.autocorrectionType = .no
        pairingCodeField.returnKeyType = .done
        pairingCodeField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 0))
        pairingCodeField.leftViewMode = .always
        pairingCodeField.addTarget(self, action: #selector(savePairingCode), for: .editingDidEndOnExit)
        pairingCodeField.translatesAutoresizingMaskIntoConstraints = false

        let savePairingButton = UIButton(type: .system)
        savePairingButton.setTitle("Save", for: .normal)
        savePairingButton.setTitleColor(.white, for: .normal)
        savePairingButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.55)
        savePairingButton.layer.cornerRadius = 10
        savePairingButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        savePairingButton.addTarget(self, action: #selector(savePairingCode), for: .touchUpInside)
        savePairingButton.translatesAutoresizingMaskIntoConstraints = false

        pairingContainer.addSubview(pairingLabel)
        pairingContainer.addSubview(pairingCodeField)
        pairingContainer.addSubview(savePairingButton)

        // Pulsing dot + status
        let statusRow = UIView()
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        pulseView = UIView()
        pulseView.backgroundColor = UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        pulseView.layer.cornerRadius = 5
        pulseView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = UILabel()
        statusLabel.text = "Initializing..."
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statusRow.addSubview(pulseView)
        statusRow.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            pulseView.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor),
            pulseView.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            pulseView.widthAnchor.constraint(equalToConstant: 10),
            pulseView.heightAnchor.constraint(equalToConstant: 10),

            statusLabel.leadingAnchor.constraint(equalTo: pulseView.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: statusRow.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Container stack
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        onboardingView.addSubview(contentView)

        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(nameContainer)
        contentView.addSubview(divider)
        contentView.addSubview(instructionsLabel)
        contentView.addSubview(pairingContainer)
        contentView.addSubview(statusRow)

        // The margins are minimums, not pins. Pinning both edges as required
        // constraints fully determined the width, so the max-width cap below
        // (previously .defaultHigh) was always the one broken — text ran the full
        // width of the screen, which is ~950pt on a 13" iPad.
        onboardingCenterY = contentView.centerYAnchor.constraint(equalTo: onboardingView.centerYAnchor, constant: -12)
        NSLayoutConstraint.activate([
            onboardingCenterY,
            contentView.centerXAnchor.constraint(equalTo: onboardingView.centerXAnchor),
            contentView.leadingAnchor.constraint(
                greaterThanOrEqualTo: onboardingView.safeAreaLayoutGuide.leadingAnchor, constant: 40),
            contentView.trailingAnchor.constraint(
                lessThanOrEqualTo: onboardingView.safeAreaLayoutGuide.trailingAnchor, constant: -40),
        ])

        // Cap the measure so body copy stays near a readable line length.
        let maxWidth = contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        maxWidth.priority = .required
        maxWidth.isActive = true

        // Take the full 420 when there is room, shrink on narrow devices.
        let preferredWidth = contentView.widthAnchor.constraint(equalToConstant: 420)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 76),
            iconView.heightAnchor.constraint(equalToConstant: 76),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            nameContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            nameContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            divider.topAnchor.constraint(equalTo: nameContainer.bottomAnchor, constant: 16),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            instructionsLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 18),
            instructionsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            instructionsLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            pairingContainer.topAnchor.constraint(equalTo: instructionsLabel.bottomAnchor, constant: 16),
            pairingContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pairingContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            pairingLabel.topAnchor.constraint(equalTo: pairingContainer.topAnchor),
            pairingLabel.leadingAnchor.constraint(equalTo: pairingContainer.leadingAnchor),
            pairingLabel.trailingAnchor.constraint(equalTo: pairingContainer.trailingAnchor),

            pairingCodeField.topAnchor.constraint(equalTo: pairingLabel.bottomAnchor, constant: 6),
            pairingCodeField.leadingAnchor.constraint(equalTo: pairingContainer.leadingAnchor),
            pairingCodeField.trailingAnchor.constraint(equalTo: savePairingButton.leadingAnchor, constant: -8),
            // 44pt is the minimum comfortable touch target.
            pairingCodeField.heightAnchor.constraint(equalToConstant: 44),

            savePairingButton.trailingAnchor.constraint(equalTo: pairingContainer.trailingAnchor),
            savePairingButton.centerYAnchor.constraint(equalTo: pairingCodeField.centerYAnchor),
            savePairingButton.widthAnchor.constraint(equalToConstant: 76),
            savePairingButton.heightAnchor.constraint(equalToConstant: 44),
            pairingCodeField.bottomAnchor.constraint(equalTo: pairingContainer.bottomAnchor),

            statusRow.topAnchor.constraint(equalTo: pairingContainer.bottomAnchor, constant: 16),
            statusRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Start pulse animation
        startPulseAnimation()
    }

    private func startListenerIfPaired() {
        do {
            if try pairingSecretStore.loadSecret() != nil {
                statusLabel?.text = "Ready · Waiting for Mac…"
                networkListener?.start()
            } else {
                statusLabel?.text = "Enter pairing code"
                pulseView?.backgroundColor = UIColor.systemOrange
            }
        } catch {
            statusLabel?.text = "Pairing unavailable"
            pulseView?.backgroundColor = UIColor.systemOrange
        }
    }

    private func startPulseAnimation() {
        // An indefinitely repeating animation is exactly what Reduce Motion asks
        // apps to drop.
        guard !UIAccessibility.isReduceMotionEnabled else {
            pulseView.layer.removeAllAnimations()
            pulseView.alpha = 1.0
            return
        }
        UIView.animate(withDuration: 1.2, delay: 0, options: [.repeat, .autoreverse, .curveEaseInOut]) {
            self.pulseView.alpha = 0.2
        }
    }

    private func dismissOnboarding() {
        guard !isConnected else { return }
        isConnected = true

        UIView.animate(withDuration: 0.5, delay: 0.3, options: .curveEaseOut) {
            self.onboardingView.alpha = 0
        } completion: { _ in
            self.onboardingView.isHidden = true
        }
    }

    private func showDisconnectedState(lost: Bool = false) {
        isConnected = false
        statusLabel.text = lost ? "Connection lost" : "Mac disconnected"
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        pulseView.layer.removeAllAnimations()
        pulseView.alpha = 1.0
        pulseView.backgroundColor = lost ? UIColor.systemRed : UIColor.systemOrange

        onboardingView.isHidden = false
        if onboardingView.alpha == 0 {
            UIView.animate(withDuration: 0.25) {
                self.onboardingView.alpha = 1
            }
        }
    }

    @objc private func savePairingCode() {
        let code = pairingCodeField.text ?? ""

        // Normalization strips whitespace and `-`, so inputs like "-" used to pass
        // the old non-empty check and end up as SHA256("") — the same fixed secret
        // on every install that did it.
        guard PairingAuthenticator.isAcceptableSecretInput(code) else {
            presentAlert(
                title: "Pairing Code Too Weak",
                message: "Use at least \(PairingAuthenticator.minimumSecretLength) letters or digits, and don't repeat a single character. Separators like spaces and dashes are ignored."
            )
            statusLabel.text = "Enter a longer pairing code"
            pulseView.backgroundColor = UIColor.systemOrange
            return
        }

        do {
            let secret = PairingAuthenticator.normalizedSecret(from: code)
            try pairingSecretStore.saveSecret(secret)
            pairingCodeField.text = ""
            pairingCodeField.resignFirstResponder()
            LogManager.shared.log("ViewController: Pairing code saved")
            startListenerIfPaired()
        } catch {
            statusLabel.text = "Pairing save failed"
            pulseView.backgroundColor = UIColor.systemOrange
            LogManager.shared.log("ViewController: Pairing save failed")
            presentAlert(
                title: "Couldn't Save Pairing Code",
                message: "The keychain refused the write. Try again, and restart the app if it keeps failing."
            )
        }
    }

    // MARK: - Alerts

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// Confirms an action the user cannot undo.
    private func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool,
        action: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: confirmTitle, style: isDestructive ? .destructive : .default) { _ in
            action()
        })
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func confirmClearPairingCode() {
        confirm(
            title: "Reset Pairing?",
            message: "This iPad will stop accepting connections until you enter the pairing code again.",
            confirmTitle: "Reset Pairing",
            isDestructive: true
        ) { [weak self] in
            self?.clearPairingCode()
        }
    }

    @objc private func confirmHideSettingsButton() {
        confirm(
            title: "Hide Settings Button?",
            message: "To bring it back, tap the screen with three fingers.",
            confirmTitle: "Hide",
            isDestructive: false
        ) { [weak self] in
            self?.hideSettingsButton()
        }
    }

    @objc private func clearPairingCode() {
        do {
            try pairingSecretStore.deleteSecret()
            LogManager.shared.log("ViewController: Pairing cleared")
            networkListener?.resetPairingSession { [weak self] in
                self?.showPairingRequiredState()
            }
        } catch {
            statusLabel.text = "Pairing clear failed"
            LogManager.shared.log("ViewController: Pairing clear failed")
        }
    }

    private func showPairingRequiredState() {
        isConnected = false
        updateIdleTimer(isStreaming: false)
        renderer.clear()
        statusLabel.text = "Enter pairing code"
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        pulseView.layer.removeAllAnimations()
        pulseView.alpha = 1.0
        pulseView.backgroundColor = UIColor.systemOrange
        onboardingView.isHidden = false
        onboardingView.alpha = 1.0
        view.bringSubviewToFront(onboardingView)
        view.bringSubviewToFront(settingsButtonBlur)
        view.bringSubviewToFront(settingsButton)
        pairingCodeField.text = ""
    }

    @objc private func deviceNameChanged() {
        let name = deviceNameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return }
        UserDefaults.standard.set(name, forKey: "customDeviceName")
        LogManager.shared.log("ViewController: Device name changed to '\(name)' — restart app to apply")
    }

    @objc private func deviceNameReturnPressed() {
        deviceNameField.resignFirstResponder()
    }

    // MARK: - Settings Button & Overlay

    private var settingsButton: UIButton!
    private var displayModeButton: UIButton!

    private var settingsButtonBlur: UIVisualEffectView!

    private func setupSettingsButton() {
        // Blur background for the settings button
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        settingsButtonBlur = UIVisualEffectView(effect: blurEffect)
        settingsButtonBlur.layer.cornerRadius = 22
        settingsButtonBlur.clipsToBounds = true
        settingsButtonBlur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsButtonBlur)

        settingsButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        settingsButton.setImage(UIImage(systemName: "gearshape.fill", withConfiguration: config), for: .normal)
        settingsButton.tintColor = UIColor.white.withAlphaComponent(0.9)
        settingsButton.accessibilityLabel = "Settings"
        settingsButton.addTarget(self, action: #selector(settingsButtonTapped), for: .touchUpInside)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButtonBlur.contentView.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            settingsButtonBlur.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            settingsButtonBlur.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            settingsButtonBlur.widthAnchor.constraint(equalToConstant: 44),
            settingsButtonBlur.heightAnchor.constraint(equalToConstant: 44),
        ])
        NSLayoutConstraint.activate([
            settingsButton.topAnchor.constraint(equalTo: settingsButtonBlur.contentView.topAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: settingsButtonBlur.contentView.bottomAnchor),
            settingsButton.leadingAnchor.constraint(equalTo: settingsButtonBlur.contentView.leadingAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: settingsButtonBlur.contentView.trailingAnchor),
        ])

        if UserDefaults.standard.bool(forKey: Self.settingsButtonHiddenKey) {
            settingsButtonBlur.isHidden = true
            settingsButtonBlur.alpha = 0
        }
    }

    // MARK: - Keyboard

    /// Lifts the onboarding column clear of the software keyboard.
    ///
    /// The column is vertically centred, so on iPad in landscape the keyboard
    /// covered the pairing code field — the one control a first-time user has to
    /// reach.
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            return
        }

        let keyboardTop = view.convert(endFrame, from: nil).minY
        let contentBottom = onboardingView.convert(pairingCodeField.frame, from: pairingCodeField.superview).maxY
        let overlap = contentBottom + 24 - keyboardTop

        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        onboardingCenterY.constant = overlap > 0 ? -12 - overlap : -12

        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration) {
            self.onboardingView.layoutIfNeeded()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        onboardingCenterY.constant = -12
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration) {
            self.onboardingView.layoutIfNeeded()
        }
    }

    @objc private func settingsButtonTapped() {
        toggleSettings()
    }

    private var settingsOverlayBlur: UIVisualEffectView!

    private func setupSettingsOverlay() {
        // Use blur effect instead of solid black
        let blurEffect = UIBlurEffect(style: .systemThinMaterialDark)
        settingsOverlayBlur = UIVisualEffectView(effect: blurEffect)
        settingsOverlayBlur.layer.cornerRadius = 16
        settingsOverlayBlur.clipsToBounds = true
        settingsOverlayBlur.isHidden = true
        settingsOverlayBlur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsOverlayBlur)

        // Keep settingsOverlay pointing to the blur view for hide/show logic
        settingsOverlay = settingsOverlayBlur

        let settingsTitleLabel = UILabel()
        settingsTitleLabel.text = "Screen Bridge v1.1.0"
        settingsTitleLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        settingsTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        settingsTitleLabel.textAlignment = .center

        // Display mode button
        displayModeButton = UIButton(type: .system)
        updateDisplayModeButtonTitle()
        displayModeButton.setTitleColor(.white, for: .normal)
        displayModeButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.5)
        displayModeButton.layer.cornerRadius = 10
        displayModeButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        displayModeButton.addTarget(self, action: #selector(toggleDisplayMode), for: .touchUpInside)
        displayModeButton.translatesAutoresizingMaskIntoConstraints = false

        // Hide button option
        let hideButtonButton = UIButton(type: .system)
        hideButtonButton.setTitle("Hide Settings Button", for: .normal)
        hideButtonButton.setTitleColor(.white, for: .normal)
        hideButtonButton.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.75)
        hideButtonButton.layer.cornerRadius = 10
        hideButtonButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        // Hiding removes the only visible way back into this panel, so the user
        // has to be told the recovery gesture before it happens.
        hideButtonButton.addTarget(self, action: #selector(confirmHideSettingsButton), for: .touchUpInside)
        hideButtonButton.translatesAutoresizingMaskIntoConstraints = false

        let resetPairingButton = UIButton(type: .system)
        resetPairingButton.setTitle("Reset Pairing…", for: .normal)
        resetPairingButton.setTitleColor(.white, for: .normal)
        resetPairingButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.75)
        resetPairingButton.layer.cornerRadius = 10
        resetPairingButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        // Confirm first: this deletes the stored secret and there is no undo.
        resetPairingButton.addTarget(self, action: #selector(confirmClearPairingCode), for: .touchUpInside)
        resetPairingButton.translatesAutoresizingMaskIntoConstraints = false

        let exportLogsButton = UIButton(type: .system)
        exportLogsButton.setTitle("Export Diagnostics", for: .normal)
        exportLogsButton.setTitleColor(.white, for: .normal)
        exportLogsButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.5)
        exportLogsButton.layer.cornerRadius = 10
        exportLogsButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        exportLogsButton.addTarget(self, action: #selector(exportDiagnostics), for: .touchUpInside)
        exportLogsButton.translatesAutoresizingMaskIntoConstraints = false

        // Close button
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.setTitleColor(UIColor.white.withAlphaComponent(0.6), for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        closeButton.addTarget(self, action: #selector(hideSettings), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            settingsTitleLabel,
            displayModeButton,
            exportLogsButton,
            resetPairingButton,
            hideButtonButton,
            closeButton,
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(14, after: settingsTitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        settingsOverlayBlur.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            settingsOverlayBlur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            settingsOverlayBlur.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            settingsOverlayBlur.widthAnchor.constraint(equalToConstant: 220),

            stack.topAnchor.constraint(equalTo: settingsOverlayBlur.contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: settingsOverlayBlur.contentView.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: settingsOverlayBlur.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: settingsOverlayBlur.contentView.trailingAnchor, constant: -20),

            settingsTitleLabel.heightAnchor.constraint(equalToConstant: 24),
            displayModeButton.heightAnchor.constraint(equalToConstant: 44),
            exportLogsButton.heightAnchor.constraint(equalToConstant: 44),
            resetPairingButton.heightAnchor.constraint(equalToConstant: 44),
            hideButtonButton.heightAnchor.constraint(equalToConstant: 44),
            // Close had only its intrinsic height (~20pt), below the touch target minimum.
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func setupShowSettingsGesture() {
        // Local-only convenience gesture. It must never compete with or delay
        // iPadOS system gestures — Screen Bridge is display-only and registers no
        // other recognizers.
        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(showSettingsButton))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.cancelsTouchesInView = false
        view.addGestureRecognizer(threeFingerTap)
    }

    @objc private func hideSettingsButton() {
        // Persisted so the choice survives a relaunch. Previously the button
        // silently came back, which made the setting look broken.
        UserDefaults.standard.set(true, forKey: Self.settingsButtonHiddenKey)
        settingsOverlay.isHidden = true
        UIView.animate(withDuration: 0.3) {
            self.settingsButtonBlur.alpha = 0
        } completion: { _ in
            self.settingsButtonBlur.isHidden = true
        }
    }

    @objc private func showSettingsButton() {
        UserDefaults.standard.set(false, forKey: Self.settingsButtonHiddenKey)
        settingsButtonBlur.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.settingsButtonBlur.alpha = 1
        }
    }

    private func toggleSettings() {
        let willShow = settingsOverlay.isHidden
        if willShow {
            settingsOverlay.isHidden = false
            settingsOverlay.alpha = 0
            UIView.animate(withDuration: 0.25) {
                self.settingsOverlay.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.2) {
                self.settingsOverlay.alpha = 0
            } completion: { _ in
                self.settingsOverlay.isHidden = true
            }
        }
    }

    @objc private func hideSettings() {
        UIView.animate(withDuration: 0.2) {
            self.settingsOverlay.alpha = 0
        } completion: { _ in
            self.settingsOverlay.isHidden = true
        }
    }

    @objc private func exportDiagnostics() {
        guard let logURL = LogManager.shared.exportURL() else {
            presentAlert(title: "No Diagnostics Yet", message: "Use Screen Bridge once, then try exporting again.")
            return
        }

        let activity = UIActivityViewController(activityItems: [logURL], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = settingsButton
            popover.sourceRect = settingsButton.bounds
        }
        present(activity, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func toggleDisplayMode() {
        renderer.isAspectFill.toggle()
        updateDisplayModeButtonTitle()
    }

    private func updateDisplayModeButtonTitle() {
        displayModeButton.setTitle(renderer.isAspectFill ? "Display: Fill Screen" : "Display: Fit Screen", for: .normal)
    }
    
    // MARK: - NetworkListenerDelegate
    
    /// Keeps the screen awake only while a stream is actually on it.
    private func updateIdleTimer(isStreaming: Bool) {
        UIApplication.shared.isIdleTimerDisabled = isStreaming
    }

    func networkListener(_ listener: NetworkListenerIOS, didUpdate state: ReceiverState, statusText: String) {
        statusLabel.text = statusText
        updateIdleTimer(isStreaming: state == .connected)

        switch state {
        case .pairingRequired:
            showPairingRequiredState()

        case .connected:
            // Stop pulse, show green dot, then dismiss onboarding
            pulseView.layer.removeAllAnimations()
            pulseView.alpha = 1.0
            pulseView.backgroundColor = UIColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0)
            statusLabel.textColor = UIColor.white.withAlphaComponent(0.8)
            dismissOnboarding()
            // Tell sender our screen dimensions so it can match our aspect ratio
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.sendScreenInfo()
            }

        case .connecting:
            pulseView.backgroundColor = UIColor.systemOrange
            if !isConnected { startPulseAnimation() }

        case .waiting:
            if !isConnected {
                pulseView.backgroundColor = UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
                startPulseAnimation()
            }

        case .disconnected, .connectionLost:
            // Never leave the last video frame on screen — replace it with the
            // explicit disconnected/lost UI immediately.
            renderer.clear()
            showDisconnectedState(lost: state == .connectionLost)
        }
    }
    
    func networkListener(_ listener: NetworkListenerIOS, didReceiveInput event: InputEvent) {
        // Receiver doesn't handle input from sender usually, but protocol demands conformance
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    @available(iOS 11.0, *)
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
}
#endif
