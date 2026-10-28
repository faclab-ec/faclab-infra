#!/usr/bin/env bash
# Kafka topics of Faclab, with several partitions (ADR-0005). Each message is keyed by its company:
# a company's messages keep their order in one partition and the companies spread over the rest.
# They are created here, never by auto-creation (KAFKA_AUTO_CREATE_TOPICS_ENABLE=false).
#
# docker compose runs it once Kafka is healthy (service kafka-topics). It is idempotent: a topic that
# exists keeps its messages, and one with fewer partitions grows to KAFKA_TOPIC_PARTITIONS (Kafka
# never shrinks them). Growing moves where new messages of a company go, so do it while the topic
# is quiet.
#
#   docker compose run --rm kafka-topics
set -euo pipefail

BOOTSTRAP="${KAFKA_BOOTSTRAP_SERVERS:-kafka:9092}"
PARTITIONS="${KAFKA_TOPIC_PARTITIONS:-6}"
REPLICATION="${KAFKA_TOPIC_REPLICATION_FACTOR:-1}"
# sales.confirmed: core -> invoicing; invoices: invoicing -> core (and invoicing itself);
# dlq: the messages invoicing couldn't process
TOPICS=(sales.confirmed invoices dlq)

partition_count() {
  kafka-topics --bootstrap-server "$BOOTSTRAP" --describe --topic "$1" |
    sed -n 's/.*PartitionCount: *\([0-9]*\).*/\1/p' | head -n 1
}

for topic in "${TOPICS[@]}"; do
  kafka-topics --bootstrap-server "$BOOTSTRAP" --create --if-not-exists \
    --topic "$topic" --partitions "$PARTITIONS" --replication-factor "$REPLICATION"
  current="$(partition_count "$topic")"
  if [ "$current" -lt "$PARTITIONS" ]; then
    echo "$topic has $current partitions; growing it to $PARTITIONS..."
    kafka-topics --bootstrap-server "$BOOTSTRAP" --alter --topic "$topic" --partitions "$PARTITIONS"
    current="$(partition_count "$topic")"
  fi
  echo "$topic: $current partitions"
done
