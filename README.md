# UpNext

A tiny macOS menu bar app that shows your next meeting: `Standup in 12m`, or `Standup · 8m left` while it's running.

- Click the menu bar item to see the rest of today's meetings. Meetings with a Zoom, Meet, Teams, Webex, Whereby or Around link get a 🎥 and open the call when clicked; other meetings open in Calendar.
- Skips all-day events and meetings you declined.
- Reads every calendar in macOS Calendar. To include Google Calendar, add your account under System Settings → Internet Accounts.

## Build

Needs the Xcode command line tools (`swiftc`).

```sh
./build.sh                       # builds and installs ~/Applications/UpNext.app
open ~/Applications/UpNext.app   # click Allow when macOS asks for calendar access
```

It adds itself to Login Items on first launch; turn it off there if you don't want it.

Self-test: `swiftc main.swift -o /tmp/upnext && /tmp/upnext --selftest`
