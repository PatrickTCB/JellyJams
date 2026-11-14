# Agents Guide

## Summany

This is a SwiftUI app for Jellyfin music playback on iOS, macOS, and tvOS.

## Design
Standard SwiftUI controls, behaviours, and design patterns should always be preferred over custom behaviour. 

## Critical Workflow
- **Project Generation**: `.xcodeproj` is generated via XcodeGen. It should only be run once, so if you're looking at a directory that already has a `.xcodeproj` file then you don't need to re-generate it.

## Platform & Verification
- **Targets**: macOS 27, iOS/iPadOS 27, tvOS 27. Use `#if os(...)` for platform-specific code. tvOS follows the iOS focus-and-select idiom (`#if !os(macOS)` paths) but lacks Sliders, Steppers, keyboard shortcuts, swipe/reorder, and the `Commands` API — guard those with `#if !os(tvOS)`.
- **Testing**: Unit tests run on **macOS, the iOS Simulator, and the tvOS Simulator**. macOS is the fast default; the iOS suite is required when touching `#if os(iOS)` code — background download sessions are only covered there. Some simulator model names are duplicated across runtimes; pick a unique name or target by id.
  - macOS: `xcodebuild test -project JellyJams.xcodeproj -scheme JellyJams -destination 'platform=macOS'`
  - iOS: `xcodebuild test -project JellyJams.xcodeproj -scheme JellyJams -destination 'platform=iOS Simulator,name=iPhone 17'`
  - tvOS: `xcodebuild test -project JellyJams.xcodeproj -scheme JellyJams -destination 'platform=tvOS Simulator,name=Apple TV 4K'`
- **iOS Type-Check**: Verify iOS builds with:
  `xcodebuild -project JellyJams.xcodeproj -scheme JellyJams -destination 'generic/platform=iOS Simulator' build`
- **tvOS Type-Check**: Verify tvOS builds with:
  `xcodebuild -project JellyJams.xcodeproj -scheme JellyJams -destination 'generic/platform=tvOS Simulator' build`

## Architecture & Tech
- **DI**: Core services are `@Observable` classes owned by `AppServices` and provided to views via `.environment(_:)` / `@Environment(Type.self)` (see `JellyJamsApp.swift`). Outside views, follow changes with `Observations`, not Combine.
- **SDK**: Not pinned but should only be updated by human hands.
