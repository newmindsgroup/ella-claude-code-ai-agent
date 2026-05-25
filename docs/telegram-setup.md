# Telegram setup — already in the template, awaiting only your token

Telegram is **fully pre-configured in the template**. A new deployment does not
re-derive any of it. You provide two values from your phone; one command applies
everything; one short pairing handshake (which genuinely needs a human) finishes
it.

## What the template already ships (nothing to rebuild)

| Capability | Where it lives | Auto-applied? |
|---|---|---|
| **31-command `/` menu** (brief, dashboard, queue, tasks, goals, calendar, pipeline, inbox, drafts, voice, security, budget, jobs, status, diag, goal_add, done, research, find_time, memories, remember, who, graph, improve, scan, deploy, …) | `scripts/setup-bot-identity.sh` | yes — by `setup-telegram.sh` |
| **Bot About text + description + chat menu button** | `scripts/setup-bot-identity.sh` | yes |
| **Allowlist DM policy** (only you can talk to the bot) | `access.json` written by `setup-telegram.sh` | yes |
| **Callback-button routing** — Ship/Cancel deploys, Ship/Hold/Revise drafts, Run/Skip proposed moves, Reply/Archive/Snooze email, forward-to-memory, Telegram↔dashboard chat parity | `scripts/patch-channels-plugin.sh` (7 passes) | **yes — auto-applied on every `claude-agent` start via `ExecStartPre`** |
| **Voice round-trip** — send a voice note → transcribed (whisper.cpp) → text reply → voice reply (edge-tts); `/voice off\|reply\|always` | `scripts/voice-transcribe.sh`, `voice-reply.sh`, `pref.sh` | yes (scripts shipped; `/voice` in menu) |
| **Mini App dashboard** — `/dashboard` opens Mission Control inline | `tg-send.sh --webapp-buttons` + dashboard | yes |
| **React-as-progress** (👀 received → ✍️ working → 👌 done) | channels-plugin patches | yes |
| **Send helper** — text, MarkdownV2, callback buttons, web-app buttons, voice notes, native polls | `scripts/tg-send.sh` | yes |
| **Poller watchdog** — restarts the Telegram poller if it dies | `telegram-poller-watchdog.{sh,service,timer}` | yes (timer enabled by `install-capabilities.sh`) |

## What YOU provide (the only two values)

From your phone, before/at deploy time:

1. **Bot token** — open Telegram → message **@BotFather** → `/newbot` → pick a
   name + a username ending in `bot`. BotFather replies with a token like
   `8123456789:AAH...`. That's it.
2. **Your Telegram user_id** — message **@userinfobot** → `/start` → it replies
   with your numeric `Id` (e.g. `1439634560`).

Put both in `client-credentials.md` (`telegram_bot_token`,
`telegram_owner_user_id`, `telegram_bot_username`) before the deploy.

## One command applies everything

On the VPS (or the deploy runs it for you inside `install-capabilities.sh`):

```bash
bash {AGENT_HOME}/scripts/setup-telegram.sh --token <BOTFATHER_TOKEN> --owner-id <YOUR_USER_ID>
```

That writes the token to `.env` (mode 600), writes the allowlist `access.json`
(only if missing — it never clobbers paired users), runs `setup-bot-identity.sh`
(menu + description + button), and verifies the token. The callback patches are
already applied by the agent service. Re-running is safe and idempotent.

> `install-capabilities.sh` calls this automatically if a token is already in
> `.env`. If you deploy before creating the bot, it just prints the one-liner
> above and you run it once the token exists.

## The one step that needs a human (≈60 seconds)

Telegram's pairing handshake can't be scripted — it requires you to message the
bot:

1. `systemctl start claude-agent.service`
2. In the agent's Claude Code session:
   `/plugin install telegram@claude-plugins-official` then
   `/telegram:configure <token>`
3. DM **@your_bot** anything → you get a 6-char pairing code.
4. `/telegram:access pair <code>` then `/telegram:access policy allowlist`

Done — DM the bot and it replies within ~30s, with the full command menu, voice,
buttons, and the Mini App dashboard all live.

## Re-applying / refreshing

Changed the command menu in the template and want it live? Just re-run
`setup-telegram.sh` (or `setup-bot-identity.sh`) — both are idempotent and set
the bot's public identity to whatever the template currently defines.
