#!/bin/bash
set -Eeuo pipefail

HOST="http://$HOSTNAME:8084"
MAX_WAIT=120
SLEEP_STEP=2

CONNECTORS=(
  "TWCMS_NVBO_SOURCE"
  "TWCMS_MCB_BO_SINK"
)

LOG_DIR="/var/log/kafka-connect"
LOG_FILE="$LOG_DIR/restart_connectors.log"
LOCK_FILE="/tmp/restart-connectors.lock"
TMP_RESP="/tmp/restart-connectors-response.$$"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 0640 "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[$(date '+%F %T')] Скрипт уже выполняется, выходим"
  exit 1
fi

cleanup() {
  rm -f "$TMP_RESP"
}
trap cleanup EXIT

log() {
  echo "[$(date '+%F %T')] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Не найдена обязательная команда: $1"
    exit 1
  }
}

api_code() {
  local method="$1"
  local url="$2"

  curl -sS \
    --connect-timeout 5 \
    --max-time 30 \
    -H 'Accept: application/json' \
    -X "$method" \
    -o "$TMP_RESP" \
    -w '%{http_code}' \
    "$url"
}

get_status() {
  curl -sS \
    --connect-timeout 5 \
    --max-time 30 \
    -H 'Accept: application/json' \
    "$HOST/connectors/$1/status"
}

wait_until_paused() {
  local connector="$1"
  local elapsed=0
  local status connector_state running restarting

  while (( elapsed <= MAX_WAIT )); do
    if ! status=$(get_status "$connector"); then
      log "$connector: не удалось получить status при ожидании pause"
      return 1
    fi

    connector_state=$(jq -r '.connector.state // "UNKNOWN"' <<<"$status")
    running=$(jq '[.connector.state, (.tasks[]?.state)] | map(select(. == "RUNNING")) | length' <<<"$status")
    restarting=$(jq '[.connector.state, (.tasks[]?.state)] | map(select(. == "RESTARTING")) | length' <<<"$status")

    if [[ "$connector_state" == "PAUSED" && "$running" -eq 0 && "$restarting" -eq 0 ]]; then
      log "$connector: pause завершен"
      return 0
    fi

    sleep "$SLEEP_STEP"
    elapsed=$((elapsed + SLEEP_STEP))
  done

  log "$connector: timeout ожидания PAUSED (${MAX_WAIT} сек)"
  return 1
}

print_status() {
  local connector="$1"
  local status

  if ! status=$(get_status "$connector"); then
    log "$connector: не удалось получить итоговый status"
    return 1
  fi

  jq -r '
    "name=" + (.name // "unknown"),
    "connector_state=" + (.connector.state // "UNKNOWN"),
    (.tasks[]? | "task_id=" + (.id|tostring) + " state=" + (.state // "UNKNOWN") + " worker=" + (.worker_id // "-") )
  ' <<<"$status"
}

require_cmd curl
require_cmd jq
require_cmd flock

log "===== start ====="

for CONNECTOR in "${CONNECTORS[@]}"; do
  log "Коннектор: $CONNECTOR"

  code=$(api_code PUT "$HOST/connectors/$CONNECTOR/pause") || {
    log "$CONNECTOR: ошибка сети при pause"
    continue
  }

  if [[ "$code" != "200" && "$code" != "202" && "$code" != "204" ]]; then
    log "$CONNECTOR: pause вернул HTTP $code"
    [[ -s "$TMP_RESP" ]] && cat "$TMP_RESP"
    continue
  fi

  if ! wait_until_paused "$CONNECTOR"; then
    log "$CONNECTOR: restart/resume пропущены"
    continue
  fi

  code=$(api_code POST "$HOST/connectors/$CONNECTOR/restart?includeTasks=true&onlyFailed=false") || {
    log "$CONNECTOR: ошибка сети при restart"
    continue
  }

  if [[ "$code" != "200" && "$code" != "202" && "$code" != "204" ]]; then
    log "$CONNECTOR: restart вернул HTTP $code"
    [[ -s "$TMP_RESP" ]] && cat "$TMP_RESP"
    continue
  fi

  sleep 4

  code=$(api_code PUT "$HOST/connectors/$CONNECTOR/resume") || {
    log "$CONNECTOR: ошибка сети при resume"
    continue
  }

  if [[ "$code" != "200" && "$code" != "202" && "$code" != "204" ]]; then
    log "$CONNECTOR: resume вернул HTTP $code"
    [[ -s "$TMP_RESP" ]] && cat "$TMP_RESP"
    continue
  }

  log "$CONNECTOR: итоговый статус"
  print_status "$CONNECTOR"
done

log "===== finish ====="
