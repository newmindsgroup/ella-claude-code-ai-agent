# Mission Control — screenshot demo harness

The screenshots in [`../mission-control.md`](../mission-control.md) and the README
are captured from this harness: the real dashboard SPA fed **synthetic** data, so
no production tenant information is ever exposed.

## What's here

- `api/` — synthetic JSON fixtures for every read-only `/api/*.json` endpoint the
  dashboard hydrates from (fictional tenant "Jane Doe / Example Co" with made-up
  clients, deals, tasks, ROI, telemetry). Plus `api/chat/{audit,rules,snooze}`.
- `shoot.mjs` — Playwright script: opens the dashboard, walks all 20 nav views, and
  writes `mc-<view>.png` into `../images/`.
- `shoot-chat.mjs` — re-shoots the Chat view with a synthetic conversation injected
  via `localStorage` (the chat thread loads client-side, not from a static file).

## Regenerate the screenshots

```bash
# 1. Render the dashboard for the example tenant
cd <repo-root>
bash vps-setup/scripts/render-tenant.sh vps-setup/tenants/EXAMPLE_TENANT.yml

# 2. Assemble the demo web root (rendered SPA + synthetic fixtures)
mkdir -p /tmp/mc-demo
cp vps-setup/agents-config/example-tenant/dashboard/index.html /tmp/mc-demo/index.html
cp -R docs/demo/api /tmp/mc-demo/api

# 3. Serve it (static server; query strings are ignored for path resolution)
cd /tmp/mc-demo && python3 -m http.server 8799 &

# 4. Capture (needs Playwright + chromium: `npx playwright install chromium`)
cp <repo-root>/docs/demo/shoot*.mjs /tmp/mc-demo/
cd /tmp/mc-demo
npm install playwright
OUT=<repo-root>/docs/images node shoot.mjs
OUT=<repo-root>/docs/images/mc-chat.png node shoot-chat.mjs
```

The capture uses a 1440×900 viewport at 2× device scale for retina-crisp images.

## Privacy rule

**Never publish screenshots of a live/production Mission Control.** It shows real
tasks, deals, contacts, and dollar figures. Either use this synthetic harness, or
redact every private detail before committing a production capture.
