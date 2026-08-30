# Agents Guide

## Summany

This is a SwiftUI app for Jellyfin music playback on iOS, and macOS.

## Design
Standard SwiftUI controls, behaviours, and design patterns should always be preferred over custom behaviour. 

## Critical Workflow
- **Project Generation**: `.xcodeproj` is generated via XcodeGen. It should only be run once, so if you're looking at a directory that already has a `.xcodeproj` file then you don't need to re-generate it.

## Platform & Verification
- **Targets**: macOS 15, iOS/iPadOS 18. Use `#if os(...)` for platform-specific code.
- **Testing**: Unit tests are **macOS-only**.
- **iOS Type-Check**: Verify iOS builds with:
  `xcodebuild -project JellyJams.xcodeproj -scheme JellyJams -destination 'generic/platform=iOS Simulator' build`

## Architecture & Tech
- **DI**: Core services are provided via `EnvironmentObject` (see `JellyJamsApp.swift`).
- **SDK**: Pinned to `jellyfin-sdk-swift` v3.1.0.
