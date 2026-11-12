import AppKit
import EventKit
import ServiceManagement
import UserNotifications

// Pure helpers (covered by --selftest).
func meetingURL(_ texts: [String?]) -> URL? {
    let pattern = #"https://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|around\.co)[^\s<>"]*"#
    for case let text? in texts {
        if let r = text.range(of: pattern, options: .regularExpression) { return URL(string: String(text[r])) }
    }
    return nil
}

func dur(_ s: TimeInterval) -> String {
    let m = Int((s / 60).rounded(.up))
    return m < 60 ? "\(m)m" : "\(m / 60)h\(m % 60 == 0 ? "" : " \(m % 60)m")"
}

func label(title: String, start: Date, end: Date, now: Date) -> String {
    let t = title.count > 30 ? title.prefix(29) + "…" : title
    return start <= now
        ? "\(t) · \(dur(end.timeIntervalSince(now))) left"
        : "\(t) in \(dur(start.timeIntervalSince(now))) (\(dur(end.timeIntervalSince(start))))"
}

if CommandLine.arguments.contains("--selftest") {
    let now = Date(timeIntervalSince1970: 0)
    assert(label(title: "Standup", start: now + 600, end: now + 1200, now: now) == "Standup in 10m (10m)")
    assert(label(title: "Standup", start: now - 60, end: now + 90, now: now) == "Standup · 2m left")
    assert(label(title: "1:1", start: now + 5400, end: now + 9000, now: now) == "1:1 in 1h 30m (1h)")
    assert(meetingURL([nil, "Join: https://meet.google.com/abc-defg-hij\nthanks"])?.absoluteString == "https://meet.google.com/abc-defg-hij")
    assert(meetingURL(["https://example.com/doc"]) == nil)
    print("selftest ok"); exit(0)
}

final class App: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = EKEventStore()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "UpNext")
        item.button?.imagePosition = .imageLeading
        // First launch only, so turning it off in Login Items sticks.
        if !UserDefaults.standard.bool(forKey: "registeredLoginItem") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "registeredLoginItem")
            } catch { NSLog("UpNext: login item registration failed: \(error)") }
        }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                if !granted { self.item.button?.title = " No calendar access" }
                self.refresh()
            }
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "meeting", actions: [UNNotificationAction(identifier: "join", title: "Join", options: .foreground)], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .EKEventStoreChanged, object: store)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func upcoming(from start: Date, to end: Date) -> [EKEvent] {
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > start && !$0.isDeclined }
            .sorted { $0.startDate < $1.startDate }
    }

    @objc func refresh() {
        let now = Date()
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let events = upcoming(from: now, to: tomorrow)
        let tomorrowEvents = upcoming(from: tomorrow, to: cal.date(byAdding: .day, value: 1, to: tomorrow)!)
        // Prefer a meeting that's about to start over one already running.
        let next = events.first { $0.startDate > now && $0.startDate.timeIntervalSince(now) < 600 } ?? events.first
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            item.button?.title = next.map { " " + label(title: $0.title ?? "Busy", start: $0.startDate, end: $0.endDate, now: now) } ?? " No more meetings"
        }

        scheduleReminders(events + tomorrowEvents, now: now)

        let menu = NSMenu()
        let fmt = DateFormatter(); fmt.timeStyle = .short
        func addEvents(_ events: [EKEvent]) { for e in events {
            let mi = NSMenuItem(title: "\(fmt.string(from: e.startDate))  \(e.title ?? "Busy") (\(dur(e.endDate.timeIntervalSince(e.startDate))))", action: #selector(open(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = e
            let color = e.calendar.color ?? .gray
            mi.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
                color.setFill(); NSBezierPath(ovalIn: r).fill(); return true
            }
            if meetingURL([e.url?.absoluteString, e.location, e.notes]) != nil { mi.title += "  🎥" }
            menu.addItem(mi)
        } }
        addEvents(events)
        if events.isEmpty { menu.addItem(withTitle: "Nothing left today", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Tomorrow"))
        addEvents(tomorrowEvents)
        if tomorrowEvents.isEmpty { menu.addItem(withTitle: "Nothing tomorrow", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(forceRefresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    // Asks Google/iCloud to sync now; new events then arrive via EKEventStoreChanged.
    @objc func forceRefresh() {
        store.refreshSourcesIfNecessary()
        refresh()
    }

    @objc func open(_ sender: NSMenuItem) {
        guard let e = sender.representedObject as? EKEvent else { return }
        NSWorkspace.shared.open(link(for: e))
    }

    func link(for e: EKEvent) -> URL {
        meetingURL([e.url?.absoluteString, e.location, e.notes])
            ?? URL(string: "ical://ekevent/\(e.calendarItemExternalIdentifier ?? "")")!
    }

    // Rebuilt on every refresh so moved or cancelled meetings never leave a stale reminder.
    func scheduleReminders(_ events: [EKEvent], now: Date) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for e in events where e.startDate.timeIntervalSince(now) > 60 {
            let c = UNMutableNotificationContent()
            c.title = e.title ?? "Busy"
            c.body = "Starts in 1 minute"
            c.sound = .default
            c.userInfo = ["url": link(for: e).absoluteString]
            if meetingURL([e.url?.absoluteString, e.location, e.notes]) != nil { c.categoryIdentifier = "meeting" }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: e.startDate.timeIntervalSince(now) - 60, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(e.eventIdentifier ?? "")@\(e.startDate.timeIntervalSince1970)", content: c, trigger: trigger))
        }
    }

    // Show banners even though UpNext counts as the active app.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // Clicking the banner or Join opens the call (or the event in Calendar).
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        if r.actionIdentifier != UNNotificationDismissActionIdentifier,
           let s = r.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
        done()
    }
}

extension EKEvent {
    var isDeclined: Bool { attendees?.first { $0.isCurrentUser }?.participantStatus == .declined }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
