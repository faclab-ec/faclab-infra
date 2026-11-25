#!/usr/bin/env python3
"""Dashboards, alerts and notification channels of Faclab in SigNoz, as code (S7.5).

    scripts/signoz-sync.py check              validate the files offline (CI)
    scripts/signoz-sync.py sync [--dry-run] [--prune]
                                              create or update channels, dashboards and alerts
    scripts/signoz-sync.py verify [--hours N] run every panel and alert query and report errors
    scripts/signoz-sync.py retention [--dry-run] [--logs-days N] [--traces-days N] [--metrics-days N]
                                              set and read back the retention of each signal (D-7)

The files live in observability/signoz/dashboards (SigNoz dashboards v6, one per file, `name`
faclab-<slug>) and observability/signoz/alerts (rules v2alpha1, label faclab_rule=<file name>).
`sync` matches what SigNoz already has by that name and label, so it can run any number of times:
it creates what is missing, updates what differs and leaves the rest alone. `--prune` also deletes
the Faclab dashboards and rules that no longer have a file.

Settings, from the environment or faclab-infra's .env (the environment wins):
  SIGNOZ_URL          SigNoz's address (default http://localhost:8080)
  SIGNOZ_API_KEY      key of a SigNoz service account with the Admin role; never printed
  ALERT_EMAIL_TO      recipients of the faclab-correo channel, comma-separated
  TELEGRAM_BOT_TOKEN  bot of the faclab-telegram channel (critical alerts)
  TELEGRAM_CHAT_ID    chat that bot posts to

Only the Python standard library: no dependency to install.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIGNOZ_DIR = ROOT / "observability" / "signoz"
DASHBOARDS_DIR = SIGNOZ_DIR / "dashboards"
ALERTS_DIR = SIGNOZ_DIR / "alerts"
RUNBOOKS_DIR = ROOT / "observability" / "runbooks"
RUNBOOK_BASE = "https://github.com/faclab-ec/faclab-infra/blob/master/observability/runbooks/"

DASHBOARD_TAG = {"key": "faclab", "value": "observabilidad"}
RULE_LABEL = "faclab_rule"
EMAIL_CHANNEL = "faclab-correo"
TELEGRAM_CHANNEL = "faclab-telegram"
KNOWN_CHANNELS = {EMAIL_CHANNEL, TELEGRAM_CHANNEL}
DESCRIPTION_PARTS = ("Consulta:", "Unidad:", "Umbral:", "Acción:")
VARIABLE_CLAUSE = re.compile(r"\s*(AND\s+)?[\w.]+\s+IN\s+\$[\w.]+(\s+AND)?", re.IGNORECASE)


# ─── Files ───────────────────────────────────────────────────────────────────────────────────────


def load_json_files(directory: Path) -> dict[Path, dict]:
    return {path: json.loads(path.read_text(encoding="utf-8")) for path in sorted(directory.glob("*.json"))}


def dashboard_slug(path: Path) -> str:
    # 01-ecosistema.json -> faclab-ecosistema
    return "faclab-" + re.sub(r"^\d+-", "", path.stem)


def panel_queries(panel: dict) -> list[dict]:
    """The v5 query envelopes of a dashboard panel (builder queries and formulas)."""
    envelopes = []
    for query in panel["spec"].get("queries", []):
        plugin = query["spec"]["plugin"]
        if plugin["kind"] == "signoz/BuilderQuery":
            envelopes.append({"type": "builder_query", "spec": plugin["spec"]})
        elif plugin["kind"] == "signoz/CompositeQuery":
            envelopes.extend(plugin["spec"]["queries"])
        elif plugin["kind"] == "signoz/Formula":
            envelopes.append({"type": "builder_formula", "spec": plugin["spec"]})
        else:
            raise ValueError(f"unsupported query plugin {plugin['kind']}")
    return envelopes


# ─── check ───────────────────────────────────────────────────────────────────────────────────────


def check() -> int:
    errors: list[str] = []
    dashboards = load_json_files(DASHBOARDS_DIR)
    alerts = load_json_files(ALERTS_DIR)

    names = set()
    for path, dashboard in dashboards.items():
        where = path.relative_to(ROOT)
        if dashboard.get("schemaVersion") != "v6":
            errors.append(f"{where}: schemaVersion must be v6")
        if dashboard.get("name") != dashboard_slug(path):
            errors.append(f"{where}: name must be {dashboard_slug(path)}")
        if dashboard.get("name") in names:
            errors.append(f"{where}: repeated name {dashboard.get('name')}")
        names.add(dashboard.get("name"))
        if DASHBOARD_TAG not in dashboard.get("tags", []):
            errors.append(f"{where}: missing tag {DASHBOARD_TAG}")
        spec = dashboard.get("spec", {})
        panels = spec.get("panels", {})
        placed = set()
        for layout in spec.get("layouts", []):
            for item in layout["spec"]["items"]:
                ref = item["content"]["$ref"].removeprefix("#/spec/panels/")
                if ref not in panels:
                    errors.append(f"{where}: layout points at missing panel {ref}")
                placed.add(ref)
                if item["x"] + item["width"] > 12:
                    errors.append(f"{where}: panel {ref} goes past the 12 columns of the grid")
        for panel_id, panel in panels.items():
            if panel_id not in placed:
                errors.append(f"{where}: panel {panel_id} is not in any layout")
            kind = panel["spec"]["plugin"]["kind"]
            if kind == "signoz/TextPanel":
                continue
            description = panel["spec"]["display"].get("description", "")
            missing = [part for part in DESCRIPTION_PARTS if part not in description]
            if missing:
                errors.append(f"{where}: panel {panel_id} lacks {', '.join(missing)} in its description")
            try:
                queries = panel_queries(panel)
            except (KeyError, ValueError) as error:
                errors.append(f"{where}: panel {panel_id}: {error}")
                continue
            query_names = [q["spec"]["name"] for q in queries]
            if len(query_names) != len(set(query_names)):
                errors.append(f"{where}: panel {panel_id} repeats a query name")
            if not queries:
                errors.append(f"{where}: panel {panel_id} has no query")

    referenced_runbooks = set()
    for path, rule in alerts.items():
        where = path.relative_to(ROOT)
        if rule.get("schemaVersion") != "v2alpha1":
            errors.append(f"{where}: schemaVersion must be v2alpha1")
        if rule.get("labels", {}).get(RULE_LABEL) != path.stem:
            errors.append(f"{where}: label {RULE_LABEL} must be {path.stem}")
        runbook_url = rule.get("annotations", {}).get("runbook_url", "")
        if not runbook_url.startswith(RUNBOOK_BASE):
            errors.append(f"{where}: annotations.runbook_url must start with {RUNBOOK_BASE}")
        else:
            runbook = runbook_url.removeprefix(RUNBOOK_BASE)
            referenced_runbooks.add(runbook)
            if not (RUNBOOKS_DIR / runbook).is_file():
                errors.append(f"{where}: runbook {runbook} does not exist in observability/runbooks")
        if runbook_url and runbook_url not in rule.get("annotations", {}).get("description", ""):
            errors.append(f"{where}: annotations.description must carry the runbook link")
        if rule.get("evaluation", {}).get("kind") != "rolling":
            errors.append(f"{where}: evaluation must be rolling")
        condition = rule.get("condition", {})
        queries = condition.get("compositeQuery", {}).get("queries", [])
        if condition.get("selectedQueryName") not in [q["spec"]["name"] for q in queries]:
            errors.append(f"{where}: selectedQueryName is not one of its queries")
        for level in condition.get("thresholds", {}).get("spec", []):
            if level.get("name") not in ("warning", "critical"):
                errors.append(f"{where}: threshold {level.get('name')} must be warning or critical")
            unknown = set(level.get("channels", [])) - KNOWN_CHANNELS
            if unknown:
                errors.append(f"{where}: unknown channels {sorted(unknown)}")

    runbooks = {path.name for path in RUNBOOKS_DIR.glob("*.md") if path.name != "README.md"}
    index = (RUNBOOKS_DIR / "README.md").read_text(encoding="utf-8")
    for runbook in sorted(runbooks - referenced_runbooks):
        errors.append(f"observability/runbooks/{runbook}: no alert links to it")
    for runbook in sorted(runbooks):
        if f"({runbook})" not in index:
            errors.append(f"observability/runbooks/README.md: {runbook} is missing from the index")

    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"{len(dashboards)} dashboards, {len(alerts)} alerts and {len(runbooks)} runbooks are valid")
    return 0


# ─── SigNoz API ──────────────────────────────────────────────────────────────────────────────────


def read_env_file() -> dict[str, str]:
    values: dict[str, str] = {}
    env_file = ROOT / ".env"
    if not env_file.is_file():
        return values
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def setting(name: str, default: str = "") -> str:
    if name in os.environ:
        return os.environ[name]
    return read_env_file().get(name, default)


class SigNozError(Exception):
    pass


class SigNoz:
    def __init__(self, url: str, api_key: str):
        self.url = url.rstrip("/")
        self.api_key = api_key

    def request(self, method: str, path: str, body: dict | None = None, query: dict | None = None,
                whole: bool = False):
        url = self.url + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("SIGNOZ-API-KEY", self.api_key)
        request.add_header("Accept", "application/json")
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            try:
                parsed = json.loads(detail)
                detail = parsed.get("error", parsed)
                if isinstance(detail, dict):
                    detail = detail.get("message", detail)
            except json.JSONDecodeError:
                pass
            if error.code == 403:
                detail = f"{detail} (the service account of SIGNOZ_API_KEY needs the Admin role: Settings > " \
                         "Service Accounts > its roles)"
            raise SigNozError(f"{method} {path}: HTTP {error.code}: {detail}") from None
        except urllib.error.URLError as error:
            raise SigNozError(f"{method} {path}: {error.reason}") from None
        if not payload:
            return None
        parsed = json.loads(payload)
        # The settings endpoints answer their fields at the top level, not inside `data`
        return parsed if whole else parsed.get("data")

    def list_all(self, path: str, key: str) -> list[dict]:
        items, offset = [], 0
        while True:
            page = self.request("GET", path, query={"limit": 100, "offset": offset}) or {}
            batch = page.get(key) or []
            items.extend(batch)
            offset += len(batch)
            if not batch or offset >= page.get("total", 0):
                return items


def client() -> SigNoz:
    api_key = setting("SIGNOZ_API_KEY")
    if not api_key:
        sys.exit("SIGNOZ_API_KEY is not set (environment or .env): create a service account with the Admin "
                 "role in SigNoz, a key for it, and put it in faclab-infra's .env")
    return SigNoz(setting("SIGNOZ_URL", "http://localhost:8080"), api_key)


def contains(desired, actual) -> bool:
    """Whether actual has every value of desired; SigNoz may add defaults of its own."""
    if isinstance(desired, dict):
        if not isinstance(actual, dict):
            return False
        return all(contains(value, actual.get(key)) for key, value in desired.items()
                   if not (value in (None, "", [], {}, False, 0) and key not in actual))
    if isinstance(desired, list):
        return isinstance(actual, list) and len(desired) == len(actual) and all(
            contains(d, a) for d, a in zip(desired, actual))
    if isinstance(desired, (int, float)) and isinstance(actual, (int, float)):
        return float(desired) == float(actual)
    return desired == actual


# ─── sync ────────────────────────────────────────────────────────────────────────────────────────


def desired_channels() -> dict[str, dict]:
    channels = {}
    recipients = setting("ALERT_EMAIL_TO")
    if recipients:
        channels[EMAIL_CHANNEL] = {
            "config": {"kind": "email", "spec": {"to": recipients, "sendResolved": True}},
        }
    token, chat = setting("TELEGRAM_BOT_TOKEN"), setting("TELEGRAM_CHAT_ID")
    if token and chat:
        channels[TELEGRAM_CHANNEL] = {
            "config": {"kind": "telegram", "spec": {"botToken": token, "chatId": int(chat), "sendResolved": True}},
        }
    return channels


def sync_channels(api: SigNoz, dry_run: bool, report: list) -> set[str]:
    """Rules name their channels by display name, so each channel's display name is its name"""
    wanted = desired_channels()
    existing = {c["name"]: c for c in api.list_all("/api/v2/notification_channels", "channels")}
    for name, channel in wanted.items():
        current = existing.get(name)
        if current is not None and current.get("displayName") != name:
            if not dry_run:
                api.request("DELETE", f"/api/v2/notification_channels/{current['id']}")
            current = None
        if current is None:
            if not dry_run:
                api.request("POST", "/api/v2/notification_channels", {"name": name, "displayName": name, **channel})
            report.append(("canal", name, "creado"))
            continue
        full = api.request("GET", f"/api/v2/notification_channels/{current['id']}") or {}
        if contains(channel["config"], full.get("config")):
            report.append(("canal", name, "sin cambios"))
            continue
        if not dry_run:
            api.request("PUT", f"/api/v2/notification_channels/{current['id']}", {"config": channel["config"]})
        report.append(("canal", name, "actualizado"))
    available = set(wanted) | (set(existing) & KNOWN_CHANNELS)
    for name in sorted(KNOWN_CHANNELS - available):
        print(f"warning: channel {name} is not configured; the alerts that use it will not notify through it",
              file=sys.stderr)
    return available


def with_channels(rule: dict, available: set[str]) -> dict:
    rule = json.loads(json.dumps(rule))
    for level in rule["condition"]["thresholds"]["spec"]:
        level["channels"] = [c for c in level.get("channels", []) if c in available]
    return rule


def sync_dashboards(api: SigNoz, dry_run: bool, prune: bool, report: list) -> None:
    files = {d["name"]: d for d in load_json_files(DASHBOARDS_DIR).values()}
    existing = {}
    for item in api.list_all("/api/v2/dashboards", "dashboards"):
        if DASHBOARD_TAG in (item.get("tags") or []):
            existing[item["name"]] = item
    for name, dashboard in files.items():
        current = existing.get(name)
        body = {k: dashboard[k] for k in ("schemaVersion", "name", "tags", "spec")}
        if current is None:
            created = None if dry_run else api.request("POST", "/api/v2/dashboards", body)
            report.append(("dashboard", name, "creado" + (f" ({dashboard_url(api, created)})" if created else "")))
            continue
        full = api.request("GET", f"/api/v2/dashboards/{current['id']}")
        if contains(body, full):
            report.append(("dashboard", name, "sin cambios"))
            continue
        if current.get("locked"):
            report.append(("dashboard", name, "BLOQUEADO en SigNoz: desbloquéalo para actualizarlo"))
            continue
        if not dry_run:
            api.request("PUT", f"/api/v2/dashboards/{current['id']}", body)
        report.append(("dashboard", name, "actualizado"))
    if prune:
        for name in sorted(set(existing) - set(files)):
            if not dry_run:
                api.request("DELETE", f"/api/v2/dashboards/{existing[name]['id']}")
            report.append(("dashboard", name, "borrado"))


def dashboard_url(api: SigNoz, dashboard: dict | None) -> str:
    return f"{api.url}/dashboard/{dashboard['id']}" if dashboard and dashboard.get("id") else ""


def sync_rules(api: SigNoz, available: set[str], dry_run: bool, prune: bool, report: list) -> None:
    files = {path.stem: with_channels(rule, available) for path, rule in load_json_files(ALERTS_DIR).items()}
    existing = {}
    for item in api.list_all("/api/v3/rules", "rules"):
        slug = (item.get("labels") or {}).get(RULE_LABEL)
        if slug:
            existing[slug] = item
    for slug, rule in files.items():
        current = existing.get(slug)
        if current is None:
            if not dry_run:
                api.request("POST", "/api/v2/rules", rule)
            report.append(("alerta", slug, "creada"))
            continue
        full = api.request("GET", f"/api/v2/rules/{current['id']}")
        if contains(rule, full):
            report.append(("alerta", slug, "sin cambios"))
            continue
        if not dry_run:
            api.request("PUT", f"/api/v2/rules/{current['id']}", rule)
        report.append(("alerta", slug, "actualizada"))
    if prune:
        for slug in sorted(set(existing) - set(files)):
            if not dry_run:
                api.request("DELETE", f"/api/v2/rules/{existing[slug]['id']}")
            report.append(("alerta", slug, "borrada"))


def sync(dry_run: bool, prune: bool) -> int:
    if check() != 0:
        return 1
    api = client()
    report: list[tuple[str, str, str]] = []
    try:
        available = sync_channels(api, dry_run, report)
        sync_dashboards(api, dry_run, prune, report)
        sync_rules(api, available, dry_run, prune, report)
    except SigNozError as error:
        for kind, name, result in report:
            print(f"{kind:9} {name:32} {result}")
        print(f"error: {error}", file=sys.stderr)
        return 1
    for kind, name, result in report:
        print(f"{kind:9} {name:32} {result}")
    changed = sum(1 for _, _, result in report if not result.startswith("sin cambios"))
    prefix = "dry run: " if dry_run else ""
    print(f"{prefix}{changed} cambios, {len(report) - changed} sin cambios")
    return 0


# ─── retention ───────────────────────────────────────────────────────────────────────────────────

# D-7 (OBSERVABILITY.md §4.7): logs 15 days, traces 7, metrics 90. SigNoz keeps one retention per
# signal. Traces and metrics go through the v1 endpoint, in hours; logs only through v2, in days
# (v1 answers "SetTTLV2 only supported"). A change is a ClickHouse mutation: the `expected_*` fields
# of the v1 answer show the value that is being applied until it finishes
RETENTION_DAYS = {"logs": 15, "traces": 7, "metrics": 90}


def current_retention(api: SigNoz, signal: str) -> tuple[int, int | None]:
    """The retention in force and, while a change is being applied, the one it is going to."""
    if signal == "logs":
        answer = api.request("GET", "/api/v2/settings/ttl", whole=True) or {}
        return int(answer["default_ttl_days"]), None
    answer = api.request("GET", "/api/v1/settings/ttl", query={"type": signal}, whole=True) or {}
    expected = answer.get(f"expected_{signal}_ttl_duration_hrs")
    return int(answer[f"{signal}_ttl_duration_hrs"]) // 24, None if expected is None else int(expected) // 24


def set_retention(api: SigNoz, signal: str, days: int) -> None:
    if signal == "logs":
        api.request("POST", "/api/v2/settings/ttl", {"type": "logs", "defaultTTLDays": days})
    else:
        api.request("POST", "/api/v1/settings/ttl", query={"type": signal, "duration": f"{days * 24}h"})


def retention(dry_run: bool, days: dict[str, int]) -> int:
    api = client()
    failures = 0
    try:
        for signal, wanted in days.items():
            in_force, applying = current_retention(api, signal)
            if in_force == wanted and applying in (None, wanted):
                print(f"{signal:8} sin cambios ({wanted} días)")
                continue
            if dry_run:
                print(f"{signal:8} cambiaría de {in_force} a {wanted} días")
                continue
            set_retention(api, signal, wanted)
            in_force, applying = current_retention(api, signal)
            # Applied, or accepted and being applied (the mutation runs in ClickHouse)
            if in_force == wanted or applying == wanted:
                state = "aplicada" if in_force == wanted else "aceptada, aplicándose"
                print(f"{signal:8} {state}: {wanted} días")
            else:
                print(f"{signal:8} ERROR: pedí {wanted} días y SigNoz dice {in_force}", file=sys.stderr)
                failures += 1
    except SigNozError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 1 if failures else 0


# ─── verify ──────────────────────────────────────────────────────────────────────────────────────


def without_variables(queries: list[dict]) -> list[dict]:
    """Dashboard filters use variables ($env, $route...); verify runs them over every value."""
    queries = json.loads(json.dumps(queries))
    for query in queries:
        flt = query["spec"].get("filter")
        if flt and flt.get("expression"):
            expression = VARIABLE_CLAUSE.sub(" ", flt["expression"]).strip()
            flt["expression"] = re.sub(r"^AND\s+|\s+AND$", "", expression).strip()
    return queries


def run_query(api: SigNoz, queries: list[dict], start: int, end: int, request_type: str) -> tuple[int, list[str]]:
    """How many series the visible queries return, and SigNoz's warnings (a metric it never received)"""
    body = {
        "schemaVersion": "v1", "start": start, "end": end, "requestType": request_type,
        "compositeQuery": {"queries": without_variables(queries)},
    }
    data = api.request("POST", "/api/v5/query_range", body) or {}
    warnings = [w.get("message", "") for w in ((data.get("warning") or {}).get("warnings") or [])]
    series = 0
    for result in (data.get("data") or {}).get("results") or []:
        if result.get("queryName") and result.get("queryName") not in visible_names(queries):
            continue
        for aggregation in result.get("aggregations") or []:
            series += len(aggregation.get("series") or [])
        series += len(result.get("rows") or [])
        series += len(result.get("data") or []) if isinstance(result.get("data"), list) else 0
    return series, warnings


def visible_names(queries: list[dict]) -> set[str]:
    return {q["spec"]["name"] for q in queries if not q["spec"].get("disabled")}


def verify(hours: float) -> int:
    api = client()
    end = int(time.time() * 1000)
    start = end - int(hours * 3600 * 1000)
    failed = empty = ok = warned = 0
    checks = []
    for path, dashboard in load_json_files(DASHBOARDS_DIR).items():
        for panel_id, panel in dashboard["spec"]["panels"].items():
            if panel["spec"]["plugin"]["kind"] == "signoz/TextPanel":
                continue
            kind = panel["spec"]["queries"][0]["kind"]
            checks.append((f"{dashboard['name']}/{panel_id}", panel_queries(panel), kind))
    for path, rule in load_json_files(ALERTS_DIR).items():
        checks.append((f"alerta/{path.stem}", rule["condition"]["compositeQuery"]["queries"], "time_series"))
    for name, queries, request_type in checks:
        try:
            series, warnings = run_query(api, queries, start, end, request_type)
        except SigNozError as error:
            failed += 1
            print(f"ERROR  {name}: {error}")
            continue
        # "Never received" means a wrong metric name (or one no service emits yet)
        never = [w for w in warnings if "never been received" in w]
        if never:
            warned += 1
            print(f"aviso  {name}: {'; '.join(never)}")
        elif series:
            ok += 1
            print(f"ok     {name}: {series} series")
        else:
            empty += 1
            print(f"vacío  {name}")
    print(f"{ok} con datos, {empty} sin datos en las últimas {hours:g} h, {warned} con métricas que SigNoz "
          f"nunca recibió, {failed} con error")
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="validate the files offline")
    sync_parser = commands.add_parser("sync", help="create or update channels, dashboards and alerts")
    sync_parser.add_argument("--dry-run", action="store_true", help="show what would change without changing it")
    sync_parser.add_argument("--prune", action="store_true", help="delete Faclab dashboards and alerts without a file")
    verify_parser = commands.add_parser("verify", help="run every query against SigNoz")
    verify_parser.add_argument("--hours", type=float, default=1, help="time window, in hours (default 1)")
    retention_parser = commands.add_parser("retention", help="set and read back the retention of logs, traces and metrics")
    retention_parser.add_argument("--dry-run", action="store_true", help="show what would change without changing it")
    for signal, default in RETENTION_DAYS.items():
        retention_parser.add_argument(f"--{signal}-days", type=int, default=default,
                                      help=f"{signal} retention, in days (default {default})")
    args = parser.parse_args()
    if args.command == "check":
        return check()
    if args.command == "sync":
        return sync(args.dry_run, args.prune)
    if args.command == "retention":
        return retention(args.dry_run, {signal: getattr(args, f"{signal}_days") for signal in RETENTION_DAYS})
    return verify(args.hours)


if __name__ == "__main__":
    sys.exit(main())
