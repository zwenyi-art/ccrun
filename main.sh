#!/usr/bin/env bash
# vl.sh — Cloud Run SSH deploy + Telegram notify (Loop Version)
set -euo pipefail

# ===== Config (env override-able) =====
IMAGE="${IMAGE:-nynyjk/eioubc:here}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-hereandnowssh}"
LOOP_COUNT="${LOOP_COUNT:-2}"   # <- number of loop runs

CPU="${CPU:-6}"
MEMORY="${MEMORY:-4Gi}"
TIMEOUT="${TIMEOUT:-3600}"
MIN_INSTANCES="${MIN_INSTANCES:-1}"
PORT="${PORT:-8080}"
WSPATH="${WSPATH:-/myanmar}"

DURATION_HOURS="${DURATION_HOURS:-5}"

TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# ===== Helpers =====
abort(){ echo "Error: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || abort "Missing dependency: $1"; }

yangon_now_epoch(){ TZ="Asia/Yangon" date +%s; }
yangon_fmt_epoch(){ TZ="Asia/Yangon" date -d "@$1" "+%-I:%M %p,%-d.%-m.%Y(ASIA/YANGON)"; }

html_escape(){ sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

tg_send(){
  local text="$1"

  if [[ -z "$TELEGRAM_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    echo "Skip Telegram"
    return 0
  fi

  local resp code body

  resp="$(curl -sS -w '\n%{http_code}' -X POST \
    "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data "parse_mode=HTML" \
    --data "disable_web_page_preview=true")"

  code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"

  [[ "$code" == "200" ]] && return 0

  echo "Telegram failed: $body"
}

enable_api(){
  local api="$1"
  gcloud services enable "$api" --quiet >/dev/null 2>&1 || true
}

# ===== Checks & Auto-Setup =====
need gcloud
need curl

# --- NEW: AUTO-DETECT PROJECT ID ---
# 1. Try to read the current project
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"

# 2. If it is empty, find the first project in your list
if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
    echo "🔍 Project ID not set. Searching for one..."
    # This command gets the first project ID from your account
    PROJECT="$(gcloud projects list --format="value(projectId)" --limit=1)"
fi

# 3. If we still don't have one, then we must stop
if [[ -z "$PROJECT" ]]; then
    abort "No Google Cloud Project found! Please run: 'gcloud auth login' first."
fi

# 4. Set the project officially so the rest of the script works
echo "🚀 Using Project ID: $PROJECT"
gcloud config set project "$PROJECT" --quiet
# -----------------------------------

enable_api "run.googleapis.com"

# ===== LOOP START =====
for ((i=1;i<=LOOP_COUNT;i++)); do

  echo "===== LOOP $i / $LOOP_COUNT ====="

  SERVICE_LOOP="${SERVICE}-${i}"

  START_TS="$(yangon_now_epoch)"
  END_TS="$(( START_TS + DURATION_HOURS * 3600 ))"

  START_TIME="$(yangon_fmt_epoch "$START_TS")"
  END_TIME="$(yangon_fmt_epoch "$END_TS")"

  echo "Deploying ${SERVICE_LOOP}..."

  gcloud run deploy "$SERVICE_LOOP" \
    --image "$IMAGE" \
    --region "$REGION" \
    --platform managed \
    --execution-environment gen2 \
    --allow-unauthenticated \
    --min-instances "$MIN_INSTANCES" \
    --cpu "$CPU" \
    --memory "$MEMORY" \
    --timeout "$TIMEOUT" \
    --port "$PORT" \
    --set-env-vars "WSPATH=${WSPATH}"

  URL="$(gcloud run services describe "$SERVICE_LOOP" --region "$REGION" --format='value(status.url)')"
  HOST="${URL#https://}"

  PAYLOAD="GET ${WSPATH} HTTP/1.1
Host:${HOST}
Connection:Upgrade
Upgrade:Websocket
User-Agent: Googlebot/2.1 (+http://www.google.com/bot.html)[crlf][crlf]"

  PAYLOAD_ESCAPED="$(echo "$PAYLOAD" | html_escape)"

read -r -d '' MSG <<EOF || true
☁️ <b>Google Cloud / Cloud Run SSH</b>

<blockquote><b>Payload</b></blockquote>
<pre><code>${PAYLOAD_ESCAPED}</code></pre>

<blockquote><b>host&amp;port/username&amp;pass</b></blockquote>
<pre><code>192.168.100.1:443@a:abc</code></pre>

<blockquote><b>Proxy&amp;Port</b></blockquote>
<pre><code>vpn.googleapis.com:443</code></pre>

<blockquote><b>SNI</b></blockquote>
<pre><code>vpn.googleapis.com</code></pre>

<b>URL:</b> ${URL}
<b>Start:</b> ${START_TIME}
<b>End:</b> ${END_TIME}
EOF

  tg_send "$MSG"

  echo "✅ Done! URL = $URL"
  echo

done

echo "🎉 All loops completed!"