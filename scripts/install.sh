#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
project_path="$repo_dir/Safari Gesture Nav/Safari Gesture Nav.xcodeproj"
derived_data="$repo_dir/build/Install"
product="$derived_data/Build/Products/Release/Safari Gesture Nav.app"
product_extension="$product/Contents/PlugIns/Safari Gesture Nav Extension.appex"
destination="/Applications/Safari Gesture Nav.app"
destination_extension="$destination/Contents/PlugIns/Safari Gesture Nav Extension.appex"
extension_identifier="dev.eli.safari.gesturenav.Extension"

cd "$repo_dir"
cp "$repo_dir/extension/background.js" "$repo_dir/Safari Gesture Nav/Safari Gesture Nav Extension/Resources/background.js"
cp "$repo_dir/extension/manifest.json" "$repo_dir/Safari Gesture Nav/Safari Gesture Nav Extension/Resources/manifest.json"

xcodebuild \
  -project "$project_path" \
  -scheme "Safari Gesture Nav" \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  build

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
