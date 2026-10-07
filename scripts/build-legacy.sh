#!/bin/sh
#
# Builds an unsigned 32-bit (armv7) .ipa for iOS 10 devices such as the
# iPad 4, which Xcode 16 can no longer target. Uses the command-line tools
# from Xcode 13.4.1, the last version that builds armv7 (Xcode 13 itself
# doesn't need to launch). Xcode 13 can't open this project's file format, so
# the steps Xcode normally does are spelled out here.
#
# Usage:
#   XCODE13=/path/to/Xcode_13.4.1.app scripts/build-legacy.sh
#
# Install the .ipa with Sideloadly, or sign it yourself (see the README).

set -eu

XCODE13=${XCODE13:-/Applications/Xcode_13.4.1.app}
export DEVELOPER_DIR="$XCODE13/Contents/Developer"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/rsc-swift"
OUT=${OUT:-"$ROOT/build/legacy"}
BUNDLE_ID=${BUNDLE_ID:-io.github.amadesa.rscswift}
MIN_IOS=10.0
TARGET="armv7-apple-ios$MIN_IOS"

# the app target's version (the first MARKETING_VERSION in the project)
VERSION=$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);/\1/p' \
    "$ROOT/rsc-swift.xcodeproj/project.pbxproj" | head -1)

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
BUILD="$OUT/intermediates"
APP="$OUT/Payload/rsc-swift.app"

echo "building rsc-swift $VERSION for $TARGET with $(xcrun swiftc --version 2>&1 | head -1)"

rm -rf "$OUT"
mkdir -p "$BUILD/objects" "$APP"

# keep this machine's paths (and so the username) out of the binary
PREFIX_MAP="-ffile-prefix-map=$ROOT=."

# 1. the rsc-c game core
find "$SRC/Core" -name '*.c' | while IFS= read -r file; do
    object="$BUILD/objects/$(echo "${file#$SRC/Core/}" | tr / _).o"
    xcrun clang -target "$TARGET" -isysroot "$SDK" -std=gnu99 -fwrapv -O2 -w \
        -DIOS -DRENDER_SW -I "$SRC/Core" "$PREFIX_MAP" \
        -c "$file" -o "$object"
done

# 2. the Swift app, linked with the core. iOS 10 has no Swift runtime of its
# own, so the app must look for the one it ships in Frameworks (step 6)
xcrun swiftc -target "$TARGET" -sdk "$SDK" -O -parse-as-library \
    -module-name rsc_swift \
    -import-objc-header "$SRC/rsc-swift-Bridging-Header.h" \
    -Xcc -I"$SRC/Core" -Xcc "$PREFIX_MAP" \
    -debug-prefix-map "$ROOT=." \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks \
    "$SRC"/*.swift "$BUILD"/objects/*.o \
    -o "$APP/rsc-swift"

# 3. game data and licence
cp "$SRC"/Resources/cache/* "$APP/"
cp "$SRC/Core/COPYING" "$APP/"

# 4. icons and launch images. Xcode 13's ibtool and actool don't run on
# current macOS, so instead of a compiled storyboard and asset catalog use
# loose files listed in Info.plist, which iOS 10 still supports
ICON="$SRC/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

icon() { # name pixels
    sips -z "$2" "$2" "$ICON" --out "$APP/$1" >/dev/null
}

icon AppIcon60x60@2x.png 120
icon AppIcon60x60@3x.png 180
icon AppIcon40x40@2x.png 80
icon AppIcon76x76~ipad.png 76
icon AppIcon76x76@2x~ipad.png 152
icon AppIcon83.5x83.5@2x~ipad.png 167
icon AppIcon40x40~ipad.png 40
icon AppIcon40x40@2x~ipad.png 80

# plain black launch images: the icon's (black) corner pixel, padded out
sips -c 1 1 --cropOffset 0 0 "$ICON" --out "$BUILD/black.png" >/dev/null

launch() { # name width height
    sips -p "$3" "$2" --padColor 000000 "$BUILD/black.png" \
        --out "$APP/$1" >/dev/null 2>&1
}

launch LaunchImage-700@2x.png 640 960
launch LaunchImage-700-568h@2x.png 640 1136
launch LaunchImage-700-Portrait~ipad.png 768 1024
launch LaunchImage-700-Portrait@2x~ipad.png 1536 2048
launch LaunchImage-700-Landscape~ipad.png 1024 768
launch LaunchImage-700-Landscape@2x~ipad.png 2048 1536

# 5. Info.plist (Xcode generates this from the build settings normally)
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>RSC</string>
	<key>CFBundleExecutable</key><string>rsc-swift</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>rsc-swift</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleIcons</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array><string>AppIcon40x40</string><string>AppIcon60x60</string></array>
		</dict>
	</dict>
	<key>CFBundleIcons~ipad</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon40x40</string><string>AppIcon60x60</string>
				<string>AppIcon76x76</string><string>AppIcon83.5x83.5</string>
			</array>
		</dict>
	</dict>
	<key>UILaunchImages</key>
	<array>
		<dict>
			<key>UILaunchImageMinimumOSVersion</key><string>7.0</string>
			<key>UILaunchImageName</key><string>LaunchImage-700</string>
			<key>UILaunchImageOrientation</key><string>Portrait</string>
			<key>UILaunchImageSize</key><string>{320, 480}</string>
		</dict>
		<dict>
			<key>UILaunchImageMinimumOSVersion</key><string>7.0</string>
			<key>UILaunchImageName</key><string>LaunchImage-700-568h</string>
			<key>UILaunchImageOrientation</key><string>Portrait</string>
			<key>UILaunchImageSize</key><string>{320, 568}</string>
		</dict>
	</array>
	<key>UILaunchImages~ipad</key>
	<array>
		<dict>
			<key>UILaunchImageMinimumOSVersion</key><string>7.0</string>
			<key>UILaunchImageName</key><string>LaunchImage-700-Portrait</string>
			<key>UILaunchImageOrientation</key><string>Portrait</string>
			<key>UILaunchImageSize</key><string>{768, 1024}</string>
		</dict>
		<dict>
			<key>UILaunchImageMinimumOSVersion</key><string>7.0</string>
			<key>UILaunchImageName</key><string>LaunchImage-700-Landscape</string>
			<key>UILaunchImageOrientation</key><string>Landscape</string>
			<key>UILaunchImageSize</key><string>{768, 1024}</string>
		</dict>
	</array>
	<key>LSRequiresIPhoneOS</key><true/>
	<key>MinimumOSVersion</key><string>$MIN_IOS</string>
	<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
	<key>UIRequiredDeviceCapabilities</key><array><string>armv7</string></array>
	<key>UIRequiresFullScreen</key><true/>
	<key>UIStatusBarHidden</key><true/>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>UISupportedInterfaceOrientations~ipad</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationPortraitUpsideDown</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>DTPlatformName</key><string>iphoneos</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Info.plist" >/dev/null

# 6. iOS 10 has no Swift runtime built in, so ship it with the app
xcrun swift-stdlib-tool --copy --scan-executable "$APP/rsc-swift" \
    --platform iphoneos --destination "$APP/Frameworks" >/dev/null

# the libraries come with 64-bit slices too; this build only runs as armv7
for library in "$APP"/Frameworks/*.dylib; do
    xcrun lipo "$library" -thin armv7 -output "$library.armv7"
    mv "$library.armv7" "$library"
done

# 7. package
IPA="$OUT/rsc-swift-legacy-$VERSION.ipa"
(cd "$OUT" && zip -qry "$IPA" Payload)

echo "built $IPA ($(du -h "$IPA" | cut -f1))"
