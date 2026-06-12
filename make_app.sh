#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# make_app.sh — Build ThreeDViewport.app from a Swift Package project.
#
# Usage:
#   ./make_app.sh           # release build (default)
#   ./make_app.sh debug     # debug build
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PRODUCT="ThreeDViewport"
BUNDLE_ID="com.example.ThreeDViewport"
VERSION="1.0"
CONFIG="${1:-release}"

echo "▶  Building $PRODUCT ($CONFIG)..."
swift build -c "$CONFIG"

SRC=".build/$CONFIG"
APP="$PRODUCT.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

echo "▶  Assembling $APP..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

# ── Executable ────────────────────────────────────────────────────────────────
cp "$SRC/$PRODUCT" "$MACOS/$PRODUCT"
echo "   Copied executable"

# ── Resources bundle + pre-compiled Metal shaders ────────────────────────────
# SPM copies .metal source files into the bundle but does NOT compile them.
# makeDefaultLibrary(bundle:) requires a pre-compiled default.metallib.
# We compile it here with xcrun metal/metallib so the .app is self-contained.
#
# Bundle.module looks for the bundle at Bundle.main.bundleURL/<name>.bundle
# (the .app root, not Contents/Resources) — place it there.
BUNDLE_NAME="${PRODUCT}_${PRODUCT}.bundle"
BUNDLE_DST="$APP/$BUNDLE_NAME"

if [ -d "$SRC/$BUNDLE_NAME" ]; then
    cp -r "$SRC/$BUNDLE_NAME" "$APP/"
    echo "   Copied $BUNDLE_NAME → $BUNDLE_DST"
else
    mkdir -p "$BUNDLE_DST"
    echo "   Created empty $BUNDLE_DST"
fi

# Compile all .metal sources into default.metallib inside the bundle.
METAL_SRC_DIR="Sources/ThreeDViewport/Renderer"
AIR_FILES=()
for METAL_FILE in "$METAL_SRC_DIR"/*.metal; do
    AIR="${METAL_FILE%.metal}.air"
    xcrun -sdk macosx metal -c "$METAL_FILE" -o "$AIR"
    AIR_FILES+=("$AIR")
    echo "   Compiled $(basename "$METAL_FILE")"
done

if [ ${#AIR_FILES[@]} -gt 0 ]; then
    xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$BUNDLE_DST/default.metallib"
    rm -f "${AIR_FILES[@]}"
    echo "   Linked default.metallib → $BUNDLE_DST/default.metallib"
else
    echo "   WARNING: no .metal files found in $METAL_SRC_DIR"
fi

# ── GLTFKit2 dynamic framework ────────────────────────────────────────────────
if [ -d "$SRC/GLTFKit2.framework" ]; then
    cp -r "$SRC/GLTFKit2.framework" "$FRAMEWORKS/"
    # Add an rpath so the executable finds the framework at its conventional location.
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/$PRODUCT"
    echo "   Copied GLTFKit2.framework and added rpath"
else
    echo "   WARNING: GLTFKit2.framework not found"
fi

# ── Info.plist ────────────────────────────────────────────────────────────────
cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${PRODUCT}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${PRODUCT}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.graphics-design</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>ThreeDViewport Project</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>${BUNDLE_ID}.project</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>${BUNDLE_ID}.project</string>
            <key>UTTypeDescription</key>
            <string>ThreeDViewport Project</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.json</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>3dvp</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF
echo "   Created Info.plist"

# ── Ad-hoc code sign ──────────────────────────────────────────────────────────
# Required for Metal and Gatekeeper on modern macOS.
# Sign inner components first, then the app wrapper.
# (--deep can't handle versioned frameworks reliably, so we do it manually.)
# For distribution replace '-' with your Developer ID identity.
echo "▶  Code signing (ad-hoc)..."

# Sign each framework binary first
for fw in "$FRAMEWORKS"/*.framework; do
    if [ -d "$fw" ]; then
        # Find the actual Mach-O binary (may be in Versions/A/ for versioned frameworks)
        FW_BINARY=$(find "$fw" -type f -perm +0111 | head -1)
        if [ -n "$FW_BINARY" ]; then
            codesign --force --sign - "$fw" 2>/dev/null || \
            codesign --force --sign - "$FW_BINARY"
        fi
    fi
done

# Sign the app bundle itself.
# --no-strict is required because SPM places the resources bundle directly in
# the .app root (Bundle.main.bundleURL convention for command-line executables).
# This is fine for ad-hoc / local use; replace '-' with a Developer ID for
# App Store or Notarization builds (which require a standard bundle layout).
codesign --force --sign - --no-strict "$APP"

# ── Register document types with LaunchServices ───────────────────────────────
# So Finder immediately associates .3dvp files with this rebuilt bundle (otherwise
# a stale "can't open" association can linger until next login).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$PWD/$APP" 2>/dev/null || true
    echo "   Registered document types with LaunchServices"
fi

echo ""
echo "✅  $APP is ready."
echo "   Run with:  open $APP"
echo "   Or double-click in Finder."
