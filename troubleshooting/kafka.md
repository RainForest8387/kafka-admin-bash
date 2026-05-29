# kafka cluster latensy

## Дано:
кластер Kafka состоящий из трех брокеров, судя по данным мониторинга 
* Produce Latency 99th per broker составляет 2s   
* FetchConsumer Latency 99th per broker составляет 3.43s
* FetchFollow Latency 99th per broker составляет 1.98 s 
 
Также есть жалобы на health probe со стороны потребителей (иногда 36401.821ms)

### Приоритет: Диск → JVM/GC → Сеть → Kafka config → Consumer → Клиенты

#### Шаг 1 — Диск и I/O (первый подозреваемый)
Высокая Produce-латентность (2 с) при нормальной FetchFollow (1.98 с) чаще всего указывает на узкое место именно при записи. Проверяем на каждом брокере:
```bash
iostat -xz 1 30            # смотрим %iowait, await (>20 ms — проблема)
iotop -ao                  # какой процесс давит на диск
df -h && du -sh /var/kafka/data/*  # свободное место (нужно >20%)
```
Ключевые параметры, которые могут гнать fsync сверх нормы: log.flush.interval.messages и log.flush.interval.ms. Если они выставлены агрессивно — брокер сбрасывает каждое сообщение на диск, что и даёт 2-секундные выбросы на p99.

