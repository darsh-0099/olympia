# Olympia for iPhone

Olympia is a native iPhone workout tracker created and directed by **Darsh Patel**, built with **ChatGPT and Codex as AI development collaborators**. It brings workout planning, set logging, training history, body-weight tracking, and optional heart-rate monitoring into a customizable SwiftUI interface.

The project grew from an earlier Olympia web app and the SolarH9 heart-rate project. Its goal is to make everyday strength training easier to follow: know what to train, see what you lifted last time in that routine, record today's sets, and keep useful workout information visible when you leave the app.

**Status:** actively developed engineering preview for iOS 17 and later. The latest verified preview documented here is [Build 26](https://github.com/darsh-0099/olympia/actions/runs/38492309118): simulator and device compilation, IPA package validation, and **117 automated tests passed with zero failures**. Physical-device appearance, background behavior, sensor integration, and cloud sync still need further validation.

## Darsh's contribution

Darsh provides the product vision, training requirements, visual direction, and decisions that shape Olympia. His contribution includes:

- **Defining the experience:** a native workout app built around his training workflow, with reusable workouts, flexible programs, previous-performance references, timers, and a calendar.
- **Specifying training rules:** previous reps and weights must come from the same workout, because an exercise performed first in Push A can feel different when performed second in Push B. This requirement applies to every routine, including Pull and future Legs & Accessories variants. Planned rest days should preserve a training streak.
- **Directing the design:** choosing Aurora Glass, reviewing mockups, selecting the laurel identity and scenic themes, and giving detailed feedback on glass texture, opacity, navigation spacing, editor consistency, stars, and Earth's geography.
- **Shaping the workout controls:** selecting the Lock Screen ring layout, requesting heart rate beneath the timer when a real sensor is connected, and simplifying the Dynamic Island to a timer and Olympia mark.
- **Reducing friction:** specifying four quick actions—start today's workout, start another workout, log body weight, and connect a heart-rate sensor.
- **Guiding iteration:** reporting issues through descriptions and screenshots, requesting fixes and preview builds, and deciding which proposed features should move forward.
- **Setting future direction:** proposing clearer exercise-progress visualizations and exploring a separate nutrition tracker before integrating it into Olympia.

These are concrete product and design contributions. The implementation was developed with substantial AI assistance; this project does not claim that every line of code was written manually by Darsh.

## How ChatGPT and Codex were used

The development process is conversational and iterative. Darsh describes a need or problem, discusses options with ChatGPT, reviews mockups, and chooses a direction. Codex then works with the existing repository to implement changes, investigate bugs, add relevant tests, and prepare preview builds. Feedback from each iteration informs the next.

AI assistance has included SwiftUI screens, data models, workout-state logic, Bluetooth and ActivityKit integration, regression tests, debugging, build scripts, GitHub Actions workflows, and documentation. Image-generation tools have also helped create and refine visual concepts and background artwork under Darsh's direction.

The workflow combines human decisions with AI-assisted implementation and verification. Generated code is checked through source review, compilation, and automated tests; passing those checks does not replace testing the installed app on an iPhone. Mockups and proposed features are kept separate from implemented functionality.

## What Olympia includes

### Workouts and programs

- Create and edit reusable workouts, exercises, set counts, target weights, and programs.
- Schedule workouts on selected weekdays, including the same workout on multiple days, or use ordered workout/rest rotations.
- Configure start dates and finite repeat cycles; handle missed days, deliberate skips, and substitutions.
- View planned training and completed sessions in the Home calendar.
- Preserve streaks across scheduled rest days without counting rest as a completed workout. Missed training days can still break a streak.

### Active workout sessions

- Equipment-preparation phase, editable reps and weights, set logging, and rest timers based on absolute deadlines.
- Pause/resume, complete a session, save partial progress, discard a session, and recover interrupted workouts.
- Previous-set references scoped to the workout's stable ID and exercise, using the most recent eligible session containing that exercise. Missing sets are not filled from another routine or an older session. Imported history without a linked workout ID is not assigned automatically.
- An explicit exercise-history picker for finding previous exercises across routines when editing a workout.

### Lock Screen, Dynamic Island, and widgets

A workout Live Activity starts independently of a heart-rate sensor. The Lock Screen card shows a timer ring, current or next exercise, set information, previous-session target, and completion progress. Pause/Resume and Skip Rest controls act on the associated session. A fresh real heart-rate reading appears below the timer when available.

The compact Dynamic Island shows the timer and Olympia's laurel with an iridescent tint. Reduce Motion uses a silver mark. Animation and background updates remain subject to iOS behavior; the mark is not a continuously running RGB animation.

Home Screen widgets include a launch widget and large Week/Active Workout views. Personal widget data uses a shared App Group. Heart-rate readings become stale after 30 seconds, and WidgetKit controls refresh timing, so these widgets are not continuous heart-rate monitors.

### History, progress, and data

- Workout history and individual set records, plus exercise and body-weight charts.
- Body-weight logging and unit preferences.
- Workout-note/text and body-weight imports, with an import report for skipped lines.
- JSON export of training data.
- Optional Supabase email/password accounts and manual snapshot sync, with three-way merge, conflict/deletion checks, and optimistic revision writes implemented in source.

The core workout experience stores data locally with SwiftData. Cloud sync requires explicit configuration. Authentication tokens use Keychain, and the supplied Supabase schema applies owner-scoped row-level security. Live cloud integration has not yet been verified end to end.

### Aurora Glass interface

Six selectable scenic themes—**Aurora, Forest, Tropical, Dusk, Sakura, and Space**—combine dark backgrounds, translucent cards, and a floating navigation dock. The quick-action sheet and workout editor use the calendar card's glass treatment. Native Liquid Glass is used on iOS 26+, with a material fallback on earlier supported versions. The app also includes accessibility preferences, haptics, and workout-completion effects.

Build 26's Space theme has refined stars, an Earth facing North and South America, and no separate atmospheric horizon at the bottom.

## Architecture

The app's display name is Olympia. The Xcode project, scheme, and several inherited types retain the internal name `SolarH9`.

| Area | Main source | Responsibility |
| --- | --- | --- |
| App entry | `SolarH9/App/SolarH9App.swift` | Initializes training persistence, sensor coordination, and the root UI |
| Training data | `SolarH9/Olympia/OlympiaTrainingStore.swift` | SwiftData models, schedules, history, prior-set lookup, streaks, widget snapshots |
| Workout engine | `SolarH9/Olympia/OlympiaWorkoutEngine.swift` | Session phases, timers, recovery, and workout Live Activity updates |
| Interface | `SolarH9/Olympia/Olympia*View*.swift`, `OlympiaThemes.swift` | Home, editors, active workout, history, progress, settings, and themes |
| Bluetooth | `SolarH9/Bluetooth/` | Standard Bluetooth Heart Rate Service connectivity |
| Activities and widgets | `SolarH9/LiveActivity/`, `SolarH9LiveActivity/` | Activity attributes, interactive controls, Lock Screen/Island layouts, widgets |
| Data portability | `OlympiaImportExport.swift`, `OlympiaCloud.swift`, `supabase/schema.sql` | Note import, backup export, optional authentication and sync |
| Verification | `SolarH9Tests/`, `scripts/`, `.github/workflows/ios-preview.yml` | Automated tests, IPA packaging/validation, hosted builds |

The stack uses Swift, SwiftUI, SwiftData, Swift Charts, CoreBluetooth, ActivityKit, WidgetKit, App Intents, and optional Supabase services. The inherited heart-rate recording store and Olympia training store are wired together at the app entry point.

## Find the correct source and build it

**Repository layout matters:** recent previews are built from `Olympia-source.zip`, whose SHA-256 is checked by the workflow before extraction over the checkout. Files visible directly in GitHub's source tree can therefore be older than the files actually compiled. The default branch's bundle currently predates Build 26.

For the verified Build 26 source, use [commit `1871f048`](https://github.com/darsh-0099/olympia/tree/1871f0485f2d83bb7d86fe5175d720390d5ad48c) on [the preview branch](https://github.com/darsh-0099/olympia/tree/codex/live-workout-preview-2026-10-13). Its source archive has SHA-256:

```text
2a3b905c80d5294683ff7148441fe1ddc99fe24471f81c17508831f91ceb32d2
```

In a separate checkout, reproduce that snapshot with:

```sh
git clone https://github.com/darsh-0099/olympia.git olympia-preview
cd olympia-preview
git checkout 1871f0485f2d83bb7d86fe5175d720390d5ad48c
echo '2a3b905c80d5294683ff7148441fe1ddc99fe24471f81c17508831f91ceb32d2  Olympia-source.zip' | shasum -a 256 -c -
unzip -o Olympia-source.zip
open SolarH9.xcodeproj
```

Stop if the checksum does not match. Extraction restores the README bundled with that historical build as well as its source; GitHub's default-branch README is maintained separately.

Use a Mac with full Xcode and the appropriate iOS SDK; Build 26 was verified with **Xcode 26.6**. Select the `SolarH9` scheme and an iPhone simulator, then build/run or use Xcode's Test action. A physical-device installation requires suitable signing and provisioning for the app and extension. If changing bundle identifiers or the App Group, update both targets and their shared-container configuration consistently.

### Preview builds and installation

The [GitHub Actions workflow](https://github.com/darsh-0099/olympia/actions/workflows/ios-preview.yml) compiles the simulator app, packages the device preview, runs tests, and uploads build artifacts with seven-day retention. Main builds are manual and can select the full suite; pushes to the dedicated preview branch run the full suite. Artifacts can expire, so use a successful run and preserve any preview you need.

The packaging script, `scripts/build_unsigned_ipa.sh`, produces `Olympia.ipa`. For current previews, the app and extension have ad-hoc signatures and no provisioning profiles. **SideStore must provision and re-sign both before installation.** This is an engineering preview, not an App Store or TestFlight release. Package validation does not prove that the installed app and widgets can share their App Group.

## Optional Supabase setup

1. Create a Supabase project and run `supabase/schema.sql` from the extracted source in its SQL Editor.
2. In Olympia's Settings, enter the project's HTTPS URL and publishable/anon key. Never use a service-role key in the app.
3. Create an account, confirm its email if required, and sign in.
4. Use **Sync now** to sync manually. Export local data before resolving a reported conflict.

The native app uses its own Supabase authentication. It does not inherit a ChatGPT login or the earlier web app's database. A complete migration of the earlier website's history is not implemented; review imported notes and the import report before relying on them.

## Current limitations and next steps

- **Device verification:** further testing is needed for Lock Screen layout and controls, background timer transitions, recovery, accessibility, dock spacing, and older-iOS visual fallbacks.
- **Heart-rate hardware:** the code uses the standard Bluetooth Heart Rate Service (`0x180D` / `0x2A37`). Polar H9 and compatible devices in HR broadcast mode are intended use cases; physical hardware compatibility has not been confirmed for this preview.
- **Widgets:** both installed targets must have matching App Group authorization. SideStore signing and shared-container access need device verification. An unavailable state is shown when shared data cannot be read.
- **Cloud:** manual sync and conflict protection exist in source, but live multi-device testing remains outstanding. Native Sign in with Apple is not connected.
- **Historical schedules:** streak calculations use available active-plan metadata; the app does not keep an immutable archive of every past schedule edit.
- **Source maintenance:** moving the reviewed preview source into a fully synchronized, directly browsable source tree would simplify contributions and reproducible builds.

Two product ideas remain **proposals, not shipped features**: an expandable per-exercise progress visualization to replace Training Overview, and a nutrition diary inspired by Cronometer, developed separately before possible integration. Existing progress charts remain available, and the Programs tab has not been replaced.

To report a problem, include the preview build number, iPhone model, iOS version, reproduction steps, and expected versus actual behavior. Screenshots are helpful for layout issues. Avoid including private workout exports, credentials, or sensor identifiers in public reports.
