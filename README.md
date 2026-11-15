# Dunk Lab

A personal iOS app for dunk training: purposeful practice, a training program,
and body tracking, all pointed at the gap between your best touch and the next
dunk on your ladder.

Open `DunkLab.xcodeproj` in Xcode 27 and run on an iPhone or simulator (iOS 26+).
To install on your phone, pick your team under Signing & Capabilities.

## Layout

- `DunkLab/Model`: SwiftData models (`Models.swift`), seed import, and the math
  for loads, nutrition and formatting (`Calc.swift`).
- `DunkLab/Resources`: seed data imported once on first launch, then editable
  in the app. `phd-program.json` is generated from the Jump Science PDF.
  `practice-defaults.json` holds the dunk ladder and practice focuses.
- `DunkLab/Views`: Today (reach ladder), Practice, Train, Body.
- `DunkLabWidgets`: the widget extension. Live Activities put the current set
  (with a Done button) or the practice count (with Make / Rimmed / Miss) on the
  lock screen while a workout or session screen is open.
- `Shared`: code compiled into both the app and the extension: the palette and
  the Live Activity attributes and their button intents. The intents run in the
  app's process, which owns the store and the activities.
- `Tools/extract_program.py`: regenerates the program JSON from the PDF.
- `DESIGN.md`: the visual direction and why.

## Debug launch arguments

- `-fixture starting-numbers`: skips onboarding with the starting numbers.
- `-tab practice|train|body`: opens on a tab.
- `-week 4 -day 1` (with the fixture): starts the program at that week and
  0-based day, e.g. the week 4 max-out day.
- `-open workout` (with `-tab today`) or `-open session` (with `-tab practice`):
  opens the live workout or practice screen.

## Later

- Video capture of attempts in a practice session.
- Logging other sport play toward the weekly budget.
- HealthKit import for weight and body fat.
- Charts for lifts beyond the squat max.
