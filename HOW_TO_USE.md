# How to use the MonkeyCoder Bridge in any AI agent

The bridge turns your **MonkeyCode free-plan models** into a standard local API that almost every AI
coding agent can talk to. It runs on your computer (`http://127.0.0.1:8787`) and signs every request
for MonkeyCode automatically, so your agent never needs to know about OhMyAgent signing.

> **What you get:** one local endpoint that speaks both **OpenAI** (`/v1/chat/completions`) and
> **Anthropic** (`/v1/messages`) formats. Agents like opencode, Cursor, Cline, Continue, Cherry
> Studio, and any tool that accepts a "custom OpenAI-compatible base URL" can use it.

---

## Step 0 — Get your keys (5 minutes)

1. Go to the MonkeyCode web UI and open the model settings / API page.
2. Click **create an API key** for OhMyAgent.
3. The UI shows two values **exactly once** — copy both now:
   - `api_key` → this is your **API key**
   - `signing_secret` → this is your **signing secret**
4. Also note the **model name string(s)** you can access (the `model` field, e.g.
   `monkeycode-basic/qwen3.5-plus`). It is the model **name**, not a UUID.

> Treat both values like passwords. Never paste them into chat, docs, or git.

---

## Step 1 — Install & configure (5 minutes)

**Prerequisite:** Node.js 18 or newer (`node -v`).

```powershell
# 1. download / copy the project folder (e.g. C:\tools\monkeycoder-bridge)

# 2. create your config file from the template
Copy-Item config.example.json config.json

# 3. open config.json in a text editor and fill in:
#      "apiKey":        -> your api_key
#      "signingSecret"  -> your signing_secret
#      "models":        -> list of your model name strings
#    (leave "modelName" null to use ALL models you listed)
```

Example `config.json`:

```jsonc
{
  "port": 8787,
  "host": "127.0.0.1",
  "upstreamBaseUrl": "https://monkeycode-ai.net",
  "apiKey": "oma_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "signingSecret": "omas_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "modelName": null,
  "models": [
    { "id": "monkeycode-basic/qwen3.5-plus", "name": "MonkeyCode Free - Qwen 3.5 Plus" },
    { "id": "monkeycode-basic/deepseek-v4-flash", "name": "MonkeyCode Free - DeepSeek v4 Flash" }
  ]
}
```

> `config.json` is in `.gitignore`. Your secrets never get committed.

---

## Step 2 — Start the bridge

```powershell
node server.js
```

You should see:

```
[bridge] MonkeyCoder Bridge listening on http://127.0.0.1:8787
[bridge] Forwarding to upstream https://monkeycode-ai.net
```

Verify it works:

```powershell
Invoke-RestMethod http://127.0.0.1:8787/healthz
# -> {"ok":true,"upstream":"https://monkeycode-ai.net","modelName":null}
```

> Leave this terminal window open while you use the agent. Or install it as a startup task / use
> `npm start`.

---

## Step 3 — Point your AI agent at it

The base URL you give the agent is **`http://127.0.0.1:8787/v1`** (note the `/v1` — it matters).

### Option A — opencode (recommended, fully tested)

Copy `opencode.example.json` to your opencode config (`opencode.json` at your project root, or
`~/.config/opencode/opencode.json`). Put one entry per free model under `models`. Then select the
model in the opencode model switcher.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "monkeycode": {
      "npm": "@ai-sdk/anthropic",
      "name": "MonkeyCode Bridge",
      "options": {
        "baseURL": "http://127.0.0.1:8787/v1",
        "apiKey": "bridge-dummy"
      },
      "models": {
        "monkeycode-basic/qwen3.5-plus": {
          "name": "MonkeyCode Free - Qwen 3.5 Plus"
        },
        "monkeycode-basic/deepseek-v4-flash": {
          "name": "MonkeyCode Free - DeepSeek v4 Flash"
        }
      }
    }
  }
}
```

The `apiKey` value (`bridge-dummy`) is arbitrary — the bridge uses its own `config.json` key when
forwarding, so opencode never sees your real key.

> **Gotcha:** if you change this file while opencode is already running, **fully quit and restart**
> opencode. It caches the config at startup, and a stale base URL (missing `/v1`) gives
> `AI_APICallError: Not Found`.

### Option B — Cursor (and other OpenAI-compatible agents)

Add a **custom OpenAI-compatible provider** (or "override OpenAI base URL"):

| Setting           | Value                                   |
| ----------------- | --------------------------------------- |
| Base URL          | `http://127.0.0.1:8787/v1`              |
| API key           | anything (e.g. `bridge-dummy`)          |
| Model             | one of your model name strings          |

### Option C — Claude Code / agents that accept an Anthropic-compatible URL

Set the base URL to `http://127.0.0.1:8787/v1` and point the model at one of your model strings.
The bridge answers `/v1/messages`, so Anthropic-format clients work.

### Option D — anything else

If the agent lets you define a **custom API base URL** and an **API key**, use:

```
Base URL : http://127.0.0.1:8787/v1
API key  : bridge-dummy
Model    : <one of your model name strings>
```

The agent just sees a normal local API server.

---

## Step 4 — Watch your usage (optional, Windows)

A helper script tails the logs and prints a yellow `[ALERT]` whenever it sees a quota / rate-limit /
429 error:

```powershell
powershell -ExecutionPolicy Bypass -File watch-usage.ps1
# also tail your agent's log:
powershell -ExecutionPolicy Bypass -File watch-usage.ps1 -AgentLog C:\path\to\agent\log
```

---

## Troubleshooting

| Symptom                                     | Fix                                                                 |
| ------------------------------------------- | ------------------------------------------------------------------- |
| `AI_APICallError: Not Found` from opencode  | Restart opencode fully after changing config; make sure base URL ends in `/v1`. |
| `400 ... system prompt not found`           | The agent sent no system prompt (rare). Use an agent that sends one. |
| `429` / `quota` / `insufficient` in logs    | Daily free-token pool used up. Check your MonkeyCode dashboard, or switch to another free model. |
| `502` / Chinese upstream error              | Upstream model rejected the request. Verify the exact model name string in config and the agent. |
| Port 8787 already in use                    | Either another bridge is running (fine), or change `port` in `config.json`. |
| `node: command not found`                   | Install Node.js 18+, or run `node.exe` with its full path.           |

---

## Keeping it safe

- `config.json` (real keys) is **never** committed — `.gitignore` handles it.
- The examples ship with placeholders only (`config.example.json`, `opencode.example.json`).
- The bridge listens on `127.0.0.1` (localhost only) by default — it is not exposed to your network.
- Logs (`*.log`) are runtime-only and also gitignored.
