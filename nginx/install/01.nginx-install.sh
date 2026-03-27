#!/bin/bash

# Скрипт для развертывания nginx
# Использование: ./01.nginx-install.sh

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода цветных сообщений
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка что скрипт запущен с правами суперпользователя
if [ "$(id -u)" -ne 0 ]; then
    log_error "ERROR: must be run as root "
    sleep 10
    exit 1
fi


log_info "Устнановка deb пакетов"

apt install -y nginx apache2-utils

sleep 0.5

echo ""
log_success "============================================"
log_success "  Nginx успешно развернут!"
log_success "============================================"
echo ""

sleep 0.5
log_info "Первичная настройка для ssl & basic auth "

mkdir -p /etc/nginx/htpasswd
mkdir -p /etc/nginx/ssl/
chmod  700 /etc/nginx/ssl
find -name "*.key" -exec cp /etc/nginx/ssl/ {} \;
find -name "*.cer" -exec cp /etc/nginx/ssl/ {} \;
find -name "*.pem" -exec cp /etc/nginx/ssl/ {} \;
find /etc/nginx/ssl -name "*.key" -exec chmod 400 {} \;
find /etc/nginx/ssl -name "*.cer" -exec chmod 644 {} \;
find /etc/nginx/ssl -name "*.pem" -exec chmod 644 {} \;

rm -f /etc/nginx/sites-enabled/default
touch  /etc/nginx/sites-available/01.443.conf
ln -s   /etc/nginx/sites-available/01.443.conf /etc/nginx/sites-enabled/

mkdir -p /etc/nginx/htpasswd

chgrp -R www-data /etc/nginx/htpasswd
chmod 750 /etc/nginx/htpasswd

sleep 0.5

echo ""
log_success "============================================"
log_success "  Первичная настройка для ssl & basic auth завершена!"
log_success "============================================"
echo ""


echo ""
log_info "Полезные команды:"
echo ""
echo "  Проерить корректность конфигов"
echo "    sudo nginx -T | grep nginx:"
echo ""
echo "  Перечитать конфигурацию без рестарта nginx"
echo "    sudo nginx -s reload"
echo ""
