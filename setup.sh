#!/usr/bin/env bash
# MonkeyCoder Bridge - one-command auto-setup (macOS / Linux)
# Creates config.json (prompts for your keys), starts the bridge, and configures
# opencode, Claude Code, and Continue. In-app agents (Cursor, Cline, Cherry,
# Windsurf) need the values printed at the end typed by hand.
#
#   ./setup.sh
#   ./setup.sh --autostart     # also install a bridge launcher at session start

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bridge_base="http://127.0.0.1:8787"
bridge_url="${bridge_base}/v1"
dummy_key="bridge-dummy"
config_path="$here/config.json"
autostart="${1:-}"

sgr_green=$'\033[32m'; sgr_yellow=$'\033[33m'; sgr_red=$'\033[31m'; sgr_cyan=$'\033[36m'; sgr_dim=$'\033[2m'; sgr_reset=$'\033[0m'
ok()   { printf "${sgr_green}[ok]${sgr_reset} %s\n" "$*"; }
warn() { printf "${sgr_yellow}[warn]${sgr_reset} %s\n" "$*"; }
fail() { printf "${sgr_red}[FAIL]${sgr_reset} %s\n" "$*"; }

if ! command -v node >/dev/null 2>&1; then
  fail "Node.js not found. Install Node 18+ (https://nodejs.org) then rerun ./setup.sh"
  exit 1
fi

echo ""
echo "============================================="
echo "  MonkeyCoder Bridge - auto setup"
echo "============================================="

# ---------------- 1. config.json ----------------
if [ ! -f "$config_path" ]; then
  if [ ! -f "$here/config.example.json" ]; then
    fail "config.example.json not found next to setup.sh"
    exit 1
  fi
  cp "$here/config.example.json" "$config_path"
  printf "Paste your api_key (starts with oma_): "
  read -r ak
  printf "Paste your signing_secret (starts with omas_): "
  read -r sk
  # use python if available for proper JSON escaping; else basic sed
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$config_path" "$ak" "$sk" <<'PY'
import json, sys
p, ak, sk = sys.argv[1], sys.argv[2].strip(), sys.argv[3].strip()
cfg = json.load(open(p, encoding="utf-8"))
cfg["apiKey"] = ak
cfg["signingSecret"] = sk
assert (ak.startswith("oma_") and sk.startswith("omas_")), "keys must start with oma_ / omas_"
json.dump(cfg, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
  else
    sed -i "s#\"apiKey\": \".*\"#\"apiKey\": \"$ak\"#; s#\"signingSecret\": \".*\"#\"signingSecret\": \"$sk\"#" "$config_path"
  fi
  ok "config.json created with your keys"
else
  if grep -q 'oma_xxxxxxxx' "$config_path"; then
    fail "config.json exists but apiKey is still a placeholder. Edit it (or delete it and rerun)."
    exit 1
  fi
  ok "config.json found - keeping it"
fi

# collect model ids
model_ids=""
if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("modelName") else 1)' "$config_path" 2>/dev/null; then
  model_ids="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("modelName"))' "$config_path")"
else
  model_ids="$(python3 -c 'import json,sys; print(",".join(m["id"] for m in json.load(open(sys.argv[1])).get("models", [])))' "$config_path")"
fi
if [ -z "$model_ids" ]; then
  fail "no models defined in config.json (set \"models\" or \"modelName\")"
  exit 1
fi
IFS=',' read -r -a models <<<"$model_ids"
primary_model="${models[0]}"

# ---------------- 2. start the bridge ----------------
healthz() { curl -sf --max-time 2 "$bridge_base/healthz" >/dev/null 2>&1; }
if ! healthz; then
  echo "starting bridge..."
  (cd "$here" && nohup node server.js >bridge.log 2>&1 &)
  for _ in $(seq 1 10); do healthz && break; sleep 1; done
fi
if healthz; then
  ok "bridge is running at $bridge_base"
else
  warn "bridge not healthy. Run 'node server.js' manually and check config.json."
fi

# ---------------- 3. opencode (fully automated) ----------------
oc_path="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
if oc_dir="$(dirname "$oc_path")" && mkdir -p "$oc_dir"; then :; fi
if [ -f "$oc_path" ]; then cp "$oc_path" "$oc_path.bak"; fi
python3 - "$oc_path" "$bridge_url" "$dummy_key" "$config_path" <<'PY'
import json, sys, os
p, url, key, cfgp = sys.argv[1:5]
oc = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {"provider": {}}
oc.setdefault("provider", {})
provider = oc["provider"]["monkeycode"] = oc["provider"].get("monkeycode", {})
provider["npm"] = "@ai-sdk/anthropic"
provider["name"] = "MonkeyCode Bridge"
provider["options"] = {"baseURL": url, "apiKey": key}
cfg = json.load(open(cfgp, encoding="utf-8"))
provider["models"] = {m["id"]: {"name": m["name"]} for m in cfg.get("models", [])}
json.dump(oc, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
ok "opencode -> $oc_path (provider \"monkeycode\")"

# ---------------- 4. Claude Code (fully automated) ----------------
cc_path="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$cc_path")"
[ -f "$cc_path" ] && cp "$cc_path" "$cc_path.bak"
python3 - "$cc_path" "$bridge_url" "$dummy_key" "$primary_model" "${models[1]:-}" <<'PY'
import json, sys, os
p, url, key, model, small = sys.argv[1:6]
cc = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {"env": {}}
cc.setdefault("env", {})
env = cc["env"]
env["ANTHROPIC_BASE_URL"] = url
env["ANTHROPIC_AUTH_TOKEN"] = key
env["ANTHROPIC_MODEL"] = model
if small:
    env["ANTHROPIC_SMALL_FAST_MODEL"] = small
json.dump(cc, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
ok "claude code configured -> ~/.claude/settings.json (env: ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL)"
echo "     (note: this overrides any ANTHROPIC_BASE_URL you had there)"

# ---------------- 5. Continue (fully automated) ----------------
ct_path="$HOME/.continue/config.json"
mkdir -p "$(dirname "$ct_path")"
[ -f "$ct_path" ] && cp "$ct_path" "$ct_path.bak"
python3 - "$ct_path" "$bridge_url" "$dummy_key" "$config_path" <<'PY'
import json, sys, os
p, url, key, cfgp = sys.argv[1:5]
ct = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {"models": []}
ct.setdefault("models", [])
cfg = json.load(open(cfgp, encoding="utf-8"))
existing = {m.get("title") for m in ct["models"]}
for m in cfg.get("models", []):
    if m["name"] not in existing:
        ct["models"].append({
            "title": m["name"], "provider": "anthropic",
            "model": m["id"], "apiBase": url, "apiKey": key,
        })
json.dump(ct, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
ok "continue configured -> ~/.continue/config.json"

# ---------------- 6. autostart (optional) ----------------
if [ "$autostart" = "--autostart" ]; then
  launcher="$HOME/.config/monkeycoder-bridge/autostart.sh"
  mkdir -p "$(dirname "$launcher")"
  cat >"$launcher" <<EOF
#!/usr/bin/env bash
# starts MonkeyCoder Bridge at login
cd "$here" && nohup node server.js >>bridge.log 2>&1 &
EOF
  chmod +x "$launcher"
  warn "Created autostart launcher: $launcher"
  echo "Add it to your desktop session startup to auto-launch the bridge on login."
fi

# ---------------- 7. manual-only agents ----------------
echo ""
printf "${sgr_yellow}Manual setup (open the app and enter these values):${sgr_reset}\n"
echo "  Base URL : $bridge_url"
echo "  API key  : $dummy_key"
echo "  Models   : ${models[*]}"
echo "    Cursor        -> Settings > Models > Override OpenAI base URL"
echo "    Cline         -> provider settings: API provider = OpenAI Compatible"
echo "    Cherry Studio -> Settings > Model provider > Add OpenAI-compatible, set API host to http://127.0.0.1:8787"
echo "    Windsurf      -> Settings > Models, add custom model with the base URL above"
echo ""
echo "Done. If the bridge did not start, run:  node server.js"