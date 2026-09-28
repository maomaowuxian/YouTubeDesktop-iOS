import UIKit
import AVFAudio

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback)
        try? audio.setActive(true)

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ViewController()
        window.makeKeyAndVisible()
        self.window = window
        print("[PoC] launched; AVAudioSession=playback")
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) { print("[PoC] didEnterBackground") }
    func applicationWillEnterForeground(_ application: UIApplication) { print("[PoC] willEnterForeground") }
    func applicationDidBecomeActive(_ application: UIApplication) { print("[PoC] didBecomeActive") }
}
