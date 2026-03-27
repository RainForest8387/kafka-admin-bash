# kafka-admin-bash

## Подготовка 
Сохраните список пользователей в файл  users.txt  в формате  username:password  (один на строку), например:
```
admin:secretpass
user1:mypassword
user2:anotherpass
```



## Использование
Сделайте скрипт исполняемым и запустите:
```bash
chmod +x add_users.sh
sudo ./add_users.sh users.txt
```
*	Скрипт требует sudo для записи в `etc/nginx/`.
*	`-c` используется только для первого пользователя (создаёт файл); для остальных — добавление без `-c`, чтобы не стирать существующих.
*	Для безопасности: удалите  users.txt  после выполнения 

## Nginx
В конфиге Nginx добавьте:
```nginx
location / {
    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/htpasswd/kafka-ui-wr.htpasswd;
}
```
