# Olympia for iPhone

Native SwiftUI rebuild of the Olympia workout tracker, adapted from the prior web app and the SolarH9 heart-rate project. The display name and app icon are Olympia. The project targets iOS 17 or later.

## Included in the source

- SwiftData workouts, programs, sessions, individual sets, body weight, and workout history.
- Weekly schedules with the same workout on multiple days, or workout rotation with configurable rest days.
- Native workout flow: 120-second equipment prep, previous-set targets, editable weight/reps, wall-clock rest timer, pause/resume, partial completion, and recovery of an interrupted session.
- Home calendar with planned colors and completed sessions, progress charts, Notes/text workout and body-weight imports, JSON export, units, and appearance settings.
- Aurora Glass UI refresh with six selectable scenic themes (Aurora by default), glass-styled Home/Program/Progress/Settings and workout sheets, and an updated schedule/workout/history editor. Native Liquid Glass is used on iOS 26+ with a material fallback on earlier supported iOS versions.
- Standard Bluetooth Heart Rate Service (0x180D / 0x2A37) scanning and recording inherited from SolarH9. Polar H9 and WHOOP in HR Broadcast mode are expected to be discoverable if they advertise that standard service; neither has been device-tested in this rebuild.
- Heart-rate Live Activity (Lock Screen and Dynamic Island), a Home Screen launch widget, and large Week/Active Workout widgets.
- Supabase email/password account and manual cloud-sync code, plus row-level-security schema. Cloud sync needs a project URL and publishable key and has not been end-to-end tested.

## Set up Supabase

1. Create a free Supabase project.
2. Run [supabase/schema.sql](supabase/schema.sql) in its SQL Editor.
3. In the iPhone app's Settings, enter the project's HTTPS URL and **publishable/anon** key. Never enter a service-role key.
4. Create an account, confirm its email if required, sign in, and tap Sync now.

The native app uses separate Supabase accounts. It does not automatically inherit the website's ChatGPT session or hosted database. To bring old data over, import the original workout note; the current website JSON export only includes routines, not all historical workouts and weights.

## Build

This Mac currently lacks full Xcode and iOS signing credentials. Hosted builds can compile and package an unprovisioned engineering preview. On a Mac with Xcode 16+ and a configured Apple Developer team, open `SolarH9.xcodeproj`, select the `SolarH9` scheme (the internal scheme name), configure signing and a unique bundle identifier, then archive/export an iOS app.

The private [Olympia GitHub repository](https://github.com/darsh-0099/olympia) builds a reviewed source ZIP after checking its SHA-256. Build 21 is the historical verified preview (45 focused tests reported passing). The 2026-10-13 candidate adds a sensor-independent workout Live Activity, ring/timer Lock Screen display, timer/laurel Dynamic Island, workout-scoped previous-set references, and a four-action Home sheet. The follow-up candidate matches sheets/editor to the calendar glass, anchors the dock outside content safe-area padding, and preserves workout streaks through scheduled rest days. Local syntax/plist checks are available, but compilation, full regression tests, and device behavior require hosted Xcode/device verification. The dedicated `codex/live-workout-preview-2026-10-13` branch triggers a full-suite candidate build; main builds remain manual.

For an unprovisioned SideStore preview, run `scripts/build_unsigned_ipa.sh`; it outputs `Olympia.ipa`. The app and extension carry ad-hoc signatures only so SideStore can discover their App Group request. They have no provisioning profile or device-installable signature: SideStore must provision and re-sign both before an iPhone can install them.

## Known gaps before release

- Build 21 compiled the Aurora Glass source; the new Live Activity candidate still needs hosted verification and device visual/accessibility review. Physical-device QA, hardware HR validation, cloud-sync end-to-end testing, and signed installation remain unverified.
- Supabase sync is manual and snapshot-based, with three-way conflict/deletion checks and optimistic revision writes in source; live integration testing remains necessary.
- Native Sign in with Apple and a complete migration from the existing hosted website are not yet connected. Home-widget workout data requires matching App Group provisioning and device verification (see below).
- The note importer covers common dated workout lines and slash-separated reps; unusual free-form lines should be reviewed after import.
## Large home-screen widgets

The Week and Active Workout widgets are `systemLarge` only. They read a compact
snapshot of actual local Olympia training data (schedule, completed sessions,
workout phase/sets, and an optional recent Polar H9 reading). The widgets do not
show demo heart-rate values. A reading disappears after 30 seconds; WidgetKit
controls actual refresh timing, so the widget is not a live heart-rate monitor.

Both the app and widget extension declare the `group.com.olympia.app` App Group.
To show personal data, the installed signatures and provisioning profiles **must
both** authorize the same group. If the shared container cannot be opened (or
the app has not written a snapshot yet), the widgets show an honest unavailable
state and open Olympia when tapped. SideStore may re-sign or remap App Groups;
widget-to-app group sharing has been reported to fail in SideStore even when an
Xcode-installed build works. Verify the final signed app and `.appex` entitlements
and test on-device before relying on data display. The unprovisioned IPA build does
not prove App Group access.

## Workout Live Activity candidate

The workout engine starts its own Live Activity without requiring a sensor. Prep/rest use system-rendered absolute-deadline timers; working shows elapsed workout time, and pause freezes it. The Lock Screen card shows the upcoming/current exercise, set, previous-workout target, completion progress, and only a fresh real sensor reading below the timer. Pause/Resume and Skip Rest are session-scoped Live Activity intents in the app process, independent of the widget App Group. The compact Dynamic Island shows only Olympia's existing laurel with an iridescent tint and the timer; Reduce Motion keeps the mark silver. iOS controls update animations; this is not a continuous RGB animation. Background phase transitions and sensor availability must be confirmed on-device.

Exercise-progress charts and a separate nutrition prototype are proposed, not included in this candidate. The Programs tab stays available until a replacement is approved and ready. Previous references are keyed by workout IDs for all routine variants, including Pull and future Legs/Accessories; workout names do not determine the lookup. Scheduled rest days preserve streaks without adding completed workouts; missed/skipped training days still break them.
