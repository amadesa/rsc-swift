# rsc-swift

A native iOS/iPadOS RuneScape Classic client, built around the
[2003scape/rsc-c](https://github.com/2003scape/rsc-c) game client with a
Swift/Metal platform layer and a touch-first UI. It defaults to the
[RSC Preservation](https://rsc.vet) world (`game.openrsc.com:43596`).

Runs on iOS/iPadOS 12.2 and later. A separate legacy build runs on 32-bit
devices stuck on iOS 10, such as the iPad 4 and iPhone 5 (see
[Legacy build](#legacy-build-ios-10-32-bit)).

## Features

- The full rsc-c client: protocol, world, software renderer and the touch
  controls from its Android/web builds. Tap = left click, hold = right click,
  horizontal drag = rotate camera, vertical drag or pinch = zoom.
- Metal display at any screen size and orientation, kept clear of the notch
  and rounded corners, with a Core Graphics fallback for devices without
  Metal.
- Native keyboard for chat and text boxes: hold-to-delete, paste, and a bar
  above the keyboard showing what you're typing. Hardware keyboards work
  too (arrows rotate the camera).
- Login screen with stacked **Login**, **Register**, **Worlds** and
  **Options** buttons. Register opens the selected world's sign-up page in
  Safari.
- World list with **Add world** (import an rscplus world `.ini` from Files
  or a URL, or enter a host and port by hand) and **Remove**.
- Camera defaults to manual on touch screens until you pick a mode in game.
- Combat style is remembered per character and world.

## Building

Requires Xcode 16 or later.

1. Clone the repo and open `rsc-swift.xcodeproj`.
2. To run on a device, copy `Config/Signing.local.xcconfig.example` to
   `Config/Signing.local.xcconfig` and fill in your Apple developer team ID
   and a bundle identifier prefix. That file is ignored by git, so your
   signing details stay out of the repo. The simulator needs no signing.
3. Run the `rsc-swift` scheme.

From the command line:

```
xcodebuild -project rsc-swift.xcodeproj -scheme rsc-swift \
  -destination 'generic/platform=iOS Simulator' build
```

Set your team in `Signing.local.xcconfig` rather than in Xcode's
Signing & Capabilities tab, which would write it into the project file.

## Legacy build (iOS 10, 32-bit)

Xcode 16 can't build for 32-bit (armv7) devices or target iOS 10, so
`scripts/build-legacy.sh` builds those with the command-line tools from
Xcode 13.4.1 instead:

1. Download Xcode 13.4.1 from
   [developer.apple.com/download/all](https://developer.apple.com/download/all)
   (any Apple ID) and unpack it, e.g. to `/Applications/Xcode_13.4.1.app`.
   It doesn't open on current macOS, but its build tools still work, and
   your default Xcode isn't affected.
2. Run `XCODE13=/Applications/Xcode_13.4.1.app scripts/build-legacy.sh`.
   The unsigned `.ipa` is written to `build/legacy/`.
3. Install it with [Sideloadly](https://sideloadly.io), which supports old
   iOS versions (AltStore and SideStore need iOS 12.2 or later).

Xcode 13 can't open this project's file format, so the script spells out
the build: it compiles the C core and Swift app for armv7, bundles the Swift
runtime (iOS 10 has none built in), and uses plain icon and launch image
files instead of the asset catalog and storyboard, since Xcode 13's
Interface Builder tools don't run on current macOS. On devices without
Metal the app shows frames with Core Graphics (`FrameDisplay.swift`). The
Swift code is kept compatible with Swift 5.6 and iOS 10.

## Project layout

```
Config/                       shared build settings, signing template, Info.plist
rsc-swift/
  Core/                       rsc-c sources (upstream 2ce1b5a) with iOS patches
    mudclient-ios.c           iOS platform layer: input queue, touch gestures,
                              frame handoff, sound/keyboard/URL/world callbacks
    rsc-bridge.h              C API used from Swift
  Resources/cache/            game data (.jag/.mem) from rsc-c
  AppDelegate.swift           UIKit app entry point (makes the window before iOS 13)
  SceneDelegate.swift         makes the window on iOS 13+ (scene life cycle)
  GameClient.swift            starts the game thread, routes callbacks
  GameViewController.swift    layout, game resolution, hardware keys, alerts
  GameView.swift              touches, keyboard proxy text fields
  FrameDisplay.swift          Metal display, or Core Graphics without Metal
  FrameRenderer.swift         uploads frames to a Metal texture
  FrameShaders.metal
  GameAudio.swift             8kHz sound effects via AVAudioEngine
  AddWorldController.swift    "Add world" sheet
  WorldConfig.swift           world .ini parsing
scripts/rsc-c-ios.patch       every change made to the upstream rsc-c files
scripts/build-legacy.sh       32-bit iOS 10 build using Xcode 13's tools
```

## How it works

- The C client runs its own blocking loop (`mudclient_run`) on a dedicated
  thread. Swift posts touches and keys into a locked queue that
  `mudclient_poll_events` drains on the game thread.
- Each `surface_draw` copies the finished software-rendered frame into a
  shared buffer, and the display shows the newest one: `FrameRenderer`
  uploads it to Metal, or without Metal it becomes a CGImage on a layer.
- The client always loads at 512x346 like desktop rsc-c, then switches to
  the screen size; the login backdrop is pre-rendered while loading.
- Phones render at about one game pixel per point; iPads scale so the short
  side is about 400 game pixels.
- Options and worlds are stored in Application Support as `options.ini` and
  `worlds.cfg`, in the desktop rsc-c format. `worlds.cfg` lines are
  `name host port rsa_exp rsa_mod [register_url|-]`.
- The app target compiles the C code with `IOS`, `RENDER_SW`, `-fwrapv` and
  gnu99. Define `REVISION_177` to use the 177 protocol instead of 203; OpenRSC
  accepts both.

## Updating rsc-c

Copy the new upstream `src/` over `rsc-swift/Core` (skipping the SDL, GL,
Wii and 3DS platform files and `lib/rsa/rsa-openssl.c`), then reapply
`scripts/rsc-c-ios.patch`.

## Credits

- [2003scape/rsc-c](https://github.com/2003scape/rsc-c): the game client
  this app is built on, including its game data files and touch UI.
  Copyright 2003Scape Team, AGPLv3.
- [Open-RSC](https://github.com/Open-RSC): the server software behind
  RSC Preservation and the [rsc.vet](https://rsc.vet) site.
- App icon: the [2003scape](https://github.com/2003scape) organisation
  avatar.
- Libraries bundled with rsc-c: [ini](https://github.com/rxi/ini) (MIT),
  [ISAAC](https://burtleburtle.net/bob/rand/isaacafa.html),
  [micro-bunzip](https://landley.net/code/) and
  [tiny-bignum-c](https://github.com/kokke/tiny-bignum-c).

## Disclaimer

This is an unofficial fan project. It is not affiliated with or endorsed by
Jagex Ltd. RuneScape is a trademark of Jagex Ltd, and the RuneScape Classic
game data remains the property of Jagex.

## License

GNU Affero General Public License v3.0, the same as rsc-c. See
[`LICENSE`](LICENSE).
