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
# sudo apt install sysstat
iostat -xz 1 30            # смотрим %iowait, await (>20 ms — проблема)
iotop -ao                  # какой процесс давит на диск
df -h && du -sh /var/kafka/data/*  # свободное место (нужно >20%)
```
Ключевые параметры, которые могут гнать fsync сверх нормы: log.flush.interval.messages и log.flush.interval.ms. Если они выставлены агрессивно — брокер сбрасывает каждое сообщение на диск, что и даёт 2-секундные выбросы на p99.

#### Шаг 2 — JVM и паузы GC
Stop-the-world паузы GC великолепно объясняют спорадические провалы в 36 секунд на health probe.
```bash
# Смотрим GC-лог на каждом брокере
grep -E "GC pause|Full GC|stop-the-world" /var/log/kafka/kafkaServer-gc.log | tail -50

# Мониторинг в реальном времени
jstat -gcutil <pid> 1000 60
```
Нужно убедиться, что используется G1GC, и что -Xmx не более 6–8 GB (при большем heap паузы резко растут). Также проверяем `-XX:MaxGCPauseMillis` и отсутствие `-XX:+UseParallelGC`.

#### Шаг 3 — Сеть между брокерами
FetchFollow-латентность (1.98 с) — это задержка репликации между брокерами. В норме она должна быть единицы миллисекунд.
```bash
# RTT между брокерами
ping -c 100 broker-2 | tail -5
ping -c 100 broker-3 | tail -5

# Потери пакетов и retransmit
ss -s
netstat -s | grep -i retrans

# Нагрузка на NIC
sar -n DEV 1 30
```

Также смотрим метрику `kafka.server:type=BrokerTopicMetrics,name=BytesOutPerSec` — если приближается к физическому лимиту NIC, то репликация и consumer-fetch конкурируют за одну полосу

#### Шаг 4 — Метрики репликации Kafka
```bash
# ISR shrink — если > 0, значит реплики не успевают
kafka-topics.sh --bootstrap-server localhost:9092 --describe | grep -i "isr\|leader"

# Under-replicated partitions
kafka-topics.sh --bootstrap-server localhost:9092 --under-replicated-partitions

# Replica lag через JMX
kafka.server:type=ReplicaFetcherManager,name=MaxLag,clientId=Replica
```

Если `replica.lag.time.max.ms` нарушается, ISR начинает сжиматься — это объясняет высокую FetchConsumer-латентность: потребители не могут читать из leader до полной репликации (если `min.insync.replicas > 1` и producer использует acks=all).

#### Шаг 5 — Конфигурация Consumer и health probe
36 секунд в health probe — это почти наверняка истёкший `session.timeout.ms` или `request.timeout.ms` на стороне consumer. Проверяем:

`session.timeout.ms `(default 45 000 ms) — если брокер не отвечал 36 с, consumer считается мёртвым
`heartbeat.interval.ms` — должен быть в 3 раза меньше session.timeout.ms
`fetch.max.wait.ms` — если fetch.min.bytes большой, брокер будет держать соединение до набора батча

```bash
# Группы потребителей и их lag
kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups
```

Lag > 100K сообщений на партицию уже критичен и будет давать ощутимые задержки доставки.

#### Шаг 6 — Producer и топология топиков
```bash
# Проверяем количество партиций и скос лидеров
kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic <topic>
kafka-leader-election.sh --bootstrap-server localhost:9092 --all-topic-partitions --election-type preferred
```

Проверяем параметры producer: `linger.ms `(если 0 — каждое сообщение отправляется без батчинга, если слишком большой — добавляет искусственную задержку), batch.size, compression.type. Несбалансированные лидеры (все партиции на одном брокере) дадут именно такой паттерн: один брокер перегружен, остальные в норме.

#### Шаг 7 — Сводная проверка через JMX / Prometheus
Ключевые метрики, которые нужно смотреть в связке:

Если RequestHandlerAvgIdlePercent < 0.3 — брокер упирается в CPU на обработку запросов, нужно увеличить `num.io.threads` и `num.network.threads`.


#### Итоговая логика
Исходя из паттерна метрик (FetchConsumer > FetchFollow > Produce), наиболее вероятные причины в порядке убывания вероятности:

GC-паузы — объясняют и 36-секундные провалы, и высокие p99
Дисковые проблемы — агрессивный flush или медленный диск
ISR shrink + acks=all у producer — реплики не успевают, consumer ждёт
Перегруженный leader — скос партиций, весь трафик через один брокер
Сетевая конкуренция — репликация и consumer на одной полосе
