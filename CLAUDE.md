# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get       # Install/update dependencies
flutter run           # Run on connected device/emulator
flutter test          # Run all tests
flutter test test/widget_test.dart  # Run a single test file
flutter analyze       # Static analysis (uses flutter_lints)
flutter build apk     # Build Android APK
flutter build ios     # Build iOS (requires macOS + Xcode)
flutter build web     # Build web
```

## Project

**Morex** is a Flutter stock exchange application (`package:morex`).

- Dart SDK `^3.10.8`, Flutter stable channel
- Material Design UI
- Platforms scaffolded: Android, iOS, Web, Linux, macOS, Windows

## Current State

Early/greenfield. `lib/main.dart` is still the default Flutter counter app. No custom screens, state management, networking, or data layers have been added yet.

## Architecture (to be built)

No architectural decisions have been locked in yet. When adding features, consider:
- **State management:** `riverpod` or `bloc` are idiomatic choices for finance apps
- **Networking:** `dio` or `http` for market data APIs
- **Charting:** `fl_chart` for price/volume charts
- **Local storage:** `hive` or `isar` for caching quotes/watchlists

Follow standard Flutter layered architecture: `lib/` organized by feature or layer (e.g. `features/`, `data/`, `domain/`, `presentation/`).