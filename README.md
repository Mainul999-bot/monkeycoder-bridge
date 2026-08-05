# MonkeyCoder Bridge

A zero-dependency local proxy that lets any AI coding agent (opencode, Cursor, Claude Code, Cline,
Continue, ...) use the free-plan models of the hosted MonkeyCode platform (`monkeycode-ai.net`)
through an **OhMyAgent API key**.

> **New here? Read [`HOW_TO_USE.md`](HOW_TO_USE.md)** — a beginner-friendly, step-by-step guide
> covering keys, install, config, and how to connect **any** AI agent. This README is the technical
> reference.

MonkeyCode's OhMyAgent keys require every request to carry an
`X-OhMyAgent-Signature: v1=<hex>` header, where `<hex>` is the
`HMAC-SHA256(signingSecret, systemPrompt)`. The prompt is extracted from the request body
(top-level `system` → `instructions` → first `system` message → first `developer`/`system` input block).

This bridge does that signing for you and forwards the request to the hosted proxy. It supports two
modes:

- **Single model**: set `modelName` and every request is rewritten to that one model.
- **Multi-model** (default): leave `modelName` empty/`null` and the client's `model` value is passed
  through untouched — use as many free models as your account has.

To opencode it looks like an ordinary OpenAI-compatible provider.

## How it works

```
opencode ── POST /v1/chat/completions ──▶ MonkeyCoder Bridge (localhost:8787)
                                              │ 1. extract system prompt
                                              │ 2. compute HMAC-SHA256(secret, prompt)
                                              │ 3. rewrite model → modelName (or pass through)
                                              │ 4. add X-Api-Key + X-OhMyAgent-Signature
                                              ▼
                                        monkeycode-ai.net/v1/chat/completions
```

## Prerequisites

- Node.js 18+ (built and tested on Node 24).
- An **OhMyAgent API key** created in the MonkeyCode web UI.
  - The UI returns `api_key` + `signing_secret` exactly once — save both immediately.
- The **model name string(s)** of the free-plan model(s) you can access.
  - These are the `model` field values of your model configs (`GET /api/v1/users/models` in the API,
    or the model settings in the UI). The hosted proxy matches your request's `model` value against
    this exact string, so it must match, e.g. a GLM model name like `glm-4.6`.
  - Note: it is the model **name**, not the model config UUID.
  - To use **all** your free models, leave `modelName` empty in `config.json` and list every model
    string in your opencode config.

## Setup

**Fastest path — one command** (Windows). It fills `config.json` from your keys, starts the bridge,
and auto-configures opencode, Claude Code, and Continue:

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
# add -RegisterAutoStart to start the bridge on login
```

Manual steps below, if you prefer to do it by hand:

```powershell
# 1. configure
Copy-Item config.example.json config.json
# edit config.json: apiKey, signingSecret (modelName optional — omit to use all models)

# 2. run
node server.js
# [bridge] MonkeyCoder Bridge listening on http://127.0.0.1:8787
# [bridge] Forwarding to upstream https://monkeycode-ai.net
# [bridge] modelName not set: passing through client model names (multi-model mode)
```

Health check: `Invoke-RestMethod http://127.0.0.1:8787/healthz`

## Config

```jsonc
{
  "port": 8787,
  "host": "127.0.0.1",
  "upstreamBaseUrl": "https://monkeycode-ai.net",
  "apiKey": "YOUR_OHMYAGENT_API_KEY",
  "signingSecret": "YOUR_OHMYAGENT_SIGNING_SECRET",
  "modelName": null
}
```

| Field             | Required | Description                                                        |
| ----------------- | -------- | ------------------------------------------------------------------ |
| `port`            | no       | Listen port (default `8787`)                                       |
| `host`            | no       | Listen host (default `127.0.0.1`)                                  |
| `upstreamBaseUrl` | no       | Hosted platform base URL (default `https://monkeycode-ai.net`)     |
| `apiKey`          | yes      | Your OhMyAgent API key                                             |
| `signingSecret`   | yes      | Your OhMyAgent signing secret                                      |
| `modelName`       | no       | If set, forces every request to this model. Leave `null` to pass the client's model through (multi-model mode) |
| `models`          | no       | Array of `{ id, name }` served by `GET /v1/models`. Falls back to a single entry from `modelName` if unset |

You can also point at a different config file:
`node server.js` with env `MONKEYCODE_BRIDGE_CONFIG=/path/to/config.json`.

## Pointing opencode at the bridge

Copy `opencode.example.json` into your opencode config directory (`opencode.json` at the project
root or in `~/.config/opencode/`). In multi-model mode, replace the placeholder model entry with
**one entry per free model string** you got from `GET /api/v1/users/models` — the keys must be the
exact `model` values (e.g. `glm-4.5`, `glm-4.6`).

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
        "monkeycode-basic/qwen3.5-plus": { "name": "MonkeyCode Free - Qwen 3.5 Plus" },
        "monkeycode-basic/deepseek-v4-flash": { "name": "MonkeyCode Free - DeepSeek v4 Flash" }
      }
    }
  }
}
```

The `apiKey` value here is arbitrary — the bridge forwards requests to MonkeyCode using the
`apiKey` from its own `config.json`, so it never hits opencode's key. The base URL must end in
`/v1` (opencode builds chat URLs as `${baseURL}/messages`).

## Testing

```powershell
node test\smoke.js
```

Runs offline vectors against the exact extraction/HMAC semantics from the MonkeyCode source
(`backend/biz/llmproxy/ohmyagent_prompt.go` and `backend/biz/llmproxy/proxy.go`), plus a local
server boot/health check. No network or credentials needed.

## Endpoints proxied

- `POST /v1/chat/completions`
- `POST /v1/responses`
- `POST /v1/messages`
- `GET /healthz`
- `GET /v1/models` — returns the model list from the `models` config array (OpenAI-style `{object:"list",data:[...]}`) so clients like opencode can populate their model switcher without a 404.

Responses (including `text/event-stream` streaming) are passed through untouched.

## Notes / caveats

- This project is **not** affiliated with MonkeyCode. It's a small local shim; both sides of the
  protocol can change.
- Every request must contain a system prompt in one of the recognized locations, otherwise the
  bridge returns `400` (it cannot build the required signature).
- `config.json` holds credentials — keep it out of version control.
