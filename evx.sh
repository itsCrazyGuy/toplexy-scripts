#!/bin/bash

BOT_TOKEN="8621768947:AAHWD7d_tNi_JJ29bSVTjiC6gXEkDuTRZxQ"
CHAT_ID="-1003937000666"
DEVICE_CODE="sky"

export TZ="Asia/Kolkata"
export BUILD_HOSTNAME=toplexy

send_msg() {
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode text="$1" \
    -d parse_mode=HTML > /dev/null
}

send_file() {
  [ -f "$1" ] || return
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
    -F chat_id="$CHAT_ID" \
    -F document=@"$1" > /dev/null
}

upload_gofile() {
  local FILE="$1"
  local SERVER=$(curl -s https://api.gofile.io/servers | jq -r '.data.servers[0].name // empty')
  [ -z "$SERVER" ] && return 1

  local LINK=$(curl -s -F "file=@$FILE" "https://$SERVER.gofile.io/uploadFile" | jq -r '.data.downloadPage // empty')
  [ -n "$LINK" ] && echo "$LINK" || return 1
}

format_time() {
  printf "%02dh %02dm %02ds" $(($1/3600)) $(($1%3600/60)) $(($1%60))
}

step_start() { send_msg "⚙️ $1..."; }
step_end() {
  if [[ $? -ne 0 ]]; then
    send_msg "⚠️ <b>$1 Failed</b>\nContinuing..."
  else
    send_msg "✅ $1 Done"
  fi
}

track_progress() {
  local PARENT_PID=$1
  local LAST=0

  while true; do
    kill -0 $PARENT_PID 2>/dev/null || break

    if [ -f out/error.log ]; then
      P=$(grep -oE "\[[[:space:]]*[0-9]+%" out/error.log | tail -n1 | tr -d '[ %')
      if [[ -n "$P" ]] && (( P >= LAST + 25 )); then
        send_msg "⚙️ <b>Build Progress: $P%</b>"
        LAST=$P
      fi
    fi

    [ -f out/.done ] && break
    sleep 60
  done
}

START=$(date +%s)

send_msg "🚀 <b>Build Started</b>

📱 <b>Device:</b> $DEVICE_CODE
🖥 <b>Host:</b> $BUILD_HOSTNAME
⏱ $(date)"

step_start "Cleaning local manifests"
rm -rf .repo/local_manifests
step_end "Cleaning local manifests"

step_start "Repo Init"
repo init -u https://github.com/Evolution-X/manifest -b bq2 --git-lfs
step_end "Repo Init"

step_start "Repo Sync"
/opt/crave/resync.sh
repo sync
step_end "Repo Sync"

rm -rf vendor/lineage-priv
rm -rf vendor/qcom/opensource/vibrator
rm -rf device/qcom/sepolicy_vndr/sm8450

step_start "Cloning repos"
git clone https://github.com/itscrazyguy/device_xiaomi_sky device/xiaomi/sky
git clone https://github.com/anonytry/kernel_xiaomi_sky.git -b new kernel/xiaomi/sky
git clone https://github.com/anonytry/device_qcom_sepolicy_vndr.git device/qcom/sepolicy_vndr/sm8450/
git clone https://github.com/anonytry/android_vendor_qcom_opensource_vibrator.git vendor/qcom/opensource/vibrator
step_end "Cloning repos"

export ALLOW_MISSING_DEPENDENCIES=true
export SKIP_ABI_CHECKS=true
export EVO=true

. build/envsetup.sh

step_start "KernelSU setup"
cd kernel/xiaomi/sky
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s dev
cd -
step_end "KernelSU setup"

send_msg "🛠 <b>Compilation Started</b>"

mkdir -p out
touch out/error.log
rm -f out/.done

track_progress $$ &
TRACK_PID=$!

BUILD_CMD="brunch sky user"
$BUILD_CMD 2>&1 | tee out/error.log
STATUS=${PIPESTATUS[0]}

touch out/.done
wait $TRACK_PID

END=$(date +%s)
TIME=$(format_time $((END-START)))

if [[ $STATUS -ne 0 ]]; then
  send_msg "❌ <b>Build Failed</b>

⚠️ Exit Code: $STATUS
⏱ $TIME"
  send_file out/error.log
  exit 1
fi

ZIP=$(find out/target/product/$DEVICE_CODE -name "*.zip" -type f -printf "%T@ %p\n" | sort -nr | head -n1 | cut -d' ' -f2-)

if [ -f "$ZIP" ]; then
  NAME=$(basename "$ZIP")
  SIZE=$(du -h "$ZIP" | cut -f1)
  DATE=$(date +'%d %b %Y')

  send_msg "📤 <b>Uploading...</b>"

  LINK=$(upload_gofile "$ZIP")

  if [ -n "$LINK" ]; then
    send_msg "<b>🚀 Build Released</b>

━━━━━━━━━━━━━━━━━━

📱 <b>Device:</b> $DEVICE_CODE
📦 <b>File:</b> $NAME
📊 <b>Size:</b> $SIZE
📅 <b>Date:</b> $DATE
⏱ <b>Time:</b> $TIME

━━━━━━━━━━━━━━━━━━

🔗 <a href=\"$LINK\">Download</a>

━━━━━━━━━━━━━━━━━━

<b>Maintainer:</b> $BUILD_HOSTNAME"
  else
    send_msg "⚠️ <b>Upload Failed</b>"
  fi
else
  send_msg "❌ <b>ZIP not found</b>"
fi
