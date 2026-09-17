#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
project_path="$repo_dir/Safari Gesture Nav/Safari Gesture Nav.xcodeproj"
derived_data="$(mktemp -d /tmp/SafariGestureNav.Install.XXXXXX)"
product="$derived_data/Build/Products/Release/Safari Gesture Nav.app"
product_extension="$product/Contents/PlugIns/Safari Gesture Nav Extension.appex"
destination="/Applications/Safari Gesture Nav.app"
destination_extension="$destination/Contents/PlugIns/Safari Gesture Nav Extension.appex"
extension_identifier="dev.eli.safari.gesturenav.Extension"
legacy_derived_data="$repo_dir/build/Install"

cleanup() {
  pluginkit -r "$product_extension" 2>/dev/null || true
  if [[ "$derived_data" == /tmp/SafariGestureNav.Install.* ]]; then
    rm -rf "$derived_data"
  fi
}
trap cleanup EXIT

cd "$repo_dir"
cp "$repo_dir/extension/background.js" "$repo_dir/Safari Gesture Nav/Safari Gesture Nav Extension/Resources/background.js"
cp "$repo_dir/extension/manifest.json" "$repo_dir/Safari Gesture Nav/Safari Gesture Nav Extension/Resources/manifest.json"

xcodebuild \
  -project "$project_path" \
  -scheme "Safari Gesture Nav" \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  build

# Remove every stale registration of this bundle ID before registering the
# installed copy. Xcode and older install scripts may have registered apps from
# temporary or DerivedData build folders; Safari otherwise lists both copies.
pluginkit -m -A -v | awk -F '\t' '/dev\.eli\.safari\.gesturenav\.Extension\(/ {print $NF}' | while IFS= read -r registered_extension; do
  [[ "${registered_extension:A}" == "${destination_extension:A}" || "${registered_extension:A}" == "${product_extension:A}" ]] && continue
  pluginkit -r "$registered_extension" 2>/dev/null || true
  case "$registered_extension" in
    /private/tmp/SafariGestureNav.*/Build/Products/*/Safari\ Gesture\ Nav.app/Contents/PlugIns/*|/tmp/SafariGestureNav.*/Build/Products/*/Safari\ Gesture\ Nav.app/Contents/PlugIns/*)
      stale_app="${registered_extension%/Contents/PlugIns/*}"
      rm -rf "$stale_app"
      ;;
  esac
done
if [[ -d "$legacy_derived_data" ]]; then
  rm -rf "$legacy_derived_data"
fi

if [[ -e "$destination" ]]; then
  osascript -e 'tell application "Safari Gesture Nav" to quit' 2>/dev/null || true
  pluginkit -r "$destination_extension" 2>/dev/null || true
  rm -rf "$destination"
fi

ditto "$product" "$destination"
# Remove old temporary app bundles even when LaunchServices no longer lists them.
find /private/tmp -maxdepth 6 -type d -path '/private/tmp/SafariGestureNav.*/Build/Products/*/Safari Gesture Nav.app' -print0 | while IFS= read -r -d '' stale_app; do
  [[ "${stale_app:A}" == "${product:A}" ]] && continue
  rm -rf "$stale_app"
done
pluginkit -r "$product_extension" 2>/dev/null || true
pluginkit -a "$destination_extension"
pluginkit -e use -i "$extension_identifier" || true
# Only needed the first time Safari allows this unsigned extension; writing
# Safari's container preferences may be denied (e.g. sandboxed shells), so a
# failure here must not block the install.
defaults write com.apple.Safari IncludeDevelopMenu -bool true 2>/dev/null || true
defaults write com.apple.Safari AllowUnsignedExtensions -bool true 2>/dev/null || true
open "$destination"
echo "Installed: $destination"
