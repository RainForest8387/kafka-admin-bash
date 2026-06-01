# Agent PODD

####  Логи  контейнера в формате MSK
`log_save.sh`
```bash
#!/bin/bash

NAME="einfahrt"
LOGFILE="log-$(date +%Y%m%d-%H%M%S).txt"

echo "Check for container presence, gathering log"
if [ ! -z "$(docker ps -a | awk '{print $NF}' | grep "^${NAME}$")" ]; then
    
    echo "Processing logs with high-speed AWK parser..."

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
