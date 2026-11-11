import AppKit
import EventKit
import ServiceManagement

// Pure helpers (covered by --selftest).
func meetingURL(_ texts: [String?]) -> URL? {
    let pattern = #"https://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|around\.co)[^\s<>"]*"#
    for case let text? in texts {
        if let r = text.range(of: pattern, options: .regularExpression) { return URL(string: String(text[r])) }
    }
    return nil
}

func label(title: String, start: Date, end: Date, now: Date) -> String {
    func dur(_ s: TimeInterval) -> String {
        let m = Int((s / 60).rounded(.up))
        return m < 60 ? "\(m)m" : "\(m / 60)h\(m % 60 == 0 ? "" : " \(m % 60)m")"
    }
    let t = title.count > 30 ? title.prefix(29) + "…" : title
    return start <= now ? "\(t) · \(dur(end.timeIntervalSince(now))) left" : "\(t) in \(dur(start.timeIntervalSince(now)))"
}

if CommandLine.arguments.contains("--selftest") {
    let now = Date(timeIntervalSince1970: 0)
    assert(label(title: "Standup", start: now + 600, end: now + 1200, now: now) == "Standup in 10m")
    assert(label(title: "Standup", start: now - 60, end: now + 90, now: now) == "Standup · 2m left")
    assert(label(title: "1:1", start: now + 5400, end: now + 9000, now: now) == "1:1 in 1h 30m")
    assert(meetingURL([nil, "Join: https://meet.google.com/abc-defg-hij\nthanks"])?.absoluteString == "https://meet.google.com/abc-defg-hij")
    assert(meetingURL(["https://example.com/doc"]) == nil)
    print("selftest ok"); exit(0)
}

final class App: NSObject, NSApplicationDelegate {
    let store = EKEventStore()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.title = "📅"
        // First launch only, so turning it off in Login Items sticks.
        if !UserDefaults.standard.bool(forKey: "registeredLoginItem") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "registeredLoginItem")
            } catch { NSLog("UpNext: login item registration failed: \(error)") }
        }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                if !granted { self.item.button?.title = "📅 no calendar access" }
                self.refresh()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .EKEventStoreChanged, object: store)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func upcoming(now: Date) -> [EKEvent] {
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        let pred = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && !$0.isDeclined }
            .sorted { $0.startDate < $1.startDate }
    }

    @objc func refresh() {
        let now = Date()
        let events = upcoming(now: now)
        // Prefer a meeting that's about to start over one already running.
        let next = events.first { $0.startDate > now && $0.startDate.timeIntervalSince(now) < 600 } ?? events.first
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            item.button?.title = next.map { label(title: $0.title ?? "Busy", start: $0.startDate, end: $0.endDate, now: now) } ?? "📅 No more meetings"
        }

        let menu = NSMenu()
        let fmt = DateFormatter(); fmt.timeStyle = .short
        for e in events {
            let mi = NSMenuItem(title: "\(fmt.string(from: e.startDate))  \(e.title ?? "Busy")", action: #selector(open(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = e
            if meetingURL([e.url?.absoluteString, e.location, e.notes]) != nil { mi.title += "  🎥" }
            menu.addItem(mi)
        }
        if events.isEmpty { menu.addItem(withTitle: "Nothing left today", action: nil, keyEquivalent: "") }
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
        let url = meetingURL([e.url?.absoluteString, e.location, e.notes])
            ?? URL(string: "ical://ekevent/\(e.calendarItemExternalIdentifier ?? "")")!
        NSWorkspace.shared.open(url)
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
