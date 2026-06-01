# Agent PODD

####  Логи  контейнера в формате MSK
`log_save.sh`
```bash
#!/bin/bash

NAME="einfahrt"
LOGFILE="log-$(date +%Y%m%d-%H%M%S).txt"

echo "Check for container presence, gathering log"
if [ ! -z "$(docker ps -a | awk '{print $NF}' | grep "^${NAME}$")" ]; then
    
    echo "Processing logs ..."

    docker logs ${NAME} --timestamps 2>&1 | awk '
    {
        # Проверяем, начинается ли строка с формата Docker (например, 2026-06-01T...)
        if ($1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) {
            
            # Разбиваем на составляющие времени
            match($1, /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})/, timepart)
            
            # Формируем строку для mktime (формат: "YYYY MM DD HH MM SS")
            spec = timepart[1] " " timepart[2] " " timepart[3] " " timepart[4] " " timepart[5] " " timepart[6]
            
            # Конвертируем UTC в Unix-timestamp и добавляем 3 часа (10800 секунд) для формата Europe/Moscow
            moscow_timestamp = mktime(spec) + 10800
            
            # Форматируем обратно в читаемую дату
            local_time = strftime("[%Y-%m-%d %H:%M:%S]", moscow_timestamp)
            
            # Отсекаем дату и время в формате UTC и выводим строку с новым временем
            sub(/^[^ ]+ /, "")
            print local_time " " $0
        } else {
            # Если строка не имеет даты и времени выводим как есть
            print $0
        }
    }' > "${LOGFILE}"

    echo "Log file gathered; See ${LOGFILE} for details"
else
    echo "ERROR: No container process found"
    exit 1
fi
```

`log.sh`
```bash
#!/bin/bash

NAME="einfahrt"

echo "Check for container presence, gathering log"
if [ ! -z "$(docker ps -a | awk '{print $NF}' | grep "^${NAME}$")" ]; then
    echo -e "Press Ctrl-C to stop log output\n\n"
    
    
    docker logs ${NAME} -f --tail=10 --timestamps 2>&1 | awk '
    {
        if ($1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) {
            match($1, /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})/, timepart)
            spec = timepart[1] " " timepart[2] " " timepart[3] " " timepart[4] " " timepart[5] " " timepart[6]
            
            # Конвертируем UTC в Unix-timestamp и добавляем 3 часа (10800 секунд) для формата Europe/Moscow
            moscow_timestamp = mktime(spec) + 10800
            local_time = strftime("[%Y-%m-%d %H:%M:%S]", moscow_timestamp)
            
            sub(/^[^ ]+ /, "")
            print local_time " " $0
        } else {
            print $0
        }
        fflush()
    }'
else
    echo "ERROR: No container process found"
    exit 1
fi

```

`log.sh` c выделением цветом и удалением исходных даты и времени
```bash
#!/bin/bash

NAME="einfahrt"

echo "Check for container presence, gathering log"
if [ ! -z "$(docker ps -a | awk '{print $NF}' | grep "^${NAME}$")" ]; then
    echo -e "Press Ctrl-C to stop log output\n\n"
    
    docker logs ${NAME} -f --tail=10 --timestamps 2>&1 | awk '
    BEGIN {
        # Определяем ANSI-цвета
        GREY  = "\033[90m"
        RED   = "\033[1;31m"
        YEL   = "\033[1;33m"
        GRN   = "\033[1;32m"
        RESET = "\033[0m"
    }
    {
        # 1. Обрабатываем время (перевод из UTC в  MSK) через универсальный split
        if ($1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) {
            
            # Вырезаем только часть с датой и временем: "YYYY-MM-DD-HH-MM-SS"
            # Заменяем T, кластеры двоеточий и дефисов на единый разделитель "-"
            clean_dt = substr($1, 1, 19)
            gsub(/[T:]/, "-", clean_dt)
            
            # Разбиваем строку в массив timepart (1=ГГГГ, 2=ММ, 3=ДД, 4=ЧЧ, 5=ММ, 6=СС)
            split(clean_dt, timepart, "-")
            
            # Формируем строку для mktime (формат: "YYYY MM DD HH MM SS")
            spec = timepart[1] " " timepart[2] " " timepart[3] " " timepart[4] " " timepart[5] " " timepart[6]
            
            moscow_timestamp = mktime(spec) + 10800
            
            # Форматируем время, добавляя подсвеченный текст "MSK"
            local_time = GREY strftime("%Y-%m-%d %H:%M:%S", moscow_timestamp) " MSK" RESET
            
            # Удаляем исходный UTC из начала строки
            sub(/^[^ ]+ /, "")
            line = local_time " " $0
        } else {
            line = $0
        }

        # 2. Раскрашиваем уровни логов Java приложения
        if (line ~ /[Ee][Rr][Rr][Oo][Rr]/) {
            sub(/[Ee][Rr][Rr][Oo][Rr]/, RED "&" RESET, line)
        } else if (line ~ /[Ww][Aa][Rr][Nn]/) {
            sub(/[Ww][Aa][Rr][Nn]/, YEL "&" RESET, line)
        } else if (line ~ /[Ii][Nn][Ff][Oo]/) {
            sub(/[Ii][Nn][Ff][Oo]/, GRN "&" RESET, line)
        }

        print line
        fflush()
    }'
else
    echo "ERROR: No container process found"
    exit 1
fi

```
