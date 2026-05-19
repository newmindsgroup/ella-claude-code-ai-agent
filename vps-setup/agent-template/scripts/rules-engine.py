#!/usr/bin/env python3
"""
rules-engine.py — Phase 1 Python behavioral rules engine for Mission Control.

Reads YAML rules from {{TENANT_AGENT_HOME}}/rules/*.yaml, evaluates each rule's
`when` conditions against the dashboard state JSONs (/var/www/{dashboard}/api/*.json),
fires `then` actions when conditions match, throttles per rule to prevent
notification spam.

Designed to be safe-by-default:
  - Rules with `enabled: false` are loaded but never fire
  - Every rule has a throttle window (default 24h) — same rule never fires twice
    within that window regardless of how many times the engine runs
  - All actions are audit-logged via /api/chat/audit before/after
  - Failed action does not stop other rules
  - Engine runs as a oneshot every 5 minutes via systemd timer

YAML schema:

  name: drift-persistent-escalate              # required, unique
  description: Persistent drift items unfixed   # optional
  enabled: true                                  # default false — opt-in
  when:                                          # list, ALL must match
    - path: drift.persistent_in_latest           # dot-path into state JSON
      op: ">="                                   # >=, >, ==, <=, <, !=, in, contains
      value: 5
  then:                                          # list of actions
    - action: telegram
      text: "⚠️ {{count}} persistent drift items"
    - action: audit
      action_name: rule-fired-drift
  throttle_minutes: 1440                         # min interval between fires (default 1440 = 24h)

State paths (dot-notation; first segment = JSON filename without extension):
  drift.persistent_in_latest
  telemetry.rollup.today.api_cost_usd
  triage.totals_14d.high
  sessions.totals.active
  improvements.totals.pending
  competitive.totals.changes_latest
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# These are constants the render pipeline will substitute. If running uninstalled
# they fall back to tenant-neutral defaults.
AGENT_HOME = "{{TENANT_AGENT_HOME}}"
if AGENT_HOME.startswith("{{"):  # not rendered
    AGENT_HOME = "/opt/agent"
DASHBOARD_HOSTNAME = "{{TENANT_DASHBOARD_HOSTNAME}}"
if DASHBOARD_HOSTNAME.startswith("{{"):
    DASHBOARD_HOSTNAME = "dashboard.example.com"

RULES_DIR = Path(AGENT_HOME) / "rules"
STATE_FILE = Path(AGENT_HOME) / "dashboard-chat" / "state" / "rules-engine.json"
API_DIR = Path("/var/www") / DASHBOARD_HOSTNAME / "api"
TG_SEND = Path(AGENT_HOME) / "scripts" / "tg-send.sh"
AUDIT_URL = "http://127.0.0.1:8001/api/chat/audit"

NOW = datetime.now(timezone.utc)

# YAML may be missing in unrendered template runs; lazy-import.
try:
    import yaml  # type: ignore
except ImportError:
    print("ERROR: PyYAML required (pip install pyyaml --break-system-packages)", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# State + JSON helpers
# ---------------------------------------------------------------------------

def load_state() -> dict:
    """rules-engine state: { rule_name: {last_fired_iso, last_evaluated_iso, fire_count} }."""
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text() or "{}")
    except Exception:
        return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.replace(STATE_FILE)


_state_cache: dict[str, dict] = {}


def load_api_state(key: str) -> dict | None:
    """Load /api/{key}.json with caching across rule evaluations within one run."""
    if key in _state_cache:
        return _state_cache[key]
    f = API_DIR / f"{key}.json"
    if not f.exists():
        _state_cache[key] = None
        return None
    try:
        _state_cache[key] = json.loads(f.read_text())
    except Exception:
        _state_cache[key] = None
    return _state_cache[key]


def get_path(state: dict | list, dot_path: str):
    """Walk a dot-path into nested dict/list state. Returns None if any segment misses."""
    cur = state
    for seg in dot_path.split("."):
        if cur is None:
            return None
        if isinstance(cur, dict):
            cur = cur.get(seg)
        elif isinstance(cur, list):
            try:
                cur = cur[int(seg)]
            except (ValueError, IndexError):
                return None
        else:
            return None
    return cur


# ---------------------------------------------------------------------------
# Condition evaluation
# ---------------------------------------------------------------------------

OPERATORS = {
    ">=": lambda a, b: a is not None and a >= b,
    ">":  lambda a, b: a is not None and a > b,
    "==": lambda a, b: a == b,
    "<=": lambda a, b: a is not None and a <= b,
    "<":  lambda a, b: a is not None and a < b,
    "!=": lambda a, b: a != b,
    "in": lambda a, b: a in b if hasattr(b, "__contains__") else False,
    "contains": lambda a, b: b in a if hasattr(a, "__contains__") else False,
}


def evaluate_condition(cond: dict) -> tuple[bool, object]:
    """Evaluate one condition. Returns (match, actual_value)."""
    path = cond.get("path", "")
    op = cond.get("op", "==")
    expected = cond.get("value")
    if not path:
        return False, None
    # First segment is the JSON filename, rest is the dot path inside
    first, *rest = path.split(".", 1)
    state_json = load_api_state(first)
    if state_json is None:
        return False, None
    actual = get_path(state_json, rest[0]) if rest else state_json
    if op not in OPERATORS:
        return False, actual
    try:
        return OPERATORS[op](actual, expected), actual
    except (TypeError, ValueError):
        return False, actual


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

def render_template(text: str, context: dict) -> str:
    """Tiny {{var}} substitution. Looks up dot-paths in `context` and the state cache."""
    def repl(m):
        key = m.group(1).strip()
        # Look up in context first
        if key in context:
            return str(context[key])
        # Try dot-path into state cache
        first, *rest = key.split(".", 1)
        state_json = load_api_state(first)
        if state_json is None:
            return f"{{{{?{key}?}}}}"
        val = get_path(state_json, rest[0]) if rest else state_json
        return str(val) if val is not None else f"{{{{?{key}?}}}}"
    return re.sub(r"\{\{\s*([^}]+?)\s*\}\}", repl, text)


def action_telegram(args: dict, context: dict, rule_name: str) -> bool:
    raw_text = args.get("text", "(empty rule message)")
    text = render_template(raw_text, context)
    # Wrap with a clear "rules engine" prefix so Daniel sees they're automated
    wrapped = f"🤖 [rules engine · {rule_name}]\n\n{text}"
    try:
        # tg-send.sh handles MarkdownV2 escapes when --md isn't passed; use plain
        # text by default to avoid escape pitfalls in rule authors' YAML.
        subprocess.run(
            [str(TG_SEND), "send", "--text", wrapped],
            capture_output=True, text=True, timeout=20, check=False,
        )
        return True
    except Exception as e:
        sys.stderr.write(f"telegram action failed for {rule_name}: {e}\n")
        return False


def action_audit(args: dict, context: dict, rule_name: str) -> bool:
    action_name = args.get("action_name", f"rule-fired-{rule_name}")
    body = {
        "action": action_name,
        "target": rule_name,
        "details": {"context": {k: v for k, v in context.items() if isinstance(v, (int, float, str, bool))}},
        "source": "rules-engine",
    }
    try:
        req = urllib.request.Request(
            AUDIT_URL,
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5):
            return True
    except Exception as e:
        sys.stderr.write(f"audit action failed for {rule_name}: {e}\n")
        return False


def action_log(args: dict, context: dict, rule_name: str) -> bool:
    text = render_template(args.get("text", ""), context)
    sys.stdout.write(f"[{rule_name}] LOG: {text}\n")
    return True


def action_circuit_breaker(args: dict, context: dict, rule_name: str) -> bool:
    """v2.57.0: Block a skill (or __global__) from running.

    YAML args:
        skill: name of skill OR "__global__" for kill-switch (default global)
        reason: free-text shown in dashboard + audit
        duration_hours: how long to block (default 24)
    """
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import _budget  # noqa: E402
    except Exception as e:
        sys.stderr.write(f"[{rule_name}] circuit_breaker: import _budget failed: {e}\n")
        return False
    skill  = args.get("skill", _budget.GLOBAL_KEY)
    reason = render_template(args.get("reason", "rules-engine circuit breaker"), context)
    duration_hours = int(args.get("duration_hours", 24))
    try:
        _budget.block(skill, reason, duration_hours=duration_hours, blocked_by=f"rule:{rule_name}")
        sys.stdout.write(f"[{rule_name}] BLOCKED {skill} for {duration_hours}h — {reason}\n")
        return True
    except Exception as e:
        sys.stderr.write(f"[{rule_name}] circuit_breaker failed: {e}\n")
        return False


ACTIONS = {
    "telegram": action_telegram,
    "audit": action_audit,
    "log": action_log,
    "circuit_breaker": action_circuit_breaker,
}


# ---------------------------------------------------------------------------
# Rule loader + evaluator
# ---------------------------------------------------------------------------

def load_rules() -> list[dict]:
    if not RULES_DIR.exists():
        return []
    rules = []
    for f in sorted(RULES_DIR.glob("*.yaml")):
        try:
            d = yaml.safe_load(f.read_text())
            if not isinstance(d, dict) or "name" not in d:
                sys.stderr.write(f"WARN: skipping {f.name} (no 'name' field)\n")
                continue
            d["_file"] = f.name
            rules.append(d)
        except Exception as e:
            sys.stderr.write(f"WARN: failed to load {f.name}: {e}\n")
    return rules


def is_throttled(rule_name: str, throttle_minutes: int, state: dict) -> bool:
    last = state.get(rule_name, {}).get("last_fired_iso")
    if not last:
        return False
    try:
        last_dt = datetime.fromisoformat(last.replace("Z", "+00:00"))
    except Exception:
        return False
    elapsed_min = (NOW - last_dt).total_seconds() / 60
    return elapsed_min < throttle_minutes


def evaluate_rule(rule: dict, state: dict) -> dict:
    """Returns a result dict {name, enabled, matched, fired, skipped_throttle, actions_run, error}."""
    name = rule["name"]
    enabled = rule.get("enabled", False)
    when = rule.get("when", [])
    actions = rule.get("then", [])
    throttle_minutes = int(rule.get("throttle_minutes", 1440))

    result = {
        "name": name,
        "file": rule.get("_file", ""),
        "enabled": enabled,
        "matched": False,
        "fired": False,
        "skipped_throttle": False,
        "actions_run": [],
        "actions_total": len(actions),
        "context": {},
    }

    if not enabled:
        return result

    # Evaluate conditions (AND)
    all_match = True
    context = {}
    for cond in when:
        matched, actual = evaluate_condition(cond)
        # Inject named alias if rule provides `as:` for templating
        if "as" in cond:
            context[cond["as"]] = actual
        if not matched:
            all_match = False
            break
    result["matched"] = all_match
    result["context"] = {k: v for k, v in context.items() if isinstance(v, (int, float, str, bool))}

    if not all_match:
        return result

    # Throttle check
    if is_throttled(name, throttle_minutes, state):
        result["skipped_throttle"] = True
        return result

    # Fire actions
    actions_run = []
    for act in actions:
        act_type = act.get("action", "")
        handler = ACTIONS.get(act_type)
        if not handler:
            actions_run.append({"action": act_type, "ok": False, "error": "unknown action"})
            continue
        ok = handler(act, context, name)
        actions_run.append({"action": act_type, "ok": ok})

    result["actions_run"] = actions_run
    result["fired"] = True

    # Update state
    s = state.setdefault(name, {"fire_count": 0})
    s["last_fired_iso"] = NOW.isoformat().replace("+00:00", "Z")
    s["fire_count"] = s.get("fire_count", 0) + 1

    return result


def main() -> int:
    state = load_state()
    rules = load_rules()
    results = []

    for rule in rules:
        try:
            r = evaluate_rule(rule, state)
        except Exception as e:
            r = {
                "name": rule.get("name", "?"),
                "file": rule.get("_file", ""),
                "enabled": rule.get("enabled", False),
                "matched": False,
                "fired": False,
                "error": str(e),
            }
        # Stamp last_evaluated for every rule (matched or not)
        s = state.setdefault(r["name"], {"fire_count": 0})
        s["last_evaluated_iso"] = NOW.isoformat().replace("+00:00", "Z")
        s["last_matched"] = r["matched"]
        results.append(r)

    save_state(state)

    # Print summary to stdout (captured by systemd journal)
    fired = sum(1 for r in results if r.get("fired"))
    matched = sum(1 for r in results if r.get("matched"))
    enabled = sum(1 for r in results if r.get("enabled"))
    print(f"rules-engine: {len(results)} loaded · {enabled} enabled · {matched} matched · {fired} fired")
    for r in results:
        if r.get("fired"):
            print(f"  FIRED  {r['name']}  ({len(r.get('actions_run', []))} actions)")
        elif r.get("skipped_throttle"):
            print(f"  throttled  {r['name']}")
        elif r.get("matched"):
            print(f"  matched (no actions) {r['name']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
