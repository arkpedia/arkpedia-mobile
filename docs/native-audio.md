# Background playback and lock-screen controls (0.2)

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
An iOS 17+ Live Activity adds explicit Heart and Block buttons beside the standard
system player. Live Activities must be enabled, have system-controlled lifetimes,
and can require authentication before button actions. An old card cannot change
the preferences of a newer track: its intent carries the track ID. The extension
identifier is `net.arkpedia.mobile.controls` and must be signed with the app.

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
native song and position instead of starting another stream. The native player
does not supply browser Web Audio samples for the spectrum visualization.

## Validation and distribution

GitHub Actions compiles the Android APK, runs Android lint, and archives the iOS
app with its widget extension. The website's tests cover queue ordering,
YouTube boundaries, idempotent preference edits, stale responses, pause/resume,
background song changes and reload restoration using a simulated native bridge.
Those checks do not constitute physical-device playback tests.

Before broader distribution, use signed device builds to check screen locking,
several automatic track transitions, each action, headphone/Bluetooth routes,
interruptions, native-to-YouTube handoff, process termination, Live Activity
authorization/lifetime and signed extension intents. Compile-only and simulated
bridge evidence cannot establish those OS-level outcomes.

Node 24 is the development/CI runtime. Checkout, setup-node and artifact upload use
their Node-24-based v6 releases. `setup-java@v5` also uses Node 24 internally and
installs **Java 21** for Gradle; the two runtime versions are independent.
