#if canImport(UIKit)
import UIKit
import AVFoundation

// @UIApplicationMain removed -> handled in main.swift
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LogManager.shared.log("AppDelegate: launching on iOS \(UIDevice.current.systemVersion) (\(UIDevice.current.model))")

        // Required: configure audio session before AVSampleBufferDisplayLayer works on iOS.
        // Without this, FigApplicationStateMonitor throws errors and frames don't render.
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
            LogManager.shared.log("AppDelegate: audio session configured")
        } catch {
            LogManager.shared.log("AppDelegate: audio session setup failed — \(error)")
        }

        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// Owns the single iPad UI window. Keeping window creation in the scene
/// lifecycle gives the receiver the correct screen and window context under
/// Stage Manager, Split View, and future scene-based UIKit behavior.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ViewController()
        self.window = window
        window.makeKeyAndVisible()
    }
}
#endif
