# Agents Guide

## Summany

This is a SwiftUI app for Jellyfin music playback on iOS, and macOS.

## Design
Standard SwiftUI controls, behaviours, and design patterns should always be preferred over custom behaviour. 

## Critical Workflow
- **Project Generation**: `.xcodeproj` is generated via XcodeGen. It should only be run once, so if you're looking at a directory that already has a `.xcodeproj` file then you don't need to re-generate it.

## Platform & Verification
- **Targets**: macOS 15, iOS/iPadOS 27. Use `#if os(...)` for platform-specific code.
- **Testing**: Unit tests run on **both macOS and the iOS Simulator**. macOS is the fast default; the iOS suite is required when touching `#if os(iOS)` code — background download sessions are only covered there. Some simulator model names are duplicated across runtimes; pick a unique name or target by id.
  - macOS: `xcodebuild test -project JellyJams.xcodeproj -scheme JellyJams -destination 'platform=macOS'`
  - iOS: `xcodebuild test -project JellyJams.xcodeproj -scheme JellyJams -destination 'platform=iOS Simulator,name=iPhone 17'`
- **iOS Type-Check**: Verify iOS builds with:
  `xcodebuild -project JellyJams.xcodeproj -scheme JellyJams -destination 'generic/platform=iOS Simulator' build`

## Architecture & Tech
- **DI**: Core services are provided via `EnvironmentObject` (see `JellyJamsApp.swift`).
- **SDK**: Pinned to `jellyfin-sdk-swift` v3.1.0.
