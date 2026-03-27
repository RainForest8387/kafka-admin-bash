#!/bin/bash

HTPASSWD_FILE="/etc/nginx/htpasswd/kafka-ui-wr.htpasswd"
USERS_FILE="${1:-users.txt}"

# Проверка существования файла пользователей
if [[ ! -f "$USERS_FILE" ]]; then
  echo "❌ Ошибка: Файл $USERS_FILE не найден!"
  exit 1
fi

# Создание директории если не существует
sudo mkdir -p "$(dirname "$HTPASSWD_FILE")"

# Флаг для первого пользователя
first_user=true
skip_first=false

echo "📋 Обрабатываем пользователей из $USERS_FILE..."

# Проверим, существует ли файл htpasswd
if [[ -f "$HTPASSWD_FILE" ]]; then
  echo "📁 Файл $HTPASSWD_FILE уже существует."
else
  echo "📁 Файл $HTPASSWD_FILE не существует."
fi

while IFS= read -r username; do
  # Пропуск пустых строк и комментариев
  [[ -z "$username" || "$username" =~ ^# ]] && continue

  echo -e "\n👤 Обрабатываем пользователя: $username"

  # Для первого пользователя спрашиваем, добавлять ли его
  if [[ "$first_user" == true ]]; then
    if [[ -f "$HTPASSWD_FILE" ]]; then
      echo -n "Добавить первого пользователя '$username' в уже существующий файл? (y/n) [y]: "
    else
      echo -n "Создать файл и добавить первого пользователя '$username'? (y/n) [y]: "
    fi

    read -r answer
    answer=${answer:-y}

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      echo "❌ Первый пользователь '$username' пропущен."
      skip_first=true
    else
      echo "✅ Первый пользователь '$username' будет добавлен."
      skip_first=false
    fi

    first_user=false
  fi

  # Если первый пользователь пропущен, переходим к следующему
  if [[ "$first_user" == false && "$skip_first" == true ]]; then
    skip_first=false
    continue
  fi

  # Отключаем историю bash для безопасности
  set +H

  # Генерация безопасного пароля
  password=$(openssl rand -base64 24 | tr -d /=+ | cut -c1-32)

  # Включаем историю обратно
  set -H

  echo "🔑 Сгенерированный пароль: $password"

  if [[ "$first_user" == true ]]; then
    # Проверяем существование файла
    if [[ -f "$HTPASSWD_FILE" ]]; then
      echo "➕ Добавляем первого пользователя в существующий файл..."
      sudo htpasswd -b -m "$HTPASSWD_FILE" "$username" "$password"
    else
      echo "📁 Создаём файл и добавляем первого пользователя..."
      sudo htpasswd -b -m -c "$HTPASSWD_FILE" "$username" "$password"
    fi
    first_user=false
  else
    # Добавляем остальных пользователей
    echo "➕ Добавляем в существующий файл..."
    sudo htpasswd -b -m "$HTPASSWD_FILE" "$username" "$password"
  fi

  if [[ $? -eq 0 ]]; then
    echo "✅ Пользователь $username успешно добавлен"
  else
    echo "❌ Ошибка при добавлении пользователя $username"
    exit 1
  fi

done < "$USERS_FILE"

echo -e "\n🎉 Готово!"
echo "📄 Файл: $HTPASSWD_FILE"
echo "👥 Количество записей: $(sudo wc -l < "$HTPASSWD_FILE")"
echo "🔍 Проверить: sudo cat $HTPASSWD_FILE"
echo ""
echo "⚠️  ВАЖНО: Сохраните пароли в безопасное место!"
