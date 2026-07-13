#!/usr/bin/env bash
set -euo pipefail

DAEMON_FILE="/etc/docker/daemon.json"
MAX_SIZE="10m"
MAX_FILE="5"
RESTART_DOCKER="true"

usage() {
  cat <<'EOF'
Usage:
  sudo ./docker-set-log-config.sh [--max-size SIZE] [--max-file COUNT] [--daemon-file PATH] [--no-restart]

Options:
  --max-size SIZE    Max size per Docker log file. Default: 10m
  --max-file COUNT   Number of rotated Docker log files to keep. Default: 5
  --daemon-file PATH Docker daemon config file path. Default: /etc/docker/daemon.json
  --no-restart       Update daemon.json but do not restart Docker
  --help             Show this help text

Notes:
  - This script merges log-driver=json-file and log-opts into the existing daemon.json.
  - Existing containers keep their current logging settings until they are recreated.
EOF
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo 'This script must be run as root (use sudo).' >&2
    exit 1
  fi
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: ${command_name}" >&2
    exit 1
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-size)
      MAX_SIZE="${2:-}"
      shift 2
      ;;
    --max-file)
      MAX_FILE="${2:-}"
      shift 2
      ;;
    --daemon-file)
      DAEMON_FILE="${2:-}"
      shift 2
      ;;
    --no-restart)
      RESTART_DOCKER="false"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "${MAX_SIZE}" ] || [ -z "${MAX_FILE}" ]; then
  echo 'Both --max-size and --max-file require values.' >&2
  exit 1
fi

if ! [[ "${MAX_FILE}" =~ ^[0-9]+$ ]]; then
  echo '--max-file must be an integer.' >&2
  exit 1
fi

require_root
require_command python3

TMP_INPUT="$(mktemp)"
TMP_OUTPUT="$(mktemp)"

cleanup() {
  rm -f "${TMP_INPUT}" "${TMP_OUTPUT}"
}
trap cleanup EXIT

if [ -f "${DAEMON_FILE}" ]; then
  BACKUP_FILE="${DAEMON_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "${DAEMON_FILE}" "${BACKUP_FILE}"
  cp -a "${DAEMON_FILE}" "${TMP_INPUT}"
  echo "Backed up existing daemon config to ${BACKUP_FILE}"
else
  printf '{}\n' > "${TMP_INPUT}"
  echo "No existing daemon config found at ${DAEMON_FILE}; creating a new one."
fi

python3 - "${TMP_INPUT}" "${TMP_OUTPUT}" "${MAX_SIZE}" "${MAX_FILE}" <<'PY'
import json
import sys

input_path, output_path, max_size, max_file = sys.argv[1:5]

with open(input_path, 'r', encoding='utf-8') as infile:
    raw = infile.read().strip()

if raw:
    data = json.loads(raw)
else:
    data = {}

if not isinstance(data, dict):
    raise SystemExit('Docker daemon config must be a JSON object.')

log_opts = data.get('log-opts')
if log_opts is None:
    log_opts = {}
if not isinstance(log_opts, dict):
    raise SystemExit('Existing log-opts value is not a JSON object.')

log_opts['max-size'] = max_size
log_opts['max-file'] = max_file
data['log-driver'] = 'json-file'
data['log-opts'] = log_opts

with open(output_path, 'w', encoding='utf-8') as outfile:
    json.dump(data, outfile, indent=2)
    outfile.write('\n')
PY

install -m 644 "${TMP_OUTPUT}" "${DAEMON_FILE}"
echo "Updated ${DAEMON_FILE}:"
cat "${DAEMON_FILE}"

if [ "${RESTART_DOCKER}" = "true" ]; then
  require_command systemctl
  echo 'Restarting Docker...'
  systemctl restart docker
  echo 'Docker restarted successfully.'
  docker info --format 'LoggingDriver={{.LoggingDriver}}'
else
  echo 'Docker restart skipped. Restart Docker manually for the daemon change to take effect.'
fi

echo 'Existing containers keep their current log settings until they are recreated.'