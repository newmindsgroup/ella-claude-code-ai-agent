#!/usr/bin/env bash
# render-tenant.sh — render agent-template/ for a specific tenant.yml.
# Output goes to vps-setup/agents-config/{tenant_id}/.
#
# Usage:
#   bash vps-setup/scripts/render-tenant.sh tenants/example.yml
#   bash vps-setup/scripts/render-tenant.sh tenants/example.yml --diff
#
# Idempotent. Safe to re-run. Existing rendered files are overwritten.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/vps-setup/agent-template"
OUT_BASE="$REPO_ROOT/vps-setup/agents-config"

[[ $# -lt 1 ]] && { echo "usage: $0 <path-to-tenant.yml> [--diff]" >&2; exit 1; }

TENANT_FILE="$1"
SHOW_DIFF=""
[[ "${2:-}" == "--diff" ]] && SHOW_DIFF="1"

[[ ! -f "$TENANT_FILE" ]] && { echo "tenant file not found: $TENANT_FILE" >&2; exit 1; }
[[ ! -d "$TEMPLATE" ]]    && { echo "template dir not found: $TEMPLATE" >&2; exit 1; }

# Use python for YAML parsing + substitution
python3 - "$TENANT_FILE" "$TEMPLATE" "$OUT_BASE" "$SHOW_DIFF" <<'PYEOF'
import sys, os, shutil, re, subprocess, json

try:
    import yaml
except ImportError:
    print("ERROR: pip install pyyaml --break-system-packages", file=sys.stderr)
    sys.exit(1)

tenant_file, template_dir, out_base, show_diff = sys.argv[1:5]

with open(tenant_file) as f:
    cfg = yaml.safe_load(f)

# ---- defaults
def d(k, default=None): return cfg.get(k, default)

tenant_id = d("tenant_id")
if not tenant_id:
    print("FATAL: tenant_id required", file=sys.stderr); sys.exit(1)

# Default dashboard version to the design-system VERSION file so bumps cascade
# automatically without hand-edits in template HTML. (`__file__` is unset in a
# stdin-piped heredoc, so derive repo_root from template_dir, which IS an
# absolute path: .../vps-setup/agent-template → repo_root is two dirs up.)
def _read_version():
    try:
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(template_dir)))
        with open(os.path.join(repo_root, "design-system", "VERSION")) as f:
            return f.read().strip()
    except Exception:
        return ""
dashboard_version = d("dashboard_version") or _read_version() or "0.0.0"

linux_user  = d("linux_user", tenant_id.replace("-", "_"))
linux_group = d("linux_group", linux_user)
user_home   = d("user_home", f"/opt/{linux_user}")
agent_home  = d("agent_home", f"{user_home}/agents")
brand_repo_name = d("brand_repo_name") or tenant_id

# Build replacement table — placeholders → tenant values
RT = {
    "TENANT_ID":                          tenant_id,
    "TENANT_PERSON_FULL_NAME":            d("person_full_name", ""),
    "TENANT_PERSON_FIRST_NAME":           d("person_first_name", ""),
    "TENANT_PERSON_ROLE_DESCRIPTION":     d("person_role_description", ""),
    "TENANT_CONTACT_EMAIL":               d("contact_email", ""),
    "TENANT_WEBSITE_URL":                 d("website_url", ""),
    "TENANT_TIMEZONE":                    d("timezone", "UTC"),
    "TENANT_LOCALE":                      d("locale", "en-US"),
    "TENANT_WEATHER_LAT":                 str(d("weather_lat", 0.0)),
    "TENANT_WEATHER_LON":                 str(d("weather_lon", 0.0)),
    "TENANT_WEATHER_LABEL":               d("weather_label", ""),
    "TENANT_LINUX_USER":                  linux_user,
    "TENANT_LINUX_GROUP":                 linux_group,
    "TENANT_USER_HOME":                   user_home,
    "TENANT_AGENT_HOME":                  agent_home,
    "TENANT_WEBSITE_SYSTEMD_SERVICE":     d("website_systemd_service", ""),
    "TENANT_WEBSITE_SOURCE_PATH":         d("website_source_path", f"{user_home}/source"),
    "TENANT_BRAND_REPO_URL":              d("brand_repo_url", ""),
    "TENANT_BRAND_REPO_BRANCH":           d("brand_repo_branch", "main"),
    "TENANT_BRAND_REPO_NAME":             brand_repo_name,
    "TENANT_BRAND_REPO_GH_PATH":          d("brand_repo_gh_path", ""),
    "TENANT_VOICE_PLAYBOOK_PATH":         d("voice_playbook_path", ""),
    "TENANT_VOICE_DNA_SECTION":           d("voice_dna_section", "section 7"),
    "TENANT_RESPONSE_PLAYBOOK_PATH":      d("response_playbook_path", ""),
    "TENANT_SERVICES_DOC_PATH":           d("services_doc_path", ""),
    "TENANT_CONTENT_STRATEGY_PATH":       d("content_strategy_path", ""),
    "TENANT_NARRATIVE_CORE_PATH":         d("narrative_core_path", ""),
    "TENANT_EMAIL_TEMPLATES_PATH":        d("email_templates_path", ""),
    "TENANT_RSS_SOURCES_PATH":            d("rss_sources_path", ""),
    "TENANT_NEWSLETTER_DOC_PATH":         d("newsletter_doc_path", ""),
    "TENANT_SOCIAL_DOC_PATH":             d("social_doc_path", ""),
    "TENANT_AGENT_OPS_DOC_PATH":          d("agent_ops_doc_path", ""),
    "TENANT_NEWSLETTER_NAME":             d("newsletter_name", ""),
    "TENANT_AGENT_SKILLS_DIR":            d("agent_skills_dir", "agent-skills"),
    "TENANT_VOICE_ARCHETYPE_PRIMARY":     d("voice_archetype_primary", ""),
    "TENANT_VOICE_ARCHETYPE_SECONDARY":   d("voice_archetype_secondary", ""),
    "TENANT_VOICE_EMOJI_POLICY":          d("voice_emoji_policy", ""),
    "TENANT_GHL_LOCATION_ID_ENV":         d("ghl_location_id_env", "GHL_LOCATION_ID"),
    "TENANT_GHL_PIT_ENV":                 d("ghl_pit_env", "GHL_API_KEY"),
    "TENANT_GHL_BASE_URL":                d("ghl_base_url", "https://services.leadconnectorhq.com"),
    "TENANT_TELEGRAM_BOT_USERNAME":       d("telegram_bot_username", ""),
    "TENANT_MORNING_BRIEF_TIME":          d("morning_brief_time", "09:00:00"),
    "TENANT_EVENING_ROLLUP_TIME":         d("evening_rollup_time", "18:00:00"),
    "TENANT_STALE_WATCHER_HOURS":         d("stale_watcher_hours", "9..21"),
    "TENANT_STALE_THRESHOLD_HOURS":       str(d("stale_threshold_hours", 48)),
    "TENANT_COMMS_AGENT_ROLE":            d("comms_agent_role", ""),
    "TENANT_PIPELINE_AGENT_ROLE":         d("pipeline_agent_role", ""),
    "TENANT_CONTENT_AGENT_ROLE":          d("content_agent_role", ""),
    "TENANT_RESEARCH_AGENT_ROLE":         d("research_agent_role", ""),
    "TENANT_DRIFT_SCANNER_ROLE":          d("drift_scanner_role", ""),
    "TENANT_AGENT_GIT_EMAIL":             d("agent_git_email", ""),
    "TENANT_DASHBOARD_HOSTNAME":          d("dashboard_hostname", ""),
    "TENANT_DASHBOARD_TITLE":             d("dashboard_title", f"{d('person_full_name','')} — Mission Control".strip(" —")),
    "TENANT_DASHBOARD_VERSION":           dashboard_version,
    # Dashboard basic-auth username — distinct from linux_user / first_name.
    # Defaults to first_name lowercased so the htpasswd file matches conventional
    # lowercase usernames; tenants can override in YAML if their htpasswd differs.
    "TENANT_DASHBOARD_BASIC_AUTH_USER":   d("dashboard_basic_auth_user", d("person_first_name", linux_user).lower()),
    "TENANT_TLS_CERT_PATH":               d("tls_cert_path", ""),
    "TENANT_TLS_KEY_PATH":                d("tls_key_path", ""),
}

# Entity separation terms — pad to 4 slots so placeholders always have values
entities = d("entity_separation_terms", []) or []
for i, term in enumerate(entities, start=1):
    RT[f"TENANT_ENTITY_TERM_{i}"] = term
for i in range(len(entities)+1, 5):
    RT[f"TENANT_ENTITY_TERM_{i}"] = ""

def substitute(text):
    # Replace longest placeholders first to avoid partial overlaps
    for k in sorted(RT.keys(), key=len, reverse=True):
        text = text.replace("{{" + k + "}}", RT[k])
    return text

# Output dir
out_dir = os.path.join(out_base, tenant_id)
os.makedirs(out_dir, exist_ok=True)

# Walk template and render. Skip generated/junk dirs that shouldn't be rendered.
SKIP_DIRS = {"__pycache__", ".DS_Store", "node_modules", ".pytest_cache"}
SKIP_SUFFIX = (".pyc", ".pyo", ".swp", ".swo")

written = 0
for root, dirs, files in os.walk(template_dir):
    # Prune dirs in-place so os.walk skips them entirely.
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
    rel_root = os.path.relpath(root, template_dir)
    target_root = os.path.join(out_dir, rel_root) if rel_root != "." else out_dir
    os.makedirs(target_root, exist_ok=True)
    for f in files:
        if f.endswith(SKIP_SUFFIX) or f == ".DS_Store":
            continue
        srcp = os.path.join(root, f)
        target_name = f
        if target_name.endswith(".tmpl"):
            target_name = target_name[:-5]
        dstp = os.path.join(target_root, target_name)
        # encoding='utf-8' explicit; errors='strict' so a future binary file in
        # the template tree fails loudly here rather than silently corrupting.
        with open(srcp, encoding="utf-8") as inf:
            content = inf.read()
        rendered = substitute(content)
        # Detect un-rendered placeholders
        leftover = re.findall(r"\{\{TENANT_[A-Z_0-9]+\}\}", rendered)
        if leftover:
            print(f"  WARN: {dstp} has unresolved: {set(leftover)}")
        with open(dstp, "w") as outf:
            outf.write(rendered)
        # preserve executable bit on .sh scripts
        if dstp.endswith(".sh"):
            os.chmod(dstp, 0o755)
        written += 1

print(f"\nRendered {written} files to {out_dir}/")

# Optional diff against existing
if show_diff:
    cmp_dir = os.path.join(out_base, tenant_id + "-existing")
    print(f"\n=== diff vs existing (cmp via diff) ===")
    if os.path.exists(cmp_dir):
        subprocess.run(["diff", "-r", cmp_dir, out_dir])
    else:
        print(f"(no comparison baseline at {cmp_dir})")
PYEOF
