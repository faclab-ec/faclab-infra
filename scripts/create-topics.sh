#!/usr/bin/env bash
# Kafka topics of Faclab, with several partitions (ADR-0005). Each message is keyed by its company:
# a company's messages keep their order in one partition and the companies spread over the rest.
# They are created here, never by auto-creation (KAFKA_AUTO_CREATE_TOPICS_ENABLE=false).
#
# docker compose runs it once Kafka is healthy (service kafka-topics, here and in
# deploy/production). It is idempotent: a topic that exists keeps its messages, and one with fewer
# partitions grows to KAFKA_TOPIC_PARTITIONS (Kafka never shrinks them). Growing moves where new
# messages of a company go, so do it while the topic is quiet. With KAFKA_TOPIC_RETENTION_MS every
# topic gets that retention.ms, also the ones that already exist; without it they keep the broker's
# (KAFKA_LOG_RETENTION_HOURS).
#
#   docker compose run --rm kafka-topics
set -euo pipefail

BOOTSTRAP="${KAFKA_BOOTSTRAP_SERVERS:-kafka:9092}"
PARTITIONS="${KAFKA_TOPIC_PARTITIONS:-6}"
REPLICATION="${KAFKA_TOPIC_REPLICATION_FACTOR:-1}"
RETENTION_MS="${KAFKA_TOPIC_RETENTION_MS:-}"
# sales.confirmed: core -> invoicing; invoices: invoicing -> core; credit_notes.requested:
# core -> invoicing; credit_notes.results: invoicing -> core. The messages a consumer gives up on
# go to that service's dead_letters table, not to a topic (S3.4, S4.3)
TOPICS=(sales.confirmed invoices credit_notes.requested credit_notes.results)

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
  if [ -n "$RETENTION_MS" ]; then
    kafka-configs --bootstrap-server "$BOOTSTRAP" --alter --entity-type topics --entity-name "$topic" \
      --add-config "retention.ms=$RETENTION_MS" > /dev/null
    echo "$topic: $current partitions, retention.ms=$RETENTION_MS"
  else
    echo "$topic: $current partitions"
  fi
done
