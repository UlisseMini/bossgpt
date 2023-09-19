import SwiftUI
import Foundation
import OpenAI
import UserNotifications
import UserNotificationsUI

func getActiveWindow() -> [String: Any]? {
    if let frontmostApp = NSWorkspace.shared.frontmostApplication {
        let frontmostAppPID = frontmostApp.processIdentifier

        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as! [[String: Any]]

        for window in windowListInfo {
            if let ownerPID = window[kCGWindowOwnerPID as String] as? Int, ownerPID == frontmostAppPID {
                return window
            }
        }
    }
    return nil
}

func requestScreenRecordingPermission() {
    let screenBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let _ = CGWindowListCreateImage(screenBounds, .optionOnScreenBelowWindow, kCGNullWindowID, .bestResolution)
}

let getTitle = { (window: [String: Any]) -> String in
    return window["kCGWindowName"] as? String ?? "No window"
}
let getApp = { (window: [String: Any]) -> String in
    return window["kCGWindowOwnerName"] as? String ?? "No app"
}

let showWindow = { (window: [String: Any]) -> String in
    return "\(getApp(window)): \(getTitle(window))"
}

func loop(chatText: String) async {
    while true {
        let activeWindow = getActiveWindow()
        if activeWindow != nil {
            print(showWindow(activeWindow!))
        }
        await Task.sleep(1 * 1_000_000_000)
    }
}


func centerWindow(window: NSWindow) {
    let screen = window.screen ?? NSScreen.main!
    let screenRect = screen.visibleFrame
    let windowRect = window.frame

    let x = (screenRect.width - windowRect.width) / 2
    let y = (screenRect.height - windowRect.height) / 2

    window.setFrameOrigin(NSPoint(x: x + screenRect.minX, y: y + screenRect.minY))
}


func showNotification(title: String, body: String) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
        print("Permission granted: \(granted)")
        guard granted else { return }

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "chat_msg_click"

        // Create trigger and request
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "someID", content: content, trigger: trigger)

        // Schedule the notification
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling notification: \(error)")
            }
        }
    }
}


// MVP Psudocode:
// - Move window to center and hide. perhaps add opacity.
// - Notification every so often with msg from ai bot
//   - should only notify if they've been on the same window-concept for a while
// - Clicking notification opens chat window
// - Chat window is 1-1 with your AI. notifications for window-changes are paused
//   while you chat.


let systemPrompt = """
You are a productivity assistant. Every few minutes you will be asked to evaluate what the user is doing,
If the user is doing something they said they didn't want to do, you should ask them why they are doing it,
and nicely try to motivate them to work. Otherwise you should simply reply with "Great work!" and nothing else.

Try to understand the user's preferences and motivations, they might have a good reason to add an exception.
""".trimmingCharacters(in: .whitespaces)


struct ContentView: View {
    @State private var activeWindow: [String: Any]? = nil
    @State private var openAI = OpenAI(apiToken: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!)
    @State private var chatText = "Loading chat text..."

    var body: some View {
        VStack {
            Text((activeWindow != nil ? showWindow(activeWindow!) : "No window"))
            .onAppear {
                requestScreenRecordingPermission()
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    activeWindow = getActiveWindow()
                }
            }
            .font(.system(size: 20))
            Text(chatText)
            .onAppear {
                Task {
                    // has possible race condition but who the fuck cares
                    while NSApp.windows.isEmpty {
                        await try Task.sleep(nanoseconds: 100 * 1_000_000)
                    }
                    let window = NSApp.windows[0]
                    centerWindow(window: window)
                    // window.miniaturize(nil)
                    // NSApp.hide(nil)
                }


                // TODO: Make sure this is only spawned once.
                Task {
                    await try Task.sleep(nanoseconds: 1 * 1_000_000_000)
                    while true {
                        if activeWindow == nil {
                            print("activeWindow is null or unchanged")
                            continue;
                        }

                        let query = ChatQuery(
                            model: "gpt-3.5-turbo",
                            messages: [
                                Chat(role: .system, content: systemPrompt),
                                Chat(role: .user, content: "I'd like to be coding right now."),
                                Chat(role: .user, content: "The user is on a window titled: \(showWindow(activeWindow!)))")
                            ],
                            maxTokens: 32
                        )

                        chatText = ""
                        for try await result in openAI.chatsStream(query: query) {
                            chatText += result.choices[0].delta.content ?? ""
                        }
                        if !chatText.starts(with: "Great work!") {
                            showNotification(title: "BossGPT", body: chatText)
                        }
                        print("chatText: \(chatText)")

                        await try Task.sleep(nanoseconds: 30 * 1_000_000_000)
                    }
                }
            }
            Button("Test notification") {
                showNotification(title: "title", body: "body")
            }
        }
        .frame(width: 200, height: 100)
        .padding()
    }

}


class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("foreground notification")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {

        print(response)
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            print("Default action!")
        }
        if response.actionIdentifier == "CLICK_ACTION" {
            print("They clicked our special button!")
        }
        completionHandler()
    }
}



@main
struct bossgptApp: App {
    init() {
        // Register delegate to handle notification actions
        UNUserNotificationCenter.current().delegate = NotificationDelegate()

        // Create click action category
        let clickAction = UNNotificationAction(identifier: "CLICK_ACTION", title: "Click Me", options: [])
        let category = UNNotificationCategory(identifier: "chat_msg_click", actions: [clickAction], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

