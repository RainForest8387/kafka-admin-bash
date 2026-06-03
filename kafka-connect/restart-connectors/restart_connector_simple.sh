#!/bin/bash
set -Eeuo pipefail

HOST="http://localhost:8083"
MAX_WAIT=120
CONNECTORS=(
  "TWCMS_NVBO_SOURCE"
  "TWCMS_MCB_BO_SINK"
)

# === Цвета ===
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}✓ $*${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
log_err()  { echo -e "${RED}✗ $*${NC}"; }

# === Проверка здоровья (все компоненты строго RUNNING) ===
is_running() {
  local connector="$1"
  local status
  if ! status=$(curl -sS --connect-timeout 5 "$HOST/connectors/$connector/status" 2>/dev/null); then
    return 1
  fi
  local total_components running_components
  # grep возвращает код 1, если совпадений нет; под pipefail+set -e это уронило бы
  # скрипт, поэтому гасим код возврата через "|| true". На значение это не влияет:
  # wc -l на пустом вводе выводит 0.
  total_components=$(echo "$status" | grep -o '"state":' | wc -l) || true
  running_components=$(echo "$status" | grep -o '"state":"RUNNING"' | wc -l) || true
  [ "$total_components" -gt 0 ] && [ "$running_components" -eq "$total_components" ]
}

# === Основной цикл ===
for CONNECTOR in "${CONNECTORS[@]}"; do
  echo ""
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Коннектор: $CONNECTOR"

  # 1. Pause
  if ! curl -sS --connect-timeout 5 -X PUT "$HOST/connectors/$CONNECTOR/pause" >/dev/null; then
    log_err "Не удалось отправить команду PAUSE для $CONNECTOR"
    continue
  fi

  # 2. Ожидание плавной остановки (пока количество RUNNING не станет равно 0)
  echo "Ожидание перехода тасок в PAUSED..."
  stopped=false
  for ((elapsed=0; elapsed<=MAX_WAIT; elapsed+=2)); do
    STATUS=$(curl -sS --connect-timeout 5 "$HOST/connectors/$CONNECTOR/status" 2>/dev/null) || STATUS=""

    if [ -n "$STATUS" ]; then
      RUNNING=$(echo "$STATUS" | grep -o '"state":"RUNNING"' | wc -l) || true
      if [ "$RUNNING" -eq 0 ]; then
        log_ok "Все active-процессы коннектора $CONNECTOR остановлены (${elapsed}с)."
        stopped=true
        break
      fi
    else
      log_warn "Пустой ответ от API на ${elapsed}с (возможна GC-пауза), ждём..."
    fi
    sleep 2
  done

  if [ "$stopped" = false ]; then
    log_warn "$CONNECTOR не остановился за ${MAX_WAIT}с — пропускаем во избежание дублей батчей."
    continue
  fi

  # 3. Перезапуск
  echo "Выполнение команды RESTART..."
  if ! curl -sS --connect-timeout 5 -X POST \
       "$HOST/connectors/$CONNECTOR/restart?includeTasks=true&onlyFailed=false" >/dev/null; then
    log_err "Не удалось отправить команду RESTART для $CONNECTOR — пропускаем."
    continue
  fi
  sleep 4

  # 4. RESUME + ожидание полного запуска
  echo "Выполнение команды RESUME..."
  if ! curl -sS --connect-timeout 5 -X PUT "$HOST/connectors/$CONNECTOR/resume" >/dev/null; then
    log_err "Не удалось отправить команду RESUME для $CONNECTOR — пропускаем."
    continue
  fi

  resumed=false
  for ((elapsed=0; elapsed<=MAX_WAIT; elapsed+=2)); do
    if is_running "$CONNECTOR"; then
      log_ok "Коннектор $CONNECTOR полностью исправен (ALL RUNNING) за ${elapsed}с."
      resumed=true
      break
    fi
    sleep 2
  done

  if [ "$resumed" = false ]; then
    log_warn "Коннектор $CONNECTOR не вышел в ALL RUNNING за ${MAX_WAIT}с после RESUME."
  fi
done
