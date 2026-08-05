# Setup â€” full flow (any machine)

This is the complete guide for getting the MonkeyCoder Bridge running, from a blank/new machine to a
working agent connection, on **Windows**, **macOS**, and **Linux**.

- Windows â†’ `setup.ps1` (automatic)
- macOS / Linux â†’ `setup.sh` (automatic)
- Restarting / machines the script can't see â†’ manual steps

---

## 0. Prerequisites (everything below)

| Thing        | Requirement                                             |
| ------------ | ------------------------------------------------------- |
| Node.js      | v18+ (`node -v`). macOS/Linux install via [nodejs.org](https://nodejs.org); Windows in step 1 |
| Git          | to clone the repo                                       |
| MonkeyCode   | an **OhMyAgent API key** + **signing secret** (from the MonkeyCode web UI, shown once). Full walkthrough in [HOW_TO_USE.md Step 0](HOW_TO_USE.md#step-0--get-your-keys-5-minutes) |

There is **no way around your two keys** â€” they are private to you and are never in the repo.
Everything else below is scripted.

---

## 1. Windows â€” automatic (recommended)

Install Node.js if needed, then clone and run:

```powershell
winget install OpenJS.NodeJS.LTS    # or download from https://nodejs.org

git clone https://github.com/Mainul999-bot/monkeycoder-bridge.git
cd monkeycoder-bridge

powershell -ExecutionPolicy Bypass -File setup.ps1
```

What `setup.ps1` does:

1. Creates `config.json` from the template and asks you to paste your `api_key` + `signing_secret`.
2. Starts the bridge in the background and waits for `http://127.0.0.1:8787/healthz`.
3. **Automatically configures:**
   - opencode â†’ `~/.config/opencode/opencode.json`
   - Claude Code â†’ `~/.claude/settings.json` (env: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`)
   - Continue â†’ `~/.continue/config.json`
4. Prints the base URL / API key / model names to paste by hand into **Cursor, Cline, Cherry Studio, Windsurf**.
5. (optional) make the bridge start at login:
   ```powershell
   powershell -ExecutionPolicy Bypass -File setup.ps1 -RegisterAutoStart
   ```

> opencode: if it's already running after `setup.ps1`, **fully quit and restart it** so it reloads the
> config.

---

## 1b. macOS / Linux â€” automatic

```bash
git clone https://github.com/Mainul999-bot/monkeycoder-bridge.git
cd monkeycoder-bridge
chmod +x setup.sh
./setup.sh
```

Same behaviour as Windows: prompts for keys, starts the bridge, configures opencode / Claude Code /
Continue, and prints the manual values. Optional autostart:

```bash
./setup.sh --autostart   # creates ~/.config/monkeycoder-bridge/autostart.sh for your session's startup
```

Requires `node`, `curl`, and `python3` (for safe JSON edits).

---

## 3. Manual (any OS, no script)

```bash
git clone https://github.com/Mainul999-bot/monkeycoder-bridge.git
cd monkeycoder-bridge
cp config.example.json config.json    # then edit: paste your apiKey + signingSecret
node server.js                        # leave this terminal running
```

Verify: `curl http://127.0.0.1:8787/healthz` â†’ `{"ok":true,...}`

Then point your agent at **`http://127.0.0.1:8787/v1`** with API key `bridge-dummy` and one of your
model strings.

---

## 4. Agent settings reference

| Agent | How it's configured | Notes |
| ----- | ------------------- | ----- |
| **opencode**     | automatic via both scripts (provider `monkeycode`) | restart app after setup |
| **Claude Code**  | automatic via both scripts (`ANTHROPIC_BASE_URL` env) | overrides existing env |
| **Continue**     | automatic via both scripts (`~/.continue/config.json`) | |
| **Cursor**       | Settings > Models > Override OpenAI base URL | paste URL + model |
| **Cline**        | provider settings: API provider = OpenAI Compatible | paste URL + key + model |
| **Cherry Studio**| Settings > Model provider > Add OpenAI-compatible, API host `http://127.0.0.1:8787` | |
| **Windsurf**     | Settings > Models, add custom model | paste URL + model |

Shared values:

```
Base URL : http://127.0.0.1:8787/v1
API key  : bridge-dummy      # arbitrary; the bridge uses its own config.json key
Models   : the model strings from config.json.e.g. monkeycode-basic/qwen3.5-plus
```

---

## 5. After first setup (every machine you already configured)

Once `config.json` has real keys and the bridge is running, all you do daily is: **start the bridge**
(`node server.js`, or let the autostart handle it) and use your agent. Re-run the setup script any
time to (re)add an agent â€” it never wipes an existing `config.json`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `AI_APICallError: Not Found` (opencode) | restart opencode; make sure base URL ends in `/v1` |
| `400 ... system prompt not found` | the agent sent no system prompt (rare); use an agent that sends one |
| `429` / `quota` / `insufficient` | daily free-token pool used; check MonkeyCode dashboard or switch model |
| `502` / Chinese upstream error | wrong model name string â€” verify exactly in config.json and the agent |
| Port 8787 in use | another bridge is running (fine), or change `port` in config.json |
| `node: command not found` | install Node 18+, or use the full path to `node` |

---

## Safety

- `config.json` (your real keys) is gitignored â€” never committed.
- Examples ship with placeholders only (`config.example.json`, `opencode.example.json`).
- The bridge listens on `127.0.0.1` (localhost only) by default.
- Logs (`*.log`) are runtime-only and gitignored.