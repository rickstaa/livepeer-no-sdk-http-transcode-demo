#!/usr/bin/env bash
# Client side: reserve a session, PUT the source, GET the renditions back.
# Usage: ./client.sh [mkv|fmp4]
set -euo pipefail
cd "$(dirname "$0")"

ORCH=http://127.0.0.1:8935

case "${1:-mkv}" in
  mkv) MUX=(-f matroska) ;;
  fmp4) MUX=(-f mp4 -movflags frag_keyframe+empty_moov+default_base_moof) ;;
  *)
    echo "usage: $0 [mkv|fmp4]" >&2
    exit 2
    ;;
esac

# 1. Reserve a session. app_url is this session's route to the runner.
SESSION=$(curl -sSf -X POST "$ORCH/apps/transcode/session")
APP_URL=$(jq -r .app_url <<<"$SESSION")
CONTROL_URL=$(jq -r .control_url <<<"$SESSION")
echo "app_url: $APP_URL"
echo "control_url: $CONTROL_URL"

# 2. PUT the source for 8 seconds, in real time, as one long request.
ffmpeg -hide_banner -loglevel error -re -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 8 \
  -c:v libx264 -preset ultrafast -tune zerolatency -g 30 "${MUX[@]}" \
  -method PUT "$APP_URL/in" &
UPLOAD=$!

# 3. GET the renditions on a second request while the upload is still running.
curl -sSfN "$APP_URL/out" -o out.mkv \
  -w 'first rendition bytes after %{time_starttransfer}s, finished after %{time_total}s\n'
wait "$UPLOAD"

# 4. Release the session.
curl -sSf -o /dev/null -X POST "$CONTROL_URL/stop"

echo "renditions in out.mkv (index, codec, width, height, frames):"
ffprobe -v error -count_packets -show_entries stream=index,codec_name,width,height,nb_read_packets \
  -of csv=p=0 out.mkv
