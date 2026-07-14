#!/usr/bin/env bash
""":"
exec python3 "$0" "$(cd "$(dirname "$0")" && pwd)" "$@"
":"""
# otta-learning-policy.sh — resolve per-run LEARN controls, prepare governed
# repo learnings, and route verdict capture through the resolved policy.
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


HERE = Path(sys.argv[1])
ARGV = sys.argv[2:]
BOOLS = {
    "true": True, "1": True, "yes": True, "on": True,
    "false": False, "0": False, "no": False, "off": False,
}


def die(message: str) -> None:
    print(f"otta-learning-policy: {message}", file=sys.stderr)
    raise SystemExit(2)


def parse_bool(value: str | None) -> bool | None:
    if value is None:
        return None
    return BOOLS.get(value.strip().lower())


def strip_scalar(value: str) -> str:
    value = re.sub(r"\s+#.*$", "", value).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def read_repo_policy(config: Path) -> dict:
    if not config.is_file():
        return {"state": "missing", "enabled": None, "consult": None,
                "capture": None, "expiry_days": 180}

    try:
        lines = config.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return {"state": "malformed", "enabled": None, "consult": None,
                "capture": None, "expiry_days": 180}

    start = None
    for index, line in enumerate(lines):
        if re.match(r"^learn\s*:\s*(?:#.*)?$", line):
            start = index + 1
            break
        if re.match(r"^learn\s*:", line):
            return {"state": "malformed", "enabled": None, "consult": None,
                    "capture": None, "expiry_days": 180}
    if start is None:
        return {"state": "missing", "enabled": None, "consult": None,
                "capture": None, "expiry_days": 180}

    raw: dict[str, str] = {}
    malformed = False
    for line in lines[start:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            break
        match = re.match(r"^\s+([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$", line)
        if not match:
            malformed = True
            continue
        key, value = match.groups()
        if key in {"enabled", "consult", "capture", "expiry_days"}:
            raw[key] = strip_scalar(value)

    parsed: dict[str, object] = {"state": "ok", "enabled": None,
                                 "consult": None, "capture": None,
                                 "expiry_days": 180}
    for key in ("enabled", "consult", "capture"):
        if key in raw:
            value = parse_bool(raw[key])
            if value is None:
                malformed = True
            else:
                parsed[key] = value
    if "expiry_days" in raw:
        try:
            expiry = int(raw["expiry_days"])
            if expiry < 0:
                raise ValueError
            parsed["expiry_days"] = expiry
        except ValueError:
            malformed = True
    if malformed:
        parsed.update(state="malformed", enabled=None, consult=None,
                      capture=None, expiry_days=180)
    return parsed


def resolve_policy(config: Path, cli_consult: str | None,
                   cli_capture: str | None) -> tuple[dict, dict]:
    repo = read_repo_policy(config)

    def resolve(name: str, cli_value: str | None) -> tuple[bool, str]:
        if cli_value is not None:
            parsed = parse_bool(cli_value)
            if parsed is None:
                die(f"invalid --{name}: expected true or false")
            return parsed, "run_override"

        env_name = f"OTTA_LEARN_{name.upper()}"
        if env_name in os.environ:
            parsed = parse_bool(os.environ[env_name])
            if parsed is None:
                die(f"invalid {env_name}: expected true or false")
            return parsed, "environment"

        # OTTA_NO_CAPTURE is the legacy per-run capture opt-out.
        if name == "capture" and os.environ.get("OTTA_NO_CAPTURE"):
            return False, "environment_legacy_opt_out"

        if repo["state"] == "ok":
            if repo[name] is not None:
                return bool(repo[name]), "repo"
            if repo["enabled"] is not None:
                return bool(repo["enabled"]), "repo_legacy_enabled"
        return False, "repo_default"

    consult, consult_source = resolve("consult", cli_consult)
    capture, capture_source = resolve("capture", cli_capture)
    return ({
        "consult": consult,
        "consult_source": consult_source,
        "capture": capture,
        "capture_source": capture_source,
    }, repo)


def option_pairs(args: list[str], recognized: set[str], keep_unknown: bool = False):
    values: dict[str, str] = {}
    unknown: list[str] = []
    index = 0
    while index < len(args):
        key = args[index]
        if not key.startswith("--") or index + 1 >= len(args):
            die(f"invalid argument: {key}")
        value = args[index + 1]
        if key in recognized:
            values[key] = value
        elif keep_unknown:
            unknown.extend((key, value))
        else:
            die(f"unknown argument: {key}")
        index += 2
    return values, unknown


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")


def append_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n")


def ensure_local_run_ignore() -> None:
    result = subprocess.run(
        ["git", "rev-parse", "--git-path", "info/exclude"],
        capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.strip():
        return
    exclude = Path(result.stdout.strip())
    try:
        existing = exclude.read_text(encoding="utf-8") if exclude.is_file() else ""
        pattern = "/.otta/run/"
        if pattern in existing.splitlines():
            return
        exclude.parent.mkdir(parents=True, exist_ok=True)
        with exclude.open("a", encoding="utf-8") as handle:
            if existing and not existing.endswith("\n"):
                handle.write("\n")
            handle.write(pattern + "\n")
    except (OSError, UnicodeError):
        # Run state remains usable outside Git or when local excludes are read-only.
        return


def read_run_capture_policy(path: Path) -> dict | None:
    if not path.is_file():
        return None
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
        policy = receipt["policy"]
        capture = receipt["capture"]
        enabled = policy["capture"]
        source = policy["capture_source"]
        reason = capture["reason"]
        if (receipt.get("version") != 1 or type(enabled) is not bool
                or capture.get("enabled") is not enabled
                or not isinstance(source, str) or not source
                or not isinstance(reason, str) or not reason):
            raise ValueError
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError):
        return {
            "capture": False,
            "capture_source": "run_receipt_invalid",
            "capture_reason": "policy_receipt_invalid",
        }
    return {
        "capture": enabled,
        "capture_source": source,
        "capture_reason": reason,
    }


def disabled_reason(kind: str, source: str, repo_state: str) -> str:
    if source == "run_override":
        return f"{kind}_disabled_run_override"
    if source in {"environment", "environment_legacy_opt_out"}:
        return f"{kind}_disabled_environment"
    if repo_state == "missing":
        return "config_missing"
    if repo_state == "malformed":
        return "config_malformed"
    return f"{kind}_disabled_repo"


def prepare(args: list[str]) -> None:
    values, _ = option_pairs(args, {
        "--config", "--learnings", "--receipt", "--rules-output", "--now",
        "--consult", "--capture",
    })
    config = Path(values.get("--config", ".otta.yml"))
    learnings = Path(values.get("--learnings", "LEARNINGS.md"))
    receipt_path = Path(values.get("--receipt", ".otta/run/learning-receipt.json"))
    rules_output = Path(values.get("--rules-output", ".otta/run/consulted-learnings.md"))
    try:
        today = dt.date.fromisoformat(values.get("--now", dt.date.today().isoformat()))
    except ValueError:
        die("invalid --now: expected YYYY-MM-DD")

    ensure_local_run_ignore()
    policy, repo = resolve_policy(config, values.get("--consult"), values.get("--capture"))
    consultation = {
        "status": "skipped",
        "reason": disabled_reason("consult", policy["consult_source"], repo["state"]),
        "rule_count": 0,
        "rule_ids": [],
        "provenance": "repo:LEARNINGS.md",
    }
    active_lines: list[str] = []

    if policy["consult"]:
        if not learnings.is_file():
            consultation["reason"] = "learnings_missing"
        else:
            try:
                lines = learnings.read_text(encoding="utf-8").splitlines()
            except (OSError, UnicodeError):
                lines = []
                consultation["reason"] = "learnings_unavailable"
            else:
                rule_ids = []
                manual_pattern = re.compile(
                    r"^-\s+(\d{4}-\d{2}-\d{2})\s+(\[[^\]]+\])\s+(.+?)\s*$")
                engine_pattern = re.compile(
                    r"^-\s+(.+?)\s+<!--\s*source:\s*([^|]+?)\s*\|\s*"
                    r"added:\s*([^|]+?)\s*\|\s*expires:\s*([^|>]+?)\s*"
                    r"(?:\|\s*recurrence:\s*\d+\s*)?"
                    r"(?:\|\s*enforced-by:\s*[^|>]+?\s*)?-->\s*$")
                for line in lines:
                    manual_match = manual_pattern.match(line)
                    engine_match = engine_pattern.match(line.strip())
                    if engine_match:
                        try:
                            added = dt.date.fromisoformat(engine_match.group(3).strip())
                            expires = dt.date.fromisoformat(engine_match.group(4).strip())
                        except ValueError:
                            continue
                        if expires < today:
                            continue
                        active_lines.append(line)
                        digest = hashlib.sha256(line.encode("utf-8")).hexdigest()[:12]
                        rule_ids.append(f"engine:{added.isoformat()}:{digest}")
                    elif manual_match:
                        try:
                            created = dt.date.fromisoformat(manual_match.group(1))
                        except ValueError:
                            continue
                        age = (today - created).days
                        if age < 0 or age > int(repo["expiry_days"]):
                            continue
                        active_lines.append(line)
                        digest = hashlib.sha256(line.encode("utf-8")).hexdigest()[:12]
                        category = manual_match.group(2).strip("[]")
                        rule_ids.append(
                            f"{manual_match.group(1)}:{category}:{digest}")
                consultation["rule_ids"] = rule_ids
                consultation["rule_count"] = len(rule_ids)
                if rule_ids:
                    consultation.update(status="consulted", reason="active_rules")
                else:
                    consultation["reason"] = "no_active_rules"

    rules_output.parent.mkdir(parents=True, exist_ok=True)
    output = "# Active Otta learnings\n\n"
    if active_lines:
        output += "\n".join(active_lines) + "\n"
    else:
        output += f"<!-- {consultation['reason']} -->\n"
    rules_output.write_text(output, encoding="utf-8")

    receipt = {
        "version": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        "policy": policy,
        "consultation": consultation,
        "capture": {
            "enabled": policy["capture"],
            "reason": "capture_enabled" if policy["capture"] else disabled_reason(
                "capture", policy["capture_source"], repo["state"]),
        },
    }
    write_json(receipt_path, receipt)
    print(f"learn: {consultation['status']} ({consultation['reason']}); "
          f"rules={consultation['rule_count']}; capture={'enabled' if policy['capture'] else 'disabled'}")


def capture(args: list[str]) -> None:
    values, ledger_args = option_pairs(args, {
        "--config", "--receipt", "--policy-receipt", "--consult", "--capture",
    }, keep_unknown=True)
    config = Path(values.get("--config", ".otta.yml"))
    receipt_path = Path(values.get("--receipt", ".otta/run/learning-capture-receipts.jsonl"))
    policy_receipt_path = Path(values.get(
        "--policy-receipt", ".otta/run/learning-receipt.json"))
    ensure_local_run_ignore()
    run_policy = read_run_capture_policy(policy_receipt_path)
    if run_policy is None:
        policy, repo = resolve_policy(
            config, values.get("--consult"), values.get("--capture"))
        capture_reason = disabled_reason(
            "capture", policy["capture_source"], repo["state"])
        policy_origin = "current_resolution"
    else:
        policy = run_policy
        capture_reason = run_policy["capture_reason"]
        policy_origin = "run_receipt"

    ledger_fields: dict[str, str] = {}
    for index in range(0, len(ledger_args), 2):
        ledger_fields[ledger_args[index]] = ledger_args[index + 1]
    source = ledger_fields.get("--source", "unknown")
    event = ledger_fields.get("--event", "unknown")
    record = {
        "ts": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        "source": source,
        "event": event,
        "policy_source": policy["capture_source"],
        "policy_origin": policy_origin,
    }

    if not policy["capture"]:
        record.update(status="skipped", reason=capture_reason)
        append_json(receipt_path, record)
        print(f"learn capture: skipped ({record['reason']})", file=sys.stderr)
        return

    required = {"--source", "--event", "--score", "--feedback"}
    missing = sorted(required.difference(ledger_fields))
    if missing:
        die(f"capture missing required ledger arguments: {', '.join(missing)}")

    result = subprocess.run(["bash", str(HERE / "ledger-append.sh"), *ledger_args])
    record.update(status="captured" if result.returncode == 0 else "failed",
                  reason="capture_enabled" if result.returncode == 0 else "ledger_append_failed")
    append_json(receipt_path, record)
    if result.returncode != 0:
        raise SystemExit(result.returncode)


if not ARGV or ARGV[0] not in {"prepare", "capture"}:
    die("usage: otta-learning-policy.sh <prepare|capture> [options]")
if ARGV[0] == "prepare":
    prepare(ARGV[1:])
else:
    capture(ARGV[1:])
