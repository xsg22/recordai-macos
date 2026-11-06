#!/bin/zsh
# Compile both modern Icon Composer renditions and the legacy macOS icon.
# Arguments are explicit so callers can keep all generated output off the source disk.
set -euo pipefail
[[ $# == 2 ]] || { print -u2 'usage: export-icon.zsh <app-path> <work-directory>'; exit 2; }
icon_root="${0:A:h:h}"
icon_app="${1:A}"
icon_work="${2:A}"
icon_plist="$icon_app/Contents/Info.plist"
[[ -f "$icon_plist" ]] || { print -u2 "Missing app Info.plist: $icon_plist"; exit 1; }
mkdir -p "$icon_work" "$icon_app/Contents/Resources"
icon_stage="$(mktemp -d "$icon_work/export.XXXXXX")"
icon_minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$icon_plist" 2>/dev/null || print '14.0')"
xcrun actool "$icon_root/Resources/AppIcon.icon" \
    --compile "$icon_stage" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target "$icon_minimum" --target-device mac \
    --output-partial-info-plist "$icon_stage/IconInfo.plist" \
    --notices --warnings --errors --output-format human-readable-text
[[ -s "$icon_stage/AppIcon.icns" && -s "$icon_stage/Assets.car" ]] || {
    print -u2 'Icon compilation did not produce modern and legacy resources'; exit 1
}
# Validate compiler metadata before copying the complete icon resource set.
for icon_key in CFBundleIconFile CFBundleIconName; do
    icon_value="$(/usr/libexec/PlistBuddy -c "Print :$icon_key" "$icon_stage/IconInfo.plist")"
    [[ "$icon_value" == AppIcon ]] || { print -u2 "Unexpected $icon_key: $icon_value"; exit 1; }
done
cp "$icon_stage/AppIcon.icns" "$icon_app/Contents/Resources/AppIcon.icns"
cp "$icon_stage/Assets.car" "$icon_app/Contents/Resources/Assets.car"
for icon_key in CFBundleIconFile CFBundleIconName; do
    if /usr/libexec/PlistBuddy -c "Print :$icon_key" "$icon_plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$icon_key AppIcon" "$icon_plist"
    else
        /usr/libexec/PlistBuddy -c "Add :$icon_key string AppIcon" "$icon_plist"
    fi
done
