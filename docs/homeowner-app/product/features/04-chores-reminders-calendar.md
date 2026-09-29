# 04 · Chores, Reminders and Calendar

**Priority:** P0 (appliance link and "Turn into project" P1; spare-stock prompt P2) · **Phase:** 2 (Tracking core)
**Sources:** merged plan §1 (#2), §3; founder decisions #2; HLD §4.6–4.7, ADR-05, ADR-13, ADR-18, R3–R5; LLD `chore`, `chore_completion`, `chore_calendar_link`, §9.

## Summary
**To-Dos are household chores** ("Do the dishes", "Fold laundry", "Change HVAC filter"), separate from improvements. Each chore has an optional repeat rule, assignee (housemate label), place (room, floor or whole house), and optional link to an appliance. Completing one logs it and schedules the next due date. Chores never carry cost and never enter Budget. Each chore can send a **local push reminder** and can be **added to a calendar** through EventKit (Apple Calendar, and Google calendars that are already added to the iPhone). No server.

## User stories
- As a **parent**, I want "Run dishwasher" to repeat daily and remind my kid at 8 pm so that I don't have to nag.
- As a **homeowner**, I want "Trash out" on Tuesdays and Fridays so that it matches pickup.
- As a **homeowner**, I want "Change furnace filter" 90 days after I last did it, linked to the furnace, so that I know the size and when it was last done.
- As a **Google Calendar user**, I want my chores in my Google calendar so that I see them next to everything else.
- As a **busy person**, I want to mark a chore done from the notification so that I don't have to open the app.
- As an **owner who found a problem during a chore** ("gutter cleaning found a leak"), I want to turn it into a project so that the repair is tracked with cost.
- As a **person away on vacation**, I want to pause a chore so that it stops reminding me.

## Functional requirements

### Chore record
- **FR-CHR-01** Fields: title (required, 1–120 chars), notes, place (room / this floor / whole house; defaults from "+"), assignee (housemate or none), repeat rule (none = one-off), start date (default today), time of day (optional; none = all-day), reminder on/off + offset (at time, 15 min, 1 h, 1 day before), calendar on/off + calendar, linked appliance (optional), paused flag.
- **FR-CHR-02** A chore is created from "+" (To-Do), the To-Dos room sheet, the Whole house chip, or a Thing's detail ("Add maintenance chore").
- **FR-CHR-03** One-off chores (no repeat) close when completed and disappear from the To-Dos view; they stay in history and search.

### Repeat rules
- **FR-CHR-10** Supported rules: **daily** (every N days, N ≥ 1), **weekly** (every N weeks), **every N days**, **monthly on day X** (1–31 or "last day"), per the merged plan.
- **FR-CHR-11** Extensions: weekly can pick specific weekdays (e.g. Tue + Fri); monthly takes an interval (every 12 months = yearly, e.g. detector batteries); every rule has an **anchor** — "on schedule" (default for daily, weekly, monthly) or "after completion" (default for every-N-days, e.g. "filter 90 days after last change"); optional end date. *Assumption pending founder confirmation (HLD §9-3).*
- **FR-CHR-12** Day 29–31 clamps to the last day of shorter months (the 31st → Feb 28/29).
- **FR-CHR-13** Due dates are **floating local dates** + time of day: "every Tuesday at 7 pm" stays at 7 pm local after a time zone or DST change.
- **FR-CHR-14** The form shows a plain-language preview and the next 3 due dates ("Every 90 days after done · next: Dec 28").

### Completing, skipping, rescheduling
- **FR-CHR-20** Complete from: the room sheet checkbox, the chore detail, the notification "Done" action, or a swipe action in lists. A success haptic plays (if system haptics are on).
- **FR-CHR-21** Completing logs a completion (date/time, done by — defaults to the assignee when completed in-app; unassigned from a notification, see PRD Q-5 — optional note/photo) and computes the next due date.
- **FR-CHR-22** **Missed occurrences collapse:** completing a daily chore that is 3 days overdue schedules the next occurrence after today; it does not create 3 overdue items. *Assumption pending founder confirmation (HLD §9-4).*
- **FR-CHR-23** **Skip** advances to the next occurrence without logging it as done (logged as "skipped" in history). *Assumption pending founder confirmation (HLD §9-4).*
- **FR-CHR-24** **Reschedule to…** sets the next due date manually without logging a completion.
- **FR-CHR-25** **Undo** is offered for 5 s after complete/skip (snackbar); undo deletes the completion and restores the previous due date.
- **FR-CHR-26** **Pause / Resume.** Paused chores don't show as due, don't remind, and their future calendar events are removed; resuming schedules from the next occurrence on or after today.
- **FR-CHR-27** History: the chore detail lists completions (newest first) with who and when, and the "last done" date is shown under the title.

### Links
- **FR-CHR-30** A chore can link to one Thing (e.g. "Change filter" → Furnace). The chore detail shows the thing's relevant spec (filter size, bulb base) and the last-done date.
- **FR-CHR-31** When a chore linked to a thing that has **spare stock** (an Inventory item linked to that thing, spec 06) is completed, ask "Used a spare 16x25x1? (3 left)"; Yes decrements quantity by 1; if it reaches the low threshold, it's flagged low and appears on the shopping list. *Assumption pending founder confirmation (HLD §9-20).*
- **FR-CHR-32** **Turn into project:** from a chore's menu, create a Future Project (status Idea) prefilled with the chore's place and a title "From: <chore title>", linked back to the chore. The chore itself is unchanged.

### Push reminders (local notifications)
- **FR-CHR-40** Reminders are local notifications scheduled on the phone; no server.
- **FR-CHR-41** Permission is requested only when the user first turns a reminder on, after an in-app pre-prompt ("Get a reminder when this chore is due?"). If denied, the toggle shows "Notifications are off for Home" with an Open Settings link; the chore still saves.
- **FR-CHR-42** Fire time = due date + time of day (all-day chores: **9:00 am** default, PRD Q-9) − reminder offset. Notification title: chore title; body: place and assignee ("Kitchen · Kid 1").
- **FR-CHR-43** Overdue chores get one "Overdue: <title>" reminder (today at the fire time if still ahead, else tomorrow).
- **FR-CHR-44** Actions: **Done** (completes in the background without opening the app), **In 1 hour** (snooze; max 2 active snoozes). Tapping the body opens the chore.
- **FR-CHR-45** Completing, editing, pausing or deleting a chore on any device removes stale pending/delivered reminders for it on that device within one replan (≤ 500 ms debounce + ≤ 150 ms plan).
- **FR-CHR-46** **Scheduling window:** up to 60 chore reminders over the next 14 days are kept scheduled; each chore gets its next reminder before any chore gets a second one; a background refresh tops them up. If some were dropped, a final notice fires: "Open Home to keep your reminders coming." *Assumption pending founder confirmation (HLD §9-8).*
- **FR-CHR-47** The app icon badge shows the number of chores due today plus overdue (the user can turn this off in Settings).
- **FR-CHR-48** Settings has reminder defaults: default time for all-day chores and default offset.

### Calendar events (EventKit)
- **FR-CHR-50** "Add to calendar" on a chore creates a calendar event that repeats when the chore repeats (series), or a single event for one-offs and "after completion" chores.
- **FR-CHR-51** Calendar permission is requested the first time the toggle is turned on. **Full access** is required, because write-only access can't update or delete events. *Assumption pending founder confirmation (HLD §9-6).* If denied, the toggle reverts with an explanation + Open Settings.
- **FR-CHR-52** **Calendar picker:** lists writable calendars grouped by account ("iCloud", "Gmail – you@…", "Exchange"). The first option is **"Create 'Home' calendar"** (in iCloud, or on-device if no iCloud calendar account). The last choice becomes the default for new chores.
- **FR-CHR-53** **Google:** Google calendars appear when the user's Google account is added in iPhone Settings › Calendar › Accounts. iOS generally can't create a new calendar inside a Google account, so Google users pick an existing Google calendar; the picker explains this and links to the iOS setting. *Assumption pending founder confirmation (HLD §9-7).* Direct Google sign-in is deferred.
- **FR-CHR-54** Event content: title = chore title; notes = chore notes + "Managed by Home"; a deep link opens the chore; all-day if the chore has no time; floating time zone; no calendar alarm by default (optional "Also alert from Calendar").
- **FR-CHR-55** **Edits carry over:** changing title, time, rule or notes updates **future** events only; past occurrences keep their old details. Changing the calendar moves future events to the new calendar.
- **FR-CHR-56** **Deletes carry over:** deleting or pausing a chore, or turning the toggle off, removes future events; **completing never deletes past occurrences**.
- **FR-CHR-57** For "after completion" chores, completing moves the future single event to the new due date, or (if it's in the past) leaves it as history and creates a new one.
- **FR-CHR-58** **One device manages a chore's events:** the device that turned the calendar on owns them; the user's other devices leave the calendar alone and show "Calendar events are managed on '<device nickname>'" with **Manage from this iPhone**. *Assumption pending founder confirmation (HLD §9-5).*
- **FR-CHR-59** **One-way:** the app is the master. If the user deletes the events in the Calendar app, the app turns the chore's calendar toggle off and shows "Removed from your calendar outside Home"; it never silently re-creates them. Time/title edits made in the Calendar app are not imported.

### To-Dos view specifics
- **FR-CHR-60** Room chip = count due in the next 7 days (today + 6), bold if any today; red edge + "!" if overdue; strip "N due this week · M overdue".
- **FR-CHR-61** A "My chores / Everyone" filter by housemate in the room sheet and the Whole house sheet.

## Acceptance criteria
- **AC-CHR-1** *Given* a weekly chore on Tue + Fri starting Tue Sep 29, *when* it's completed on Tue, *then* the next due date is Fri Oct 2.
- **AC-CHR-2** *Given* "Change filter" every 90 days after completion, due Sep 1, *when* completed Sep 29, *then* next due is Dec 28.
- **AC-CHR-3** *Given* a daily chore last due Sep 26 (3 days overdue), *when* completed on Sep 29, *then* one completion is logged and next due is Sep 30; no other overdue items remain.
- **AC-CHR-4** *Given* a monthly chore on the 31st, *then* the February occurrence is Feb 28 (Feb 29 in a leap year).
- **AC-CHR-5** *Given* a chore at 7 pm weekly and a DST change, *then* the reminder still fires at 7 pm local.
- **AC-CHR-6** *Given* notifications allowed and a chore reminder at 8 pm, *when* the user taps **Done** on the notification without opening the app, *then* the completion is logged and tomorrow's reminder is scheduled.
- **AC-CHR-7** *Given* 80 daily chores with reminders, *when* the app replans, *then* exactly 60 chore reminders are pending, every chore's next occurrence is included before any second occurrence, and a sentinel notice is scheduled before the first dropped reminder.
- **AC-CHR-8** *Given* the user's Google account is added in iOS Settings, *when* they turn on "Add to calendar", *then* their Google calendars appear under "Gmail – …" and choosing one creates a repeating event visible in Google Calendar on the web after Google syncs.
- **AC-CHR-9** *Given* a repeating chore with past and future events, *when* the chore's time changes from 7 pm to 8 pm, *then* future events move to 8 pm and past events stay at 7 pm.
- **AC-CHR-10** *Given* a repeating chore with calendar events, *when* the chore is deleted, *then* future events are removed and past events remain.
- **AC-CHR-11** *Given* the user deleted the event series in the Calendar app, *when* Home next reconciles, *then* the chore's calendar toggle is off and the "Removed from your calendar outside Home" note is shown, and no event is re-created.
- **AC-CHR-12** *Given* the calendar was turned on from iPhone A, *when* the chore is edited on iPhone B, *then* iPhone B does not write to the calendar, and iPhone A updates the event after sync.
- **AC-CHR-13** *Given* "Change filter" linked to the furnace with a spare-filter item of quantity 3, *when* the chore is completed and the user taps Yes, *then* quantity becomes 2.
- **AC-CHR-14** *Given* a chore "Clean gutters", *when* the user chooses "Turn into project", *then* a Future Project (Idea) exists in the same place, linked to the chore, and the chore's schedule is unchanged.
- **AC-CHR-15** *Given* notification permission was denied, *when* the user turns on a reminder, *then* the toggle shows "Notifications are off for Home" with an Open Settings link and the chore saves.
- **AC-CHR-16** *Given* a paused chore, *then* it doesn't count in chips, has no pending reminders, and has no future calendar events.

## Edge cases
- Completing the same occurrence on two devices while offline: both completions are kept; the next due date is computed from the latest.
- Changing a repeat rule after completions exist: history is kept; next due is recomputed from the new rule starting from today.
- End date passed: the series closes; the chore moves to history.
- Assignee deleted: the chore becomes unassigned.
- Linked thing deleted: the link is cleared; the chore stays.
- Completion-anchored chore never completed: stays overdue; one overdue nudge only.
- Calendar account removed from the iPhone: the chore's calendar toggle turns off with a note.
- The chosen calendar is read-only (subscribed): not listed in the picker.
- Time zone travel: floating times keep "7 pm local wherever you are".

## Empty and error states
| State | Behavior |
|---|---|
| No chores | To-Dos view strip: "No chores yet — tap + in a room to add one"; room sheet shows an Add button |
| Nothing due this week | "Nothing due this week" in the strip |
| Calendar write fails | The chore saves; the toggle shows "Couldn't add to calendar" with Retry; logged under `calendar` |
| Notification scheduling fails | The chore saves; Diagnostics shows pending count x/64 and the last error |

## Data touched (LLD)
`chore` (repeat_rule_json, start_on, next_due_on, due_minutes, remind_*, calendar_enabled, linked_thing_id, is_paused, closed_at), `chore_completion` (append-only; outcome done/skipped), `chore_calendar_link`, local-only `calendar_event_cache`, `notification_snooze`, `app_meta` (device nickname), `project.spawned_from_chore_id`, `inventory_item.quantity` (spare decrement), `person`.

## UI references
Mockups **2.2** To-Dos, **3.3** Room sheet: Kitchen, To-Dos, **4.1** Chore detail (repeat rule, assignee, push reminder, Add to calendar picker listing iCloud "Home" and a Google account's calendars), **6.3** Settings (reminder defaults).

## Analytics / diagnostics
No event tracking. Diagnostics shows: pending notifications (x/64), notification and calendar authorization states, calendar owner device, last calendar error; counts-only export includes chores with reminders on, chores with calendar on, completions per ISO week (for the PRD retention signal, PRD §5.2).

## Out of scope
Direct Google sign-in; two-way calendar sync; rotating assignees (PRD Q-6); chore costs; server push; reminders on housemates' own phones (v1.2 sharing); location-based reminders; Apple Watch.

## Assumptions pending founder confirmation
HLD §9-3 (weekday picks, monthly interval, anchors), §9-4 (collapse + Skip), §9-5 (owner device), §9-6 (full calendar access), §9-7 (Google calendar caveat), §9-8 (60 reminders / 14 days / sentinel), §9-20 (spare-stock prompt).
