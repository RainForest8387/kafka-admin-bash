#!/bin/bash

HTPASSWD_FILE="/etc/nginx/htpasswd/kafka-ui-wr.htpasswd"
USERS_FILE="${1:-users.txt}"  # Первый аргумент - файл пользователей, по умолчанию users.txt

# Проверка существования файла пользователей
if [[ ! -f "$USERS_FILE" ]]; then
  echo "Ошибка: Файл $USERS_FILE не найден!"
  exit 1
fi

# Создание директории, если не существует
sudo mkdir -p "$(dirname "$HTPASSWD_FILE")"

# Создание/перезапись файла с первым пользователем
first_user=true
while IFS=':' read -r username password; do
  # Пропуск пустых строк
  [[ -z "$username" || -z "$password" ]] && continue

  if [[ "$first_user" == true ]]; then
    echo "Создание файла и добавление пользователя: $username"
    sudo htpasswd -b -B -c "$HTPASSWD_FILE" "$username" "$password" || exit 1
    first_user=false
  else
    echo "Добавление пользователя: $username"
    sudo htpasswd -b -B "$HTPASSWD_FILE" "$username" "$password" || exit 1
  fi
done < "$USERS_FILE"

echo "Готово! Файл $HTPASSWD_FILE обновлён."
echo "Проверьте: sudo cat $HTPASSWD_FILE"
