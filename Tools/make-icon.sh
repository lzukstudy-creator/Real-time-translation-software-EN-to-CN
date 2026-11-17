#!/bin/zsh
set -euo pipefail

task_root=${0:A:h:h}
task_source="$task_root/Resources/AppIconSource.png"
task_iconset="$task_root/.build-cache/AppIcon.iconset"
task_output="$task_root/Resources/AppIcon.icns"
mkdir -p "$task_iconset"

for task_spec in 16:icon_16x16.png 32:icon_16x16@2x.png \
                 32:icon_32x32.png 64:icon_32x32@2x.png \
                 128:icon_128x128.png 256:icon_128x128@2x.png \
                 256:icon_256x256.png 512:icon_256x256@2x.png \
                 512:icon_512x512.png 1024:icon_512x512@2x.png; do
    task_size=${task_spec%%:*}
    task_name=${task_spec#*:}
    sips -s format png -z "$task_size" "$task_size" "$task_source" \
        --out "$task_iconset/$task_name" >/dev/null
done
iconutil -c icns "$task_iconset" -o "$task_output"
print "Created: $task_output"
