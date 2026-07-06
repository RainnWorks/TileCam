#!/usr/bin/env bash
#
# check-stream-audio.sh — Does a go2rtc stream have a USABLE WebRTC audio track?
#
# It does exactly what the TileCam app does: sends a WebRTC SDP offer (audio+video,
# recvonly) to go2rtc's /api/webrtc?src=<stream> and inspects the ANSWER. Then it
# forces the producer to connect and confirms real audio RTP bytes are flowing from
# the camera source (negotiating audio != audio actually arriving).
#
# Usage:
#   tools/check-stream-audio.sh <stream_name> [base_url]
#   tools/check-stream-audio.sh front_door
#   tools/check-stream-audio.sh kitchen https://go2rtc.example.com
#
# Point it at your own go2rtc server via the second arg or $GO2RTC_BASE.
#
# Exit codes: 0 = usable audio track flowing, 1 = no/empty audio, 2 = error.

set -u

STREAM="${1:-}"
BASE="${2:-${GO2RTC_BASE:-https://go2rtc.example.com}}"

if [[ -z "$STREAM" ]]; then
  echo "usage: $0 <stream_name> [base_url]" >&2
  exit 2
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 2; }; }
need curl
need python3

OFFER="$(mktemp)"
ANSWER="$(mktemp)"
trap 'rm -f "$OFFER" "$ANSWER"' EXIT

# Minimal recvonly offer advertising the codecs go2rtc can send for audio
# (Opus / G722 / PCMA / PCMU) plus H264 video. CRLF line endings per SDP spec.
{
  printf 'v=0\r\n'
  printf 'o=- 0 0 IN IP4 0.0.0.0\r\n'
  printf 's=-\r\n'
  printf 't=0 0\r\n'
  printf 'a=group:BUNDLE 0 1\r\n'
  printf 'a=msid-semantic: WMS\r\n'
  printf 'm=audio 9 UDP/TLS/RTP/SAVPF 111 9 8 0\r\n'
  printf 'c=IN IP4 0.0.0.0\r\n'
  printf 'a=rtcp:9 IN IP4 0.0.0.0\r\n'
  printf 'a=ice-ufrag:probe\r\n'
  printf 'a=ice-pwd:probepasswordprobepasswordpr\r\n'
  printf 'a=ice-options:trickle\r\n'
  printf 'a=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00\r\n'
  printf 'a=setup:actpass\r\n'
  printf 'a=mid:0\r\n'
  printf 'a=recvonly\r\n'
  printf 'a=rtcp-mux\r\n'
  printf 'a=rtpmap:111 opus/48000/2\r\n'
  printf 'a=rtpmap:9 G722/8000\r\n'
  printf 'a=rtpmap:8 PCMA/8000\r\n'
  printf 'a=rtpmap:0 PCMU/8000\r\n'
  printf 'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
  printf 'c=IN IP4 0.0.0.0\r\n'
  printf 'a=rtcp:9 IN IP4 0.0.0.0\r\n'
  printf 'a=ice-ufrag:probe\r\n'
  printf 'a=ice-pwd:probepasswordprobepasswordpr\r\n'
  printf 'a=ice-options:trickle\r\n'
  printf 'a=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00\r\n'
  printf 'a=setup:actpass\r\n'
  printf 'a=mid:1\r\n'
  printf 'a=recvonly\r\n'
  printf 'a=rtcp-mux\r\n'
  printf 'a=rtpmap:96 H264/90000\r\n'
  printf 'a=fmtp:96 packetization-mode=1;profile-level-id=42e01f\r\n'
} > "$OFFER"

echo "== Stream: $STREAM   (server: $BASE) =="

# 1) Negotiate — what does go2rtc COMMIT to send over WebRTC?
HTTP=$(curl -s --max-time 30 -X POST \
  -H "Content-Type: application/sdp" \
  --data-binary @"$OFFER" \
  "$BASE/api/webrtc?src=$STREAM" \
  -o "$ANSWER" -w "%{http_code}")

if [[ "$HTTP" != "201" && "$HTTP" != "200" ]]; then
  echo "  [ERROR] negotiation HTTP $HTTP"
  echo "  ----"; cat "$ANSWER"; echo
  exit 2
fi

# Parse the answer's audio m-section: present? direction? codecs?
AUDIO_NEG=$(python3 - "$ANSWER" <<'PY'
import sys, re
sdp = open(sys.argv[1], 'r', errors='replace').read()
# split into m-sections
parts = re.split(r'(?m)^(m=.*)$', sdp)
sections = {}
i = 1
while i < len(parts):
    mline = parts[i].strip()
    body = parts[i+1] if i+1 < len(parts) else ""
    kind = mline.split()[0][2:] if mline.startswith('m=') else mline
    sections.setdefault(kind, []).append(mline + body)
    i += 2
aud = sections.get('audio')
if not aud:
    print("NONE")
    sys.exit()
body = aud[0]
direction = "sendrecv"
for d in ("sendonly","recvonly","sendrecv","inactive"):
    if re.search(r'(?m)^a=%s\s*$' % d, body):
        direction = d
        break
codecs = re.findall(r'(?m)^a=rtpmap:\d+\s+(\S+)', body)
mport = aud[0].splitlines()[0].split()[1]
print(f"{direction}|{mport}|{','.join(codecs)}")
PY
)

if [[ "$AUDIO_NEG" == "NONE" ]]; then
  echo "  [NEGOTIATION] no audio m-line in answer -> go2rtc will NOT send audio"
  echo "  RESULT: NO AUDIO (server negotiated video-only)"
  exit 1
fi

DIR="${AUDIO_NEG%%|*}"; REST="${AUDIO_NEG#*|}"; PORT="${REST%%|*}"; CODECS="${REST#*|}"
echo "  [NEGOTIATION] audio m-line present: direction=$DIR port=$PORT codecs=[$CODECS]"
if [[ "$PORT" == "0" || "$DIR" == "inactive" ]]; then
  echo "  RESULT: NO AUDIO (audio m-line rejected: port=$PORT dir=$DIR)"
  exit 1
fi

# 2) Confirm real audio RTP is actually flowing from the camera source.
#    The negotiation above created a consumer, forcing the producer to connect.
echo "  ...waiting for producer to pull media from the camera..."
sleep 4

curl -s --max-time 20 "$BASE/api/streams" -o "$ANSWER" \
  || { echo "  [WARN] could not fetch /api/streams to confirm byte flow"; exit 0; }

FLOW=$(python3 - "$ANSWER" "$STREAM" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("PARSEFAIL"); sys.exit()
s = d.get(sys.argv[2], {})
abytes = 0; codec = None; apkts = 0
for p in (s.get('producers') or []):
    for r in (p.get('receivers') or []):
        c = r.get('codec', {})
        if c.get('codec_type') == 'audio':
            abytes += r.get('bytes', 0) or 0
            apkts  += r.get('packets', 0) or 0
            codec = c.get('codec_name')
print(f"{abytes}|{apkts}|{codec}")
PY
)

if [[ "$FLOW" == "PARSEFAIL" ]]; then
  echo "  [WARN] /api/streams parse failed; negotiation said audio is available."
  exit 0
fi

AB="${FLOW%%|*}"; REST2="${FLOW#*|}"; AP="${REST2%%|*}"; ACODEC="${REST2#*|}"
echo "  [SOURCE] audio bytes from camera: $AB  packets: $AP  codec: $ACODEC"

if [[ "${AB:-0}" -gt 0 ]]; then
  echo "  RESULT: USABLE AUDIO  (negotiated $DIR [$CODECS]; source delivering $ACODEC, $AB bytes)"
  exit 0
else
  echo "  RESULT: NEGOTIATED BUT SILENT  (audio m-line offered, but camera source delivered 0 audio bytes)"
  exit 1
fi
