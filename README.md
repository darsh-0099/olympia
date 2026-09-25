# Olympia for iPhone

Native SwiftUI rebuild of the Olympia workout tracker, adapted from the prior web app and the SolarH9 heart-rate project. The display name and app icon are Olympia. The project targets iOS 17 or later.

## Included in the source

- SwiftData workouts, programs, sessions, individual sets, body weight, and workout history.
- Weekly schedules with the same workout on multiple days, or workout rotation with configurable rest days.
- Native workout flow: 120-second equipment prep, previous-set targets, editable weight/reps, wall-clock rest timer, pause/resume, partial completion, and recovery of an interrupted session.
- Home calendar with planned colors and completed sessions, progress charts, Notes/text workout and body-weight imports, JSON export, units, and appearance settings.
- Standard Bluetooth Heart Rate Service (0x180D / 0x2A37) scanning and recording inherited from SolarH9. Polar H9 and WHOOP in HR Broadcast mode are expected to be discoverable if they advertise that standard service; neither has been device-tested in this rebuild.
- Heart-rate Live Activity (Lock Screen and Dynamic Island) and a Home Screen launch widget.
- Supabase email/password account and manual cloud-sync code, plus row-level-security schema. Cloud sync needs a project URL and publishable key and has not been end-to-end tested.

## Set up Supabase

1. Create a free Supabase project.
2. Run [supabase/schema.sql](supabase/schema.sql) in its SQL Editor.
3. In the iPhone app's Settings, enter the project's HTTPS URL and **publishable/anon** key. Never enter a service-role key.
4. Create an account, confirm its email if required, sign in, and tap Sync now.

The native app uses separate Supabase accounts. It does not automatically inherit the website's ChatGPT session or hosted database. To bring old data over, import the original workout note; the current website JSON export only includes routines, not all historical workouts and weights.

## Build

This Mac currently lacks full Xcode and iOS signing credentials. The project and scripts are prepared, but **no new Olympia IPA has been built or verified**. On a Mac with Xcode 16+ and a configured Apple Developer team, open `SolarH9.xcodeproj`, select the `SolarH9` scheme (the internal scheme name), configure signing and a unique bundle identifier, then archive/export an iOS app.

For a non-installable unsigned archive, run `scripts/build_unsigned_ipa.sh`; it outputs `Olympia.ipa`. A signed IPA requires Xcode signing/provisioning. Do not mistake an unsigned archive for something an iPhone can install.

## Known gaps before release

- Full Xcode compile, simulator/device QA, hardware HR validation, and signing cannot be completed in the present environment.
- Supabase sync is currently manual and snapshot-based; it needs a robust multi-device conflict/deletion strategy before it is safe to market as seamless real-time sync.
- Native Sign in with Apple, home-widget workout data, and a complete migration from the existing hosted website are not yet connected.
- The note importer covers common dated workout lines and slash-separated reps; unusual free-form lines should be reviewed after import.
