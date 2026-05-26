#!/bin/bash
set -Eeuo pipefail

HOST="http://$HOSTNAME:8084"
MAX_WAIT=120
SLEEP_STEP=2
RETRY_COUNT=12
RETRY_DELAY=5

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

get_status() {
  curl -sS \
    --connect-timeout 5 \
    --max-time 30 \
    -H 'Accept: application/json' \
    "$HOST/connectors/$1/status"
}

is_running() {
  local connector="$1"
  local status
  local connector_state
  local failed
  local not_running

  if ! status=$(get_status "$connector"); then
    return 1
  fi

  connector_state=$(jq -r '.connector.state // "UNKNOWN"' <<<"$status")
  failed=$(jq '[.tasks[]?.state, .connector.state] | map(select(. == "FAILED")) | length' <<<"$status")
  not_running=$(jq '[.tasks[]?.state] | map(select(. != "RUNNING")) | length' <<<"$status")

  [[ "$connector_state" == "RUNNING" && "$failed" -eq 0 && "$not_running" -eq 0 ]]
}

api_with_retry() {
  local method="$1"
  local url="$2"
  local retries="${3:-$RETRY_COUNT}"
  local delay="${4:-$RETRY_DELAY}"

  local attempt=1
  local code

  while (( attempt <= retries )); do
    code=$(curl -sS \
      --connect-timeout 5 \
      --max-time 30 \
      -H 'Accept: application/json' \
      -X "$method" \
      -o "$TMP_RESP" \
      -w '%{http_code}' \
      "$url") || {
        log "Сетевая ошибка при $method $url, попытка $attempt/$retries"
        sleep "$delay"
        attempt=$((attempt + 1))
        continue
      }

    case "$code" in
      200|202|204)
        return 0
        ;;
      409)
        log "HTTP 409 для $method $url, вероятно идет rebalance, попытка $attempt/$retries"
        [[ -s "$TMP_RESP" ]] && cat "$TMP_RESP"
        sleep "$delay"
        attempt=$((attempt + 1))
        ;;
      *)
        log "HTTP $code для $method $url"
        [[ -s "$TMP_RESP" ]] && cat "$TMP_RESP"
        return 1
        ;;
    esac
  done

  log "Превышено число попыток для $method $url после HTTP 409/сетевых ошибок"
  return 1
}

wait_until_paused() {
  local connector="$1"
  local elapsed=0
  local status connector_state running restarting

  while (( elapsed <= MAX_WAIT )); do
    if ! status=$(get_status "$connector"); then
      log "$connector: не удалось получить статус при ожидании PAUSED"
      return 1
    fi

    connector_state=$(jq -r '.connector.state // "UNKNOWN"' <<<"$status")
    running=$(jq '[.connector.state, (.tasks[]?.state)] | map(select(. == "RUNNING")) | length' <<<"$status")
    restarting=$(jq '[.connector.state, (.tasks[]?.state)] | map(select(. == "RESTARTING")) | length' <<<"$status")

    if [[ "$connector_state" == "PAUSED" && "$running" -eq 0 && "$restarting" -eq 0 ]]; then
      log "$connector: PAUSED завершен"
      return 0
    fi

    sleep "$SLEEP_STEP"
    elapsed=$((elapsed + SLEEP_STEP))
  done

  log "$connector: timeout ожидания PAUSED (${MAX_WAIT} сек)"
  return 1
}

wait_until_running() {
  local connector="$1"
  local elapsed=0
  local status connector_state failed not_running

  while (( elapsed <= MAX_WAIT )); do
    if ! status=$(get_status "$connector"); then
      log "$connector: не удалось получить статус при ожидании RUNNING"
      return 1
    fi

    connector_state=$(jq -r '.connector.state // "UNKNOWN"' <<<"$status")
    failed=$(jq '[.tasks[]?.state, .connector.state] | map(select(. == "FAILED")) | length' <<<"$status")
    not_running=$(jq '[.tasks[]?.state] | map(select(. != "RUNNING")) | length' <<<"$status")

    if [[ "$connector_state" == "RUNNING" && "$failed" -eq 0 && "$not_running" -eq 0 ]]; then
      log "$connector: connector и все tasks в состоянии RUNNING"
      return 0
    fi

    sleep "$SLEEP_STEP"
    elapsed=$((elapsed + SLEEP_STEP))
  done

  log "$connector: timeout ожидания RUNNING (${MAX_WAIT} сек)"
  return 1
}

print_status() {
  local connector="$1"
  local status

  if ! status=$(get_status "$connector"); then
    log "$connector: не удалось получить итоговый статус"
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

  if ! api_with_retry PUT "$HOST/connectors/$CONNECTOR/pause"; then
    log "$CONNECTOR: pause не выполнен"
    continue
  fi

  if ! wait_until_paused "$CONNECTOR"; then
    log "$CONNECTOR: restart/resume пропущены"
    continue
  fi

  if ! api_with_retry POST "$HOST/connectors/$CONNECTOR/restart?includeTasks=true&onlyFailed=false"; then
    if is_running "$CONNECTOR"; then
      log "$CONNECTOR: restart вернул ошибки, но connector уже RUNNING без FAILED/non-RUNNING tasks"
    else
      log "$CONNECTOR: restart не выполнен"
      continue
    fi
  fi

  sleep 4

  if ! api_with_retry PUT "$HOST/connectors/$CONNECTOR/resume"; then
    if is_running "$CONNECTOR"; then
      log "$CONNECTOR: resume вернул ошибки, но connector уже RUNNING без FAILED/non-RUNNING tasks"
    else
      log "$CONNECTOR: resume не выполнен"
      continue
    fi
  fi

  if ! wait_until_running "$CONNECTOR"; then
    log "$CONNECTOR: после resume connector не перешел в RUNNING вовремя"
  fi

  log "$CONNECTOR: итоговый статус"
  print_status "$CONNECTOR"
done

log "===== finish ====="
