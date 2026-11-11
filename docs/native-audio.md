# Background playback and lock-screen controls (0.3.1)

This app release pairs with the native-audio adapter in `arkpedia/arkpedia`.
Older website releases still use the web player; the mobile bridge alone does not
replace a website audio element. Ordinary browsers and older mobile builds retain
the existing web engines.

Android uses Media3/ExoPlayer in a media-playback foreground service. The media
session exposes playback, seeking, Previous/Next, Favourite and Block from autoplay.
Android chooses the placement and visibility of the custom actions. Audio focus
and headphone disconnection are handled natively.

iOS uses AVPlayer with the playback audio session and audio background mode. Now
Playing exposes metadata, album artwork, timeline and supported remote commands.
The system chooses its icon and placement for the Favourite/Like command (currently
shown as a star); apps cannot replace that glyph with a custom heart. Version 0.3
removes the companion Live Activity and its widget extension, so no extra black
card appears. Startup dismisses an activity left by 0.2. The ActivityAttributes
schema and Info.plist support flag remain only for that migration; no new activity
is requested. Block remains available in Arkpedia and on Android.

Favourite toggles the website's existing favourites. Block toggles **Don't autoplay**:
explicitly chosen/queued songs are still playable. Blocking an automatically
selected current song advances to the next eligible native track.

## Native/web contract

`Capacitor.Plugins.ArkpediaAudio` exposes `getState`, `loadTrack`, `configure`,
`command`, and a `state` event. Both native implementations restrict commands to
the top-level `https://www.arkpedia.net` origin. They accept numeric Monster Siren
IDs and construct the canonical audio/cover URLs themselves; the page cannot
give the player an arbitrary URL. Redirects are handled by the platform player.

The website sends the chosen playback order, repeat mode and preference snapshot.
Native playback advances without a JavaScript callback. A snapshot stops at a
YouTube-only track or a Data saver boundary, preserving that boundary for a later
foreground action. This does not extract YouTube audio or promise YouTube
background playback. Native tracks use the canonical audio redirect endpoint, so
the app does not retain expiring CDN URLs in its queue.

Native preference edits are stored as absolute values with a monotonically
increasing revision. Website snapshots older than that revision cannot overwrite
them. The website applies edits to its existing local storage and acknowledges
them on its next configuration. Per-session sequence numbers reject delayed
playback responses. Returning to the page or reloading reconciles the current
native song and position instead of starting another stream. On iOS 0.3.1+, an optional `getSpectrum` method supplies 48 real frequency-band
levels to the foreground website. A pass-through AVPlayer audio tap copies PCM
into bounded buffers; FFT work runs outside the audio callback and uses separate
stereo channels. Analysis stops when the page no longer requests it, and stale or
wrong-track samples are not displayed. The existing player remains the only audio
stream. Android and older iOS builds report spectrum unavailable; YouTube does
not expose samples. Pause, seek, interruptions and track changes clear the capture.

The iOS build also runs generated-tone tests for frequency placement, calibrated
dBFS, silence, anti-phase stereo, planar/interleaved PCM, stale seek data and reset.
These tests and an archive do not replace a physical iPhone listening test.

## Validation and distribution

GitHub Actions compiles the Android APK, runs Android lint, and archives the iOS
app. The website's tests cover queue ordering,
YouTube boundaries, idempotent preference edits, stale responses, pause/resume,
background song changes and reload restoration using a simulated native bridge.
Those checks do not constitute physical-device playback tests.

Before broader distribution, use signed device builds to check screen locking,
several automatic track transitions, each action, headphone/Bluetooth routes,
interruptions, native-to-YouTube handoff, process termination, and dismissal of
a companion card left by an older build. Compile-only and simulated
bridge evidence cannot establish those OS-level outcomes.

Node 24 is the development/CI runtime. Checkout, setup-node and artifact upload use
their Node-24-based v6 releases. `setup-java@v5` also uses Node 24 internally and
installs **Java 21** for Gradle; the two runtime versions are independent.
