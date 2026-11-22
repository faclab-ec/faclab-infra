#!/usr/bin/env python3
"""Checks that the OTel Collector deletes sensitive attributes (S7.6, OBSERVABILITY.md §4.6).

    scripts/collector-redaction-test.py

It runs the `collector` service of docker-compose.yml (its pinned image, environment and
config.yaml) with observability/otel-collector/redaction-test.yaml on top, which only adds OTLP/HTTP
to the services' receiver and writes every pipeline to a file. Then it sends, over OTLP/HTTP:

- a span with an event, a metric point and a log, each with sensitive keys (in the resource and in
  the span, its event, the point and the log) and keys that must stay;
- a span of faclab-web and one of another service to the browser's receiver: only the first passes
  filter/browser, without its sensitive keys.

It fails when a sensitive key or value reaches the file, when a key that must stay is gone, or when
the other service's span went through. With the real processors in every pipeline, removing
transform/redact from one of them makes it fail.

Needs Docker; runs with the values of .env.example, never .env. Only the Python standard library.
"""

from __future__ import annotations

import json
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
OVERLAY = ROOT / "observability" / "otel-collector" / "redaction-test.yaml"
CONFIG_DIR = "/etc/otelcol-contrib"
SERVICES_PORT = 4320  # the overlay's OTLP/HTTP of the services' receiver
BROWSER_PORT = 4318  # otlp/browser

# One value per run: if it shows up in the file, a sensitive key got through
SECRET = f"redaction-test-{secrets.token_hex(8)}"

# Keys the redaction must delete (§4.6), with and without a prefix
SENSITIVE = [
    "password",
    "db.password",
    "http.request.header.authorization",
    "x-csrf-token",
    "Set-Cookie",
    "user.refresh_token",
    "client_secret",
    "faclab.certificate",
]
# Keys that look alike and must stay, and the ones the services rely on
KEPT = {"faclab.sale.id": "42", "auth.passwordless": "true", "faclab.token_count": "3"}


def attributes(values: dict[str, str]) -> list[dict[str, Any]]:
    return [{"key": key, "value": {"stringValue": value}} for key, value in values.items()]


def tainted(extra: dict[str, str] | None = None) -> list[dict[str, Any]]:
    """Every sensitive key with the secret, the kept keys and `extra`"""
    return attributes({**{key: SECRET for key in SENSITIVE}, **KEPT, **(extra or {})})


def resource(service: str) -> dict[str, Any]:
    return {"attributes": tainted({"service.name": service})}


def now_ns() -> str:
    return str(time.time_ns())


def span(name: str) -> dict[str, Any]:
    return {
        "traceId": secrets.token_hex(16),
        "spanId": secrets.token_hex(8),
        "name": name,
        "kind": 2,
        "startTimeUnixNano": now_ns(),
        "endTimeUnixNano": now_ns(),
        "attributes": tainted(),
        "events": [{"name": "exception", "timeUnixNano": now_ns(), "attributes": tainted()}],
    }


def traces(service: str, name: str) -> dict[str, Any]:
    return {
        "resourceSpans": [
            {"resource": resource(service), "scopeSpans": [{"spans": [span(name)]}]}
        ]
    }


def metrics(service: str) -> dict[str, Any]:
    point = {"asInt": "1", "timeUnixNano": now_ns(), "attributes": tainted()}
    metric = {
        "name": "faclab.redaction.test",
        "sum": {"dataPoints": [point], "aggregationTemporality": 2, "isMonotonic": True},
    }
    return {
        "resourceMetrics": [
            {"resource": resource(service), "scopeMetrics": [{"metrics": [metric]}]}
        ]
    }


def logs(service: str) -> dict[str, Any]:
    record = {
        "timeUnixNano": now_ns(),
        "severityText": "INFO",
        "body": {"stringValue": "redaction test"},
        "attributes": tainted({"event.name": "redaction.test"}),
    }
    return {
        "resourceLogs": [{"resource": resource(service), "scopeLogs": [{"logRecords": [record]}]}]
    }


# --- The Collector ----------------------------------------------------------------------------------


def compose(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", "compose", "--env-file", ".env.example", *args],
        cwd=ROOT,
        check=check,
        capture_output=True,
        text=True,
    )


def start_collector(name: str, out: Path) -> None:
    compose(
        "run",
        "--detach",
        "--no-deps",
        "--name",
        name,
        "--publish",
        f"127.0.0.1::{SERVICES_PORT}",
        "--publish",
        f"127.0.0.1::{BROWSER_PORT}",
        "--volume",
        f"{OVERLAY}:{CONFIG_DIR}/redaction-test.yaml:ro",
        "--volume",
        f"{out}:/out",
        "collector",
        f"--config={CONFIG_DIR}/config.yaml",
        f"--config={CONFIG_DIR}/redaction-test.yaml",
        "--feature-gates=receiver.postgresql.separateSchemaAttr",
    )


def host_port(name: str, port: int) -> int:
    published = subprocess.run(
        ["docker", "port", name, f"{port}/tcp"], check=True, capture_output=True, text=True
    ).stdout.split()[0]
    return int(published.rsplit(":", 1)[1])


def post(port: int, path: str, body: dict[str, Any]) -> None:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        if response.status != 200:
            raise RuntimeError(f"{path} answered {response.status}")


def post_when_ready(port: int, path: str, body: dict[str, Any], seconds: float = 30) -> None:
    deadline = time.monotonic() + seconds
    while True:
        try:
            post(port, path, body)
            return
        except (urllib.error.URLError, ConnectionError, RuntimeError):
            if time.monotonic() > deadline:
                raise
            time.sleep(0.5)


# --- What came out ----------------------------------------------------------------------------------


def exported(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def attribute_sets(batches: list[dict[str, Any]]) -> dict[str, list[dict[str, str]]]:
    """The attributes of each level in the file, by level"""
    found: dict[str, list[dict[str, str]]] = {}

    def add(level: str, values: list[dict[str, Any]]) -> None:
        found.setdefault(level, []).append(
            {item["key"]: next(iter(item["value"].values()), "") for item in values}
        )

    for batch in batches:
        for resource_spans in batch.get("resourceSpans", []):
            add("resource", resource_spans["resource"].get("attributes", []))
            for scope in resource_spans.get("scopeSpans", []):
                for item in scope.get("spans", []):
                    add("span", item.get("attributes", []))
                    for event in item.get("events", []):
                        add("span event", event.get("attributes", []))
        for resource_metrics in batch.get("resourceMetrics", []):
            add("resource", resource_metrics["resource"].get("attributes", []))
            for scope in resource_metrics.get("scopeMetrics", []):
                for metric in scope.get("metrics", []):
                    for kind in ("sum", "gauge", "histogram"):
                        for point in metric.get(kind, {}).get("dataPoints", []):
                            add("metric point", point.get("attributes", []))
        for resource_logs in batch.get("resourceLogs", []):
            add("resource", resource_logs["resource"].get("attributes", []))
            for scope in resource_logs.get("scopeLogs", []):
                for record in scope.get("logRecords", []):
                    add("log", record.get("attributes", []))
    return found


def span_names(batches: list[dict[str, Any]]) -> list[str]:
    return [
        item["name"]
        for batch in batches
        for resource_spans in batch.get("resourceSpans", [])
        for scope in resource_spans.get("scopeSpans", [])
        for item in scope.get("spans", [])
    ]


def wait_for(path: Path, done, seconds: float = 20) -> list[dict[str, Any]]:
    deadline = time.monotonic() + seconds
    while True:
        batches = exported(path)
        if done(batches) or time.monotonic() > deadline:
            return batches
        time.sleep(0.25)


def check(batches: list[dict[str, Any]]) -> list[str]:
    problems = []
    raw = json.dumps(batches)
    if SECRET in raw:
        problems.append("a sensitive value reached the exporter")
    sensitive = re.compile("|".join(re.escape(key) for key in SENSITIVE), re.IGNORECASE)
    levels = attribute_sets(batches)
    for level in ("resource", "span", "span event", "metric point", "log"):
        if level not in levels:
            problems.append(f"nothing at the {level} level reached the exporter")
        for values in levels.get(level, []):
            leaked = sorted(key for key in values if sensitive.fullmatch(key))
            if leaked:
                problems.append(f"{level} kept {leaked}")
            missing = sorted(key for key in KEPT if key not in values)
            if missing:
                problems.append(f"{level} lost {missing}")
    names = span_names(batches)
    if "browser span" not in names:
        problems.append("faclab-web's span didn't go through the browser's receiver")
    if "foreign span" in names:
        problems.append("another service's span went through the browser's receiver")
    return problems


def main() -> int:
    name = f"faclab-collector-redaction-{secrets.token_hex(4)}"
    with tempfile.TemporaryDirectory(prefix="collector-redaction-") as directory:
        out = Path(directory)
        # The image runs as an unprivileged user
        out.chmod(0o777)
        output = out / "telemetry.jsonl"
        try:
            start_collector(name, out)
            services, browser = host_port(name, SERVICES_PORT), host_port(name, BROWSER_PORT)
            post_when_ready(services, "/v1/traces", traces("faclab-core", "service span"))
            post(services, "/v1/metrics", metrics("faclab-core"))
            post(services, "/v1/logs", logs("faclab-invoicing"))
            post_when_ready(browser, "/v1/traces", traces("faclab-web", "browser span"))
            post(browser, "/v1/traces", traces("faclab-core", "foreign span"))

            def complete(batches: list[dict[str, Any]]) -> bool:
                levels = attribute_sets(batches)
                return len(levels.get("log", [])) >= 1 and "browser span" in span_names(batches)

            batches = wait_for(output, complete)
            # What arrived late would still be checked: give the batch processor one more cycle
            time.sleep(1)
            problems = check(exported(output) or batches)
        except subprocess.CalledProcessError as error:
            print(error.stderr, file=sys.stderr)
            raise
        finally:
            logs_of = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
            subprocess.run(["docker", "rm", "--force", name], capture_output=True)

    if problems:
        print("Collector redaction test FAILED:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print("\nCollector logs:\n" + logs_of.stdout + logs_of.stderr, file=sys.stderr)
        return 1
    print(
        "Collector redaction test passed: no sensitive key in resources, spans, span events, "
        "metric points or logs; faclab-web's span went through the browser's receiver and "
        "another service's did not."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
