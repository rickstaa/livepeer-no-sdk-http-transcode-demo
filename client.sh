#!/usr/bin/env bash
# Client side: reserve a session, PUT the source, GET the renditions back, print the lag.
# Usage: ./client.sh [mkv|fmp4]
set -euo pipefail
cd "$(dirname "$0")"

ORCH=http://127.0.0.1:8935
FPS=30

case "${1:-mkv}" in
  mkv) MUX=(-f matroska) ;;
  # One fragment per frame. frag_keyframe would hold frames back until each 1s fragment ends.
  fmp4) MUX=(-f mp4 -movflags frag_every_frame+empty_moov+default_base_moof) ;;
  *)
    echo "usage: $0 [mkv|fmp4]" >&2
    exit 2
    ;;
esac

# Decode the 720p track from stdin and print how late its frames arrive. Each frame is
# due at START + n / FPS, so this includes the time ffmpeg takes to start the source.
lag() {
  ffmpeg -hide_banner -nostats -flags low_delay -probesize 32 -analyzeduration 0 -i pipe:0 \
    -map 0:v:0 -vf showinfo -f null - 2>&1 |
    while read -r line; do
      now=${EPOCHREALTIME/[.,]/}
      if [[ $line =~ \ n:\ *([0-9]+)\  ]]; then
        echo $(((now - START) / 1000 - BASH_REMATCH[1] * 1000 / FPS))
      fi
    done |
    sort -n |
    awk '{ v[NR] = $1 }
      END { if (NR) printf "output lag: median %d ms, max %d ms over %d frames\n", v[int((NR + 1) / 2)], v[NR], NR }'
}

# 1. Reserve a session. app_url is this session's route to the runner.
SESSION=$(curl -sSf -X POST "$ORCH/apps/transcode/session")
APP_URL=$(jq -r .app_url <<<"$SESSION")
CONTROL_URL=$(jq -r .control_url <<<"$SESSION")
echo "app_url: $APP_URL"
echo "control_url: $CONTROL_URL"

# 2. PUT the source for 8 seconds as one long request. The realtime filter paces it like
# a live camera. -re would burst the start.
START=${EPOCHREALTIME/[.,]/}
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=1920x1080:rate=$FPS,realtime" -t 8 \
  -c:v libx264 -preset ultrafast -tune zerolatency -g 30 "${MUX[@]}" \
  -method PUT "$APP_URL/in" &
UPLOAD=$!

# 3. GET the renditions on a second request while the upload is still running.
curl -sSfN "$APP_URL/out" | tee out.mkv | lag
wait "$UPLOAD"

# 4. Release the session.
curl -sSf -o /dev/null -X POST "$CONTROL_URL/stop"

echo "renditions in out.mkv (index, codec, width, height, frames):"
ffprobe -v error -count_packets -show_entries stream=index,codec_name,width,height,nb_read_packets \
  -of csv=p=0 out.mkv
