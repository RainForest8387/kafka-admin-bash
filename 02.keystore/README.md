# Unified Kafka Keystore Tool

Этот инструмент объединяет 4 сценария в одном Bash-файле:

- `server-keystore`
- `server-truststore`
- `client-keystore`
- `client-truststore`

Файл скрипта: `kafka-keystore-tool.sh`

## 1. Подготовка

Сделайте файл исполняемым:

```bash
chmod +x kafka-keystore-tool.sh
```

Проверьте наличие необходимых утилит:
	•	Для  server-keystore  и  client-keystore :  openssl ,  keytool 
	•	Для  server-truststore  и  client-truststore :  keytool 

Посмотреть справку:
```bash
./kafka-keystore-tool.sh help
```
2. Команда server-keystore

Создаёт:
	•	 server.keystore.p12 
	•	 server.keystore.jks 
Что должно лежать в текущей папке
	•	серверный сертификат, например  kfk-tst-pci.cer 
	•	приватный ключ, например  kfk-tst-pci.key 
Запуск
```bash
./kafka-keystore-tool.sh server-keystore
```
Что спросит скрипт
	1.	 cert_name  — имя сертификата, например  kfk-tst-pci.cer 
	2.	 key_name  — имя приватного ключа, например  kfk-tst-pci.key 
	3.	 cert_alias_name  — alias, например  kfk-tst-pci 
	4.	 storepass  — пароль для keystore
Что делает
	•	проверяет  openssl  и  keytool 
	•	проверяет наличие файлов сертификата и ключа
	•	проверяет, что сертификат и ключ соответствуют друг другу
	•	создаёт  server.keystore.p12 
	•	конвертирует его в  server.keystore.jks 
	•	показывает содержимое итогового JKS
Результат
В текущей директории появятся:
	•	 server.keystore.p12 
	•	 server.keystore.jks 

3. Команда client-keystore
Создаёт:
	•	 client.keystore.p12 
	•	 client.keystore.jks 
Что должно лежать в текущей папке
	•	клиентский сертификат, например  kfk-tst-pci.cer 
	•	приватный ключ, например  kfk-tst-pci.key 
Запуск
```bash
./kafka-keystore-tool.sh client-keystore
```
Что спросит скрипт
	1.	 cert_name  — имя сертификата
	2.	 key_name  — имя приватного ключа
	3.	 cert_alias_name  — alias сертификата
	4.	 storepass  — пароль для keystore
Что делает
	•	проверяет  openssl  и  keytool 
	•	проверяет входные файлы
	•	проверяет соответствие сертификата и ключа
	•	создаёт  client.keystore.p12 
	•	конвертирует его в  client.keystore.jks 
	•	показывает содержимое итогового JKS
Результат
В текущей директории появятся:
	•	 client.keystore.p12 
	•	 client.keystore.jks 


4. Команда server-truststore
Создаёт:
	•	 server.truststore.jks 
	•	 server.truststore.p12 
Что должно лежать в текущей папке
Обязательно:
	•	директория  CA/ 
	•	broker-сертификаты, например  kfk-lt-int01.cer ,  kfk-lt-int02.cer ,  kfk-lt-int03.cer 
	•	client-сертификат, например  kfk-tst-pci-clnt.cer 
В директории  CA/  должны лежать:
	•	 cbm-root-ca.pem 
	•	 issuing.pem 
	•	 mkb-rsa-root-ca.pem 
	•	 mkb-rsa-policy-ca.pem 
	•	 mkb-rsa-issuing-ca1.pem 
Если truststore создаётся не первый раз, дополнительно нужна директория:
	•	 broker_cert_old/ 

В ней могут лежать:
	•	старые broker-сертификаты
	•	старый client-сертификат
Запуск
```bash
./kafka-keystore-tool.sh server-truststore
```

Что спросит скрипт
	1.	подтверждение, что CA-файлы лежат в  CA/ 
	2.	вопрос: это первый выпуск truststore или нет
	3.	 client cert full name , например  kfk-tst-pci-clnt.cer 
	4.	 client cert alias name , например  kfk-tst-pci-clnt 
	5.	 storepass 
	6.	количество брокеров: только  1 ,  3  или  5 
	7.	имена broker-сертификатов без  .cer 
Что делает
	•	проверяет наличие  keytool 
	•	проверяет директорию  CA/ 
	•	проверяет CA-файлы
	•	импортирует broker-сертификаты
	•	если truststore создаётся не первый раз, пытается импортировать старые broker/client сертификаты из  broker_cert_old/ 
	•	импортирует CA-сертификаты
	•	импортирует client-сертификат
	•	создаёт  server.truststore.p12  из  server.truststore.jks 

5. Команда client-truststore
Создаёт:
	•	 client.truststore.jks 
	•	 client.truststore.p12 
Что должно лежать в текущей папке
Обязательно:
	•	директория  CA/ 
	•	broker-сертификаты, например  kfk-lt-int01.cer ,  kfk-lt-int02.cer ,  kfk-lt-int03.cer 
В директории  CA/  должны лежать:
	•	 cbm-root-ca.pem 
	•	 issuing.pem 
	•	 mkb-rsa-root-ca.pem 
	•	 mkb-rsa-policy-ca.pem 
	•	 mkb-rsa-issuing-ca1.pem 
Если truststore создаётся не первый раз, дополнительно нужна директория:
	•	 broker_cert_old/ 
В ней могут лежать старые broker-сертификаты.
Запуск
```bash
./kafka-keystore-tool.sh client-truststore
```
Что спросит скрипт
	1.	подтверждение, что CA-файлы лежат в  CA/ 
	2.	вопрос: это первый выпуск truststore или нет
	3.	 storepass 
	4.	количество брокеров: только  1 ,  3  или  5 
	5.	имена broker-сертификатов без  .cer 
Что делает
	•	проверяет наличие  keytool 
	•	проверяет директорию  CA/ 
	•	проверяет CA-файлы
	•	импортирует broker-сертификаты
	•	если truststore создаётся не первый раз, пытается импортировать старые broker-сертификаты из  broker_cert_old/ 
	•	импортирует CA-сертификаты
	•	создаёт  client.truststore.p12 
	•	затем пересобирает  client.truststore.jks  через временный файл, чтобы явно получить JKS
	•	показывает тип и провайдера итогового keystore


Результат
В текущей директории появятся:
	•	 client.truststore.jks 
	•	 client.truststore.p12 

6. Примеры команд
```bash
./kafka-keystore-tool.sh help
./kafka-keystore-tool.sh server-keystore
./kafka-keystore-tool.sh server-truststore
./kafka-keystore-tool.sh client-keystore
./kafka-keystore-tool.sh client-truststore
```

7. Важные замечания
	•	Скрипт работает в текущей директории, поэтому запускать его нужно там, где лежат сертификаты и директории  CA/  и  broker_cert_old/ .
	•	Если выходные файлы уже существуют, скрипт выведет  WARN  и перезапишет их.
	•	Для truststore допустимое количество broker-узлов: только  1 ,  3  или  5 .
	•	Ввод пароля скрыт.
