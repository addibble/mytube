# MyTube

An iOS app for listening to audiobooks that only exist as YouTube videos. A book is an ordered list of YouTube links; the app streams the audio, remembers where you left off in each part, and rolls from one part into the next.

- Bookmarks saved continuously, so playback resumes from the same timestamp
- Skip back/forward by 15 or 30 seconds, playback speed, scrubbing
- Lock screen / Control Center player
- CarPlay audio app (needs Apple's `com.apple.developer.carplay-audio` entitlement, not enabled in this repo)

Audio is streamed with HTTP range requests; nothing is downloaded up front or cached.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
echo 'DEVELOPMENT_TEAM = YOURTEAMID' > Config/Local.xcconfig
xcodegen generate
open MyTube.xcodeproj
```

Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to one of your own.

## Note

Stream extraction uses [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) and is outside YouTube's Terms of Service. This is a personal-use project, not something that could ship on the App Store, and it may break when YouTube changes its player.
