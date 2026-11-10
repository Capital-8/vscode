#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See License.txt in the project root for license information.

set -e

# Get snapcraft version
snapcraft --version

# Configure apt to retry on transient network failures
# This applies to both the apt commands below and snapcraft's internal apt operations for stage-packages
sudo sh -c 'echo "Acquire::Retries \"5\";" > /etc/apt/apt.conf.d/80-retries'

# Abandon a stalled connection after 15s instead of apt's default 120s. snapcraft
# fetches stage-packages one at a time, and when the mirror stalls a connection the
# retry on a new one usually succeeds at once; with the default, 35 such stalls took
# 70 minutes and the job hit its time limit. The timeout applies to inactivity, so
# slow but progressing downloads are unaffected.
sudo sh -c 'echo "Acquire::http::Timeout \"15\";" > /etc/apt/apt.conf.d/80-timeout'

# Point apt at the Azure Ubuntu mirror. The build agents cannot reach
# archive.ubuntu.com/ports.ubuntu.com (DNS resolves them to a non-routable
# TEST-NET address, so connections time out), whereas the Azure mirror is
# reachable. This must run before any apt operation and before snapcraft, since
# snapcraft copies the host's /etc/apt configuration to download stage-packages.
for src in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [ -f "$src" ] || continue
  sudo sed -i \
    -e 's|http://archive.ubuntu.com|http://azure.archive.ubuntu.com|g' \
    -e 's|http://ports.ubuntu.com|http://azure.ports.ubuntu.com|g' \
    "$src"
done

# Make sure we get latest packages
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y curl apt-transport-https ca-certificates

# PROOF ONLY, do not merge: route snapcraft's stage-package downloads through a local
# proxy that never answers the first request for every 10th .deb, so apt has to time
# the connection out and retry.
command -v python3 >/dev/null || { echo "PROOF: python3 is missing" >&2; exit 1; }
cat > /tmp/stall-proxy.py <<'PY'
import http.server, socketserver, sys, threading, time, urllib.error, urllib.request
seen = set(); lock = threading.Lock(); count = [0]; stalls = [0]
class Handler(http.server.BaseHTTPRequestHandler):
	protocol_version = 'HTTP/1.0'
	def do_GET(self):
		url = self.path
		if url.endswith('.deb'):
			with lock:
				first = url not in seen
				seen.add(url)
				if first:
					count[0] += 1
				stall = first and count[0] % 10 == 1
				if stall:
					stalls[0] += 1
			if stall:
				sys.stderr.write(f'[stall-proxy] stall #{stalls[0]}: {url}\n'); sys.stderr.flush()
				time.sleep(600)
				return
		try:
			with urllib.request.urlopen(url, timeout=60) as r:
				self.send_response(r.status)
				for k, v in r.getheaders():
					if k.lower() not in ('connection', 'transfer-encoding'):
						self.send_header(k, v)
				self.send_header('Connection', 'close')
				self.end_headers()
				while True:
					b = r.read(65536)
					if not b:
						break
					self.wfile.write(b)
		except urllib.error.HTTPError as e:
			self.send_response(e.code); self.send_header('Connection', 'close'); self.end_headers()
		except Exception:
			try:
				self.send_error(502)
			except Exception:
				pass
	def log_message(self, *args):
		pass
class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
	daemon_threads = True
Server(('127.0.0.1', 3128), Handler).serve_forever()
PY
python3 /tmp/stall-proxy.py &
sleep 2
sudo sh -c 'echo "Acquire::http::Proxy \"http://127.0.0.1:3128\";" > /etc/apt/apt.conf.d/99-proof-stall-proxy'

# Define variables
SNAP_ROOT="$(pwd)/.build/linux/snap/$VSCODE_ARCH"

# Create snap package
BUILD_VERSION="$(date +%s)"
SNAP_FILENAME="code-$VSCODE_QUALITY-$VSCODE_ARCH-$BUILD_VERSION.snap"
SNAP_PATH="$SNAP_ROOT/$SNAP_FILENAME"
case $VSCODE_ARCH in
  x64) SNAPCRAFT_TARGET_ARGS="" ;;
  *) SNAPCRAFT_TARGET_ARGS="--target-arch $VSCODE_ARCH" ;;
esac
(
  set -o pipefail
  cd "$SNAP_ROOT"/code-*
  snapcraftLog=$(mktemp)
  trap 'rm -f "$snapcraftLog"' EXIT

  # Snapcraft 7.5.3 saves global state before running any part; only retry before that.
  # Recheck this boundary when upgrading the pinned image:
  # https://github.com/canonical/snapcraft/blob/7.5.3/snapcraft_legacy/internal/lifecycle/_runner.py#L121-L145
  # Three backoffs with jitter, then a final attempt (0 means no more retries).
  for delay in 30 60 120 0; do
    if sudo --preserve-env snapcraft snap $SNAPCRAFT_TARGET_ARGS --output "$SNAP_PATH" 2>&1 | tee "$snapcraftLog"; then
      break
    else
      exitCodes=("${PIPESTATUS[@]}")
    fi

    (( exitCodes[1] == 0 )) || exit "${exitCodes[1]}"

    if (( delay == 0 || exitCodes[0] != 1 )) ||
      [[ -e parts/.snapcraft_global_state ]] ||
      ! grep -Fxq 'Starting Snapcraft 7.5.3' "$snapcraftLog" ||
      [[ "$(awk 'NF { last = $0 } END { print last }' "$snapcraftLog")" != 'Issue encountered while processing your request: [429] Too Many Requests.' ]]; then
      exit "${exitCodes[0]}"
    fi

    delay=$((delay + RANDOM % 30))
    echo "Snap Store HTTP 429 before any parts ran; retrying initialization in ${delay}s." >&2
    sleep "$delay"
  done
)
