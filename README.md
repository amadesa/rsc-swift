# rsc-swift

A native iOS/iPadOS RuneScape Classic client, built around the
[2003scape/rsc-c](https://github.com/2003scape/rsc-c) game client with a
Swift/Metal platform layer and a touch-first UI. It defaults to the
[RSC Preservation](https://rsc.vet) world (`game.openrsc.com:43596`).

Runs on iOS/iPadOS 12.2 and later.

## Features

- The full rsc-c client: protocol, world, software renderer and the touch
  controls from its Android/web builds. Tap = left click, hold = right click,
  horizontal drag = rotate camera, vertical drag or pinch = zoom.
- Metal display at any screen size and orientation, kept clear of the notch
  and rounded corners.
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

## Project layout

```
Config/                       shared build settings and local signing template
rsc-swift/
  Core/                       rsc-c sources (upstream 2ce1b5a) with iOS patches
    mudclient-ios.c           iOS platform layer: input queue, touch gestures,
                              frame handoff, sound/keyboard/URL/world callbacks
    rsc-bridge.h              C API used from Swift
  Resources/cache/            game data (.jag/.mem) from rsc-c
  AppDelegate.swift           UIKit app entry point
  GameClient.swift            starts the game thread, routes callbacks
  GameViewController.swift    layout, game resolution, hardware keys, alerts
  GameView.swift              Metal view, touches, keyboard proxy text field
  FrameRenderer.swift         uploads frames to a Metal texture
  FrameShaders.metal
  GameAudio.swift             8kHz sound effects via AVAudioEngine
  AddWorldController.swift    "Add world" sheet
  WorldConfig.swift           world .ini parsing
scripts/rsc-c-ios.patch       every change made to the upstream rsc-c files
```

## How it works

- The C client runs its own blocking loop (`mudclient_run`) on a dedicated
  thread. Swift posts touches and keys into a locked queue that
  `mudclient_poll_events` drains on the game thread.
- Each `surface_draw` copies the finished software-rendered frame into a
  shared buffer, and `FrameRenderer` uploads the newest one to Metal.
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
