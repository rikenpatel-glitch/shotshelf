import Foundation
import UserNotifications
import AppKit

/// "Sorted into Receipts/Food" banners, with Move and Show buttons right on the notification.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private let category = "shotshelf.sorted"

    var onMove: ((String) -> Void)?
    var onShow: ((String) -> Void)?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notify") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notify"); if newValue { requestPermission() } }
    }

    func setUp() {
        center.delegate = self
        let move = UNNotificationAction(identifier: "move", title: "Move...", options: [.foreground])
        let show = UNNotificationAction(identifier: "show", title: "Show", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [move, show], intentIdentifiers: [])])
        if enabled { requestPermission() }
    }

    private func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func sorted(_ results: [SortResult], root: URL) {
        guard enabled, !results.isEmpty else { return }
        if results.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = "Sorted \(results.count) screenshots"
            content.body = Set(results.map(\.folder)).sorted().prefix(4).joined(separator: ", ")
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return
        }
        for r in results {
            let content = UNMutableNotificationContent()
            content.title = "Sorted into \(r.folder)"
            content.body = r.name
            content.categoryIdentifier = category
            content.userInfo = ["path": r.path]
            content.threadIdentifier = "sorted"
            // The banner shows a thumbnail; the system takes ownership of the copy.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            if let image = Vision2.image(root.appendingPathComponent(r.path)), Notifier.writeThumbnail(image, to: copy),
               let attachment = try? UNNotificationAttachment(identifier: "thumb", url: copy) {
                content.attachments = [attachment]
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func writeThumbnail(_ image: CGImage, to url: URL) -> Bool {
        let scale = min(1, 600 / CGFloat(max(image.width, image.height)))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: small)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["path"] as? String
        DispatchQueue.main.async {
            guard let path else { return }
            if response.actionIdentifier == "move" { self.onMove?(path) } else { self.onShow?(path) }
        }
        completionHandler()
    }
}
