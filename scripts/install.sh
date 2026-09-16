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

# Older versions kept a complete built app inside the repository. LaunchServices
# can discover that embedded extension and make Safari show it next to the copy
# in /Applications, even though both have the same bundle identifier.
pluginkit -r "$legacy_derived_data/Build/Products/Release/Safari Gesture Nav.app/Contents/PlugIns/Safari Gesture Nav Extension.appex" 2>/dev/null || true
if [[ -d "$legacy_derived_data" ]]; then
  rm -rf "$legacy_derived_data"
fi

if [[ -e "$destination" ]]; then
  osascript -e 'tell application "Safari Gesture Nav" to quit' 2>/dev/null || true
  rm -rf "$destination"
fi

ditto "$product" "$destination"
pluginkit -r "$product_extension" 2>/dev/null || true
pluginkit -a "$destination_extension"
pluginkit -e use -i "$extension_identifier" || true
defaults write com.apple.Safari IncludeDevelopMenu -bool true
defaults write com.apple.Safari AllowUnsignedExtensions -bool true || true
open "$destination"
echo "Installed: $destination"
