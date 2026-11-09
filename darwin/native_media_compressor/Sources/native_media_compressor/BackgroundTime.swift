import Foundation

#if os(iOS)
  import UIKit
#endif

/// Keeps an iOS app running after the user leaves it, until `end` or until
/// the time the system grants runs out. macOS does not suspend apps, so there
/// it does nothing. Main thread only, as UIApplication requires.
final class BackgroundTime {
  #if os(iOS)
    private var task = UIBackgroundTaskIdentifier.invalid
  #endif

  /// `onExpiration` runs on the main thread when the time runs out; the app
  /// is suspended right after it, so it must only ask the work to stop.
  init(name: String, onExpiration: @escaping () -> Void) {
    #if os(iOS)
      task = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
        onExpiration()
        end()
      }
    #endif
  }

  func end() {
    #if os(iOS)
      guard task != .invalid else { return }
      UIApplication.shared.endBackgroundTask(task)
      task = .invalid
    #endif
  }
}
