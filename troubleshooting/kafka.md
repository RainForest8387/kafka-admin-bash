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


Если через 2-3 дня p99 не снизится, значит есть хроническая проблема помимо heap. С учётом всего что мы уже знаем о кластере, вот полный план действий.
#### Шаг 1 — Локализовать проблему точнее
Первым делом нужно понять: это все produce-запросы медленные или конкретные топики/партиции.

```bash
# Латентность по типам запросов — сравниваем Produce vs Fetch vs Metadata
kafka-run-class.sh kafka.tools.JmxTool \
  --jmx-url service:jmx:rmi:///jndi/rmi://localhost:9999/jmxrmi \
  --object-name "kafka.network:type=RequestMetrics,name=TotalTimeMs,request=Produce" \
  --attributes "99thPercentile,Mean" \
  --reporting-interval 10000 2>/dev/null &

kafka-run-class.sh kafka.tools.JmxTool \
  --jmx-url service:jmx:rmi:///jndi/rmi://localhost:9999/jmxrmi \
  --object-name "kafka.network:type=RequestMetrics,name=TotalTimeMs,request=FetchConsumer" \
  --attributes "99thPercentile,Mean" \
  --reporting-interval 10000 2>/dev/null &

# Декомпозиция времени produce-запроса
# RemoteTimeMs = время ожидания репликации (acks=all)
# LocalTimeMs  = время локальной записи
# ResponseQueueTimeMs = время в очереди ответов
# RequestQueueTimeMs  = время ожидания в очереди запросов
for metric in RemoteTimeMs LocalTimeMs ResponseQueueTimeMs RequestQueueTimeMs; do
  echo "=== $metric ==="
  kafka-run-class.sh kafka.tools.JmxTool \
    --jmx-url service:jmx:rmi:///jndi/rmi://localhost:9999/jmxrmi \
    --object-name "kafka.network:type=RequestMetrics,name=${metric},request=Produce" \
    --attributes "99thPercentile" \
    --one-time true 2>/dev/null
done
```

Эта декомпозиция сразу покажет где именно теряется время:
Метрика высокая | Причина |
|---|---|---|
RequestQueueTimeMs | Перегружены network threads | 
LocalTimeMs | Проблема с диском или fsync | 
RemoteTimeMs |Репликация медленная, ждём ISR |
ResponseQueueTimeMs | Перегружены io threads |

#### Шаг 2 — Насыщение сетевых потоков
При 1396 партициях и num.network.threads=3 — это первый кандидат на узкое место
```bash
# NetworkProcessorAvgIdlePercent — если < 0.3, network threads перегружены
kafka-run-class.sh kafka.tools.JmxTool \
  --jmx-url service:jmx:rmi:///jndi/rmi://localhost:9999/jmxrmi \
  --object-name "kafka.network:type=SocketServer,name=NetworkProcessorAvgIdlePercent" \
  --attributes "Value" \
  --reporting-interval 5000 2>/dev/null | head -20

# RequestHandlerAvgIdlePercent — если < 0.3, io threads перегружены
kafka-run-class.sh kafka.tools.JmxTool \
  --jmx-url service:jmx:rmi:///jndi/rmi://localhost:9999/jmxrmi \
  --object-name "kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent" \
  --attributes "OneMinuteRate" \
  --reporting-interval 5000 2>/dev/null | head -20

# Размер очереди запросов — если растёт, брокер не справляется
kafka-run-class.sh kafka.tools.JmxTool \
  --jmx-url service:jmx:rmi:///jndi/rmi://localhost:9999/jmxrmi \
  --object-name "kafka.network:type=RequestChannel,name=RequestQueueSize" \
  --attributes "Value" \
  --reporting-interval 5000 2>/dev/null | head -20
```

Если `NetworkProcessorAvgIdlePercent < 0.3` — увеличиваем в server.properties:

```bash
# Было: num.network.threads=3
# Стало для 16 ядер и 1396 партиций:
num.network.threads=6
num.io.threads=12
```


#### Шаг 6 — OS-тюнинг
```bash
# Сетевые буферы — при высоком throughput маленькие буферы дают латентность
sysctl net.core.rmem_max net.core.wmem_max \
       net.core.rmem_default net.core.wmem_default \
       net.ipv4.tcp_rmem net.ipv4.tcp_wmem

# Рекомендуемые значения для Kafka
cat >> /etc/sysctl.conf << 'EOF'
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.rmem_default=65536
net.core.wmem_default=65536
net.ipv4.tcp_rmem=4096 65536 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
EOF
sysctl -p

# Лимиты файловых дескрипторов
ulimit -n
cat /proc/$(pgrep -f kafka)/limits | grep "open files"
# Должно быть не менее 100000
# Если меньше — добавляем в /etc/security/limits.conf:
# kafka soft nofile 100000
# kafka hard nofile 100000
```
