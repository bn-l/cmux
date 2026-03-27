# Build and release commands for cmux (personal fork)

# Print version from Xcode project
version:
    @grep -m1 'MARKETING_VERSION' GhosttyTabs.xcodeproj/project.pbxproj | sed 's/.*= \(.*\);/\1/' | tr -d ' '

# Download pre-built GhosttyKit and init submodules
setup:
    git submodule update --init --recursive
    ./scripts/download-prebuilt-ghosttykit.sh

# Build release app
app-release: setup
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf build/
    xcodebuild -scheme cmux -configuration Release \
        -derivedDataPath build \
        -clonedSourcePackagesDirPath .spm-cache \
        CODE_SIGNING_ALLOWED=NO build
    APP_PLIST="build/Build/Products/Release/cmux.app/Contents/Info.plist"
    # Strip Sparkle auto-update (points to upstream)
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PLIST" 2>/dev/null || true
    # Ad-hoc sign so embedded binaries and frameworks pass validation
    codesign --force --deep -s - "build/Build/Products/Release/cmux.app"

# Build cmuxd-remote daemon (darwin-arm64 only) and inject manifest
daemon: app-release
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(just version)
    TAG="v${VERSION}"
    REPO="bn-l/cmux"
    DAEMON_ROOT="daemon/remote"
    OUTPUT_DIR="build/daemon-assets"
    mkdir -p "$OUTPUT_DIR"
    ASSET_NAME="cmuxd-remote-darwin-arm64"
    (
        cd "$DAEMON_ROOT"
        GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
        go build -trimpath -buildvcs=false \
            -ldflags "-s -w -X main.version=${VERSION}" \
            -o "../../${OUTPUT_DIR}/${ASSET_NAME}" \
            ./cmd/cmuxd-remote
    )
    chmod 755 "$OUTPUT_DIR/$ASSET_NAME"
    SHA256=$(shasum -a 256 "$OUTPUT_DIR/$ASSET_NAME" | awk '{print $1}')
    RELEASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
    MANIFEST=$(jq -nc \
        --arg version "$VERSION" \
        --arg tag "$TAG" \
        --arg releaseUrl "$RELEASE_URL" \
        --arg asset "$ASSET_NAME" \
        --arg sha "$SHA256" \
        '{
            schemaVersion: 1,
            appVersion: $version,
            releaseTag: $tag,
            releaseURL: $releaseUrl,
            checksumsAssetName: "cmuxd-remote-checksums.txt",
            checksumsURL: "\($releaseUrl)/cmuxd-remote-checksums.txt",
            entries: [{
                goOS: "darwin",
                goArch: "arm64",
                assetName: $asset,
                downloadURL: "\($releaseUrl)/\($asset)",
                sha256: $sha
            }]
        }')
    APP_PLIST="build/Build/Products/Release/cmux.app/Contents/Info.plist"
    plutil -remove CMUXRemoteDaemonManifestJSON "$APP_PLIST" 2>/dev/null || true
    plutil -insert CMUXRemoteDaemonManifestJSON -string "$MANIFEST" "$APP_PLIST"
    # Re-sign after plist modification
    codesign --force --deep -s - "build/Build/Products/Release/cmux.app"
    # Write checksums file for upload
    printf '%s  %s\n' "$SHA256" "$ASSET_NAME" > "$OUTPUT_DIR/cmuxd-remote-checksums.txt"

# Create DMG from release build
dmg: daemon
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f cmux-macos.dmg
    hdiutil create cmux-macos.dmg -volname "cmux" \
        -srcfolder build/Build/Products/Release/cmux.app -ov -format UDZO
    echo "cmux-macos.dmg"

# Create GitHub release with DMG and daemon binary
release: dmg
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(just version)
    TAG="v${VERSION}"
    SHA=$(shasum -a 256 cmux-macos.dmg | cut -d' ' -f1)
    gh release create "$TAG" \
        cmux-macos.dmg \
        build/daemon-assets/cmuxd-remote-darwin-arm64 \
        build/daemon-assets/cmuxd-remote-checksums.txt \
        --repo bn-l/cmux \
        --title "cmux v${VERSION}" \
        --notes "See assets to download and install."
    echo ""
    echo "SHA256: ${SHA}"
    echo "Update homebrew-tap/Casks/cmux.rb with version \"${VERSION}\" and sha256 \"${SHA}\""

# Clean build artifacts
clean:
    rm -rf build/ cmux-macos.dmg
