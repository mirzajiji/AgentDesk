# Calendar sync and compact upcoming-event UI

Status: planned design. Source: [final architecture](final-architecture.txt), section 159.
<!-- Source sections: 159 -->

Calendar is a small productivity integration, not the main engineering dashboard. Use a provider abstraction with Apple Calendar/EventKit, Google Calendar and Microsoft Outlook/Microsoft 365 as priorities, using supported native/authentication flows and protected credentials. Providers can be enabled/disabled independently.

## Scope and privacy

Support a global personal calendar and optional explicit workspace/project associations. Association may use selected calendars, reviewed rules or manual assignment; it must not move confidential event content between companies automatically.

By default calendar data is used only for UI/scheduling. Do not inject event descriptions or attendees into Codex prompts. Agent access requires explicitly requested/authorized scheduling context and the appropriate calendar permission. Example permissions: list/title/time allowed, descriptions and create/edit requiring approval, deletion denied. Later writes must use normal policy and exact approval handling.

## Compact widget and day view

Show the nearest relevant event's title, start time and countdown, or “No upcoming events,” in a small toolbar/header/sidebar/menu-bar location. Respect selected calendar filters. Open a daily hourly timeline on selection, with previous/today/next navigation, current-time indicator, event duration, gaps and readable overlapping events.

Event details can show times, calendar, organizer/attendees, description, location, meeting link and recurrence where available. Allow join/open-in-calendar/copy-link when supported. Validate meeting URLs; opening a link should not execute arbitrary local schemes or commands supplied in an event.

Implementation should define timezone, daylight-saving, all-day, recurring and cancelled-event behavior. These are proposed edge cases to test rather than additional provider guarantees. Use actual event data and wall-clock updates for countdowns, not generated schedule estimates.

## Sync and optional surfaces

Refresh on launch, provider change signals where supported, reasonable periodic refresh and relevant edits. Cache permitted metadata with configurable retention; indicate stale/offline data and last successful sync. Disable/disconnect must stop refresh and apply the configured cache policy.

Menu-bar details/join and meeting reminders are optional to avoid duplicating native notifications. iPhone may use an appropriate native calendar permission directly; do not unnecessarily route personal calendar secrets through the Mac server. Future workflow scheduling hints must not automatically cancel or alter runs because a meeting exists.

Acceptance covers a real provider connection, today/upcoming events, compact nearest-event widget/title/time/countdown, daily timeline/current-time line, multiple and overlapping events, details/meeting URLs, visibility filters, disable/disconnect, no automatic agent disclosure, permission enforcement and offline cached display. Add timezone/filter/recurrence/privacy regression fixtures alongside UI tests.
