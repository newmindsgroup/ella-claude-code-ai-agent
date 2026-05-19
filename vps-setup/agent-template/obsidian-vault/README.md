# {{TENANT_PERSON_FIRST_NAME}}'s Memory Vault — Obsidian view

This folder is the **Obsidian-compatible mirror** of the agent's SQLite memory vault.

## How it works

```
vault.db (SQLite + FTS + embeddings)         ← canonical store, written by memory-vault.sh add
       ↓
memory-export.py (runs every 5 min)          ← bridges SQLite → markdown
       ↓
obsidian-vault/memories/<type>/m-XXXX.md     ← one markdown file per memory, with wikilinks
       ↓
Syncthing (optional)                          ← real-time fs-watcher sync to {{TENANT_PERSON_FIRST_NAME}}'s Mac
       ↓
Obsidian on {{TENANT_PERSON_FIRST_NAME}}'s Mac        ← browse + graph view + backlinks
```

The agent NEVER writes to this vault directly. Edits made here in Obsidian are picked up by `memory-corpus-sync` (the next-best-thing if Discord is also disabled — when {{TENANT_PERSON_FIRST_NAME}} edits a memory in Obsidian, the agent imports the change) or the canonical store stays one-way.

## Structure

```
obsidian-vault/
├── README.md                  ← this file
├── brand/                     ← brand canon (voice, services, narrative) imported from brand_repo
├── daily/                     ← session summaries, daily briefs (auto-written by session-summary.sh)
├── inbox/                     ← scratch space for things not yet classified
└── memories/
    ├── facts/                 ← memory.type = 'fact'
    ├── decisions/             ← memory.type = 'decision'
    ├── relationships/         ← memory.type = 'relationship' (entity-linker output)
    ├── preferences/           ← memory.type = 'preference'
    ├── patterns/              ← memory.type = 'pattern' (self-improvement output)
    ├── commitments/           ← memory.type = 'commitment' (commitment-log.sh + watcher)
    ├── goals/                 ← memory.type = 'goal'
    └── context/               ← memory.type = 'context'
```

## Memory file format

Each `m-<date>-<hash>-<slug>.md` follows:

```markdown
---
id: m-20260513-e9db-to-jane-doe-acme-corp-contract
type: commitment
tags: [commitment, jane-doe, acme-corp]
source: telegram
created_at: 2026-05-13T18:33:12Z
expires_at: 2026-05-20T00:00:00Z
confidence: 0.95
access_count: 3
last_accessed: 2026-05-19T12:18:00Z
supersedes: null
superseded_by: null
---

# To <Contact Name> (<Company Name>)

{{TENANT_PERSON_FIRST_NAME}} committed to sending the contract revision by Wed May 20.

Linked: [[contact-name]] [[company-name]] [[contract-v3]]

## History

- 2026-05-13: created via /commitment-log
- 2026-05-18: nudged by commitment-deadline-watcher (4h before deadline)
```

The `[[wikilinks]]` are real — Obsidian renders them as backlinks and the Graphify graph picks up the connections.

## Syncing to your Mac

OPTIONAL. If you want to browse memories in the Obsidian app on your Mac:

1. Install Syncthing on the VPS (`scripts/install-syncthing.sh` if shipped — see `vps-setup/runbooks/syncthing-setup.md`)
2. Install Syncthing on your Mac
3. Pair the two devices (each Syncthing UI shows a device ID; add the other one)
4. Share the `{{TENANT_ID}}-memory-vault` folder (sendonly from VPS → your Mac)
5. Open the synced folder in Obsidian as a vault

The VPS is `sendonly` so edits on your Mac don't push back. The canonical store stays SQLite.

## Don't commit memory files to git

The `obsidian-vault/memories/*` folder is in `.gitignore`. It's user state, not template content. Only this README and the directory structure get committed.
