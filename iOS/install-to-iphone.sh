#!/bin/zsh
# 一键把课译装到连着电脑的 iPhone 上（免费 Apple ID 每 7 天需要重装一次，运行本脚本即可）。
# 前提：已安装 Xcode 26.x，并在 Xcode › 设置 › Accounts 登录了 Apple ID；iPhone 用数据线连接电脑并“信任此电脑”，
#       iPhone 已打开“设置 › 隐私与安全性 › 开发者模式”。
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | grep -v Xcodes | sort -V | tail -1)/Contents/Developer}

# 优先用 Xcode 里“Signing & Capabilities”选过的团队（记在本机 .keyi-team，不上传）；其次用已登录账号的第一个团队。
[[ -f .keyi-team ]] && KEYI_TEAM=${KEYI_TEAM:-$(<.keyi-team)}
team=${KEYI_TEAM:-$( { defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null || true;
                       defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null || true; } \
    | grep -o 'teamID = [A-Z0-9]*' | head -1 | awk '{print $3}')}
if [[ -z "$team" ]]; then
    print "没有找到开发团队：请先打开 Xcode › 设置 › Accounts，用 Apple ID 登录一次。"
    exit 1
fi

devices_json=$(mktemp)
xcrun devicectl list devices --json-output "$devices_json" >/dev/null 2>&1 || true
device=$(/usr/bin/python3 -c '
import json, sys
for d in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") == "iOS" and hw.get("reality") == "physical" \
            and d.get("connectionProperties", {}).get("pairingState") == "paired":
        print(d["identifier"]); break
' "$devices_json" 2>/dev/null || true)
rm -f "$devices_json"
if [[ -z "$device" ]]; then
    print "没有找到 iPhone：请用数据线连接手机、解锁并点“信任此电脑”。"
    exit 1
fi

print "构建中（团队 $team）…"
xcodebuild -project KeYi.xcodeproj -target KeYi -configuration Release -sdk iphoneos \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
    SYMROOT="$PWD/build" -quiet build
print "安装到 iPhone…"
xcrun devicectl device install app --device "$device" build/Release-iphoneos/KeYi.app
print "完成。第一次安装后，请在 iPhone 上打开“设置 › 通用 › VPN与设备管理”，信任你的开发者证书。"
