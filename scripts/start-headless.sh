#!/bin/bash
# Headless browser launcher for cdp-proxy
# Defaults to Playwright's headless_shell (lightweight Chromium)

set -euo pipefail

# Allow override via env var
: "${HEADLESS_BROWSER:=/root/.cache/ms-playwright/chromium_headless_shell-1217/chrome-headless-shell-linux64/chrome-headless-shell}"
: "${CDP_PORT:=9222}"
: "${USER_DATA_DIR:=/tmp/headless-browser-profile}"

echo "[headless] Starting browser: $HEADLESS_BROWSER"
echo "[headless] CDP port: $CDP_PORT"

exec "$HEADLESS_BROWSER" \
  --remote-debugging-port="$CDP_PORT" \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --user-data-dir="$USER_DATA_DIR" \
  about:blank
