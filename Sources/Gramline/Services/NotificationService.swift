import AppKit
import DMCore
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    var onSelect: ((String) -> Void)?
    override init() { super.init(); UNUserNotificationCenter.current().delegate = self }
    func requestPermission() async -> Bool { (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false }
    func updateBadge(unreadCount: Int) {
        NSApp.dockTile.badgeLabel = UnreadBadge.label(for: unreadCount)
    }
    func clearAlerts() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    func deliver(_ message: Message, title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "New message" // Message contents stay private on the lock screen.
        content.sound = .default
        content.userInfo = ["threadID": message.threadID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: message.id, content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let thread = response.notification.request.content.userInfo["threadID"] as? String else { return }
        await MainActor.run { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil); onSelect?(thread) }
    }
}
