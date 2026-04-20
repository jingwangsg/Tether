import Cocoa
import FlutterMacOS
import UserNotifications

final class TerminalDesktopNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
  static let shared = TerminalDesktopNotificationCenter()

  func installDelegate() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func shouldDeliverDesktopNotification(
    appIsActive: Bool,
    windowIsKey: Bool,
    surfaceIsFocused: Bool
  ) -> Bool {
    !(appIsActive && windowIsKey && surfaceIsFocused)
  }

  func schedule(sessionId: String, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.userInfo = ["sessionId": sessionId]
    let request = UNNotificationRequest(
      identifier: "tether.agent.\(sessionId)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let sessionId = response.notification.request.content.userInfo["sessionId"] as? String {
      NotificationCenter.default.post(
        name: .terminalDesktopNotificationActivated,
        object: nil,
        userInfo: ["sessionId": sessionId]
      )
    }
    completionHandler()
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    TerminalDesktopNotificationCenter.shared.installDelegate()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
