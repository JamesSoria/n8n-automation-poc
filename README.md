# n8n Automation POC — AI Phone Assistant

A proof of concept for an AI-answered business phone line: calls get
handled by a voice AI agent, routine requests get resolved on the
spot, anything the agent can't (or shouldn't) resolve on its own gets
flagged for a human — and every single action is logged and checked
against a limit before it's allowed to run.

This is a showcase of the build, not a step-by-step tutorial — the
interesting parts are the architecture decisions and the debugging,
which are written up in [`docs/lessons-learned.md`](docs/lessons-learned.md).

## Architecture

```
 Caller
   │
   ▼
┌─────────────────────────┐
│   Voice AI platform     │   speech-to-text, LLM reasoning,
│  (handles the live call)│   text-to-speech — kept out of the
└───────────┬─────────────┘   automation layer entirely; live
            │ webhook            voice is too latency-sensitive
            ▼                    to route through a workflow tool.
┌─────────────────────────────────────────────┐
│                n8n workflow                 │
│                                               │
│  Webhook trigger                              │
│      │                                        │
│      ▼                                        │
│  Guardrail check (allow-list on what the      │
│  agent is permitted to actually do)           │
│      │                                        │
│      ├──► Audit log insert (Postgres)         │
│      │      every action: who, what, when,    │
│      │      status, and why if blocked        │
│      │                                        │
│      └──► Response back to the voice platform │
└─────────────────────────────────────────────┘
            │
            ▼
      PostgreSQL (audit_log)
```

The guardrail and audit-log pattern here isn't specific to phone
calls — it's meant to be the same shared backbone underneath any
other automated channel (inbox, forms, chat, etc.): every action gets
checked against a limit before it runs, and every action leaves a
permanent record of who/what/when/why, queryable in one place instead
of scattered across logs nobody looks at.

## Stack

- **n8n** (self-hosted, Docker) — orchestration/business logic layer
- **PostgreSQL** — audit log + application data, kept in a separate
  database from n8n's own internal state
- **A voice AI platform** — handles the actual phone call (speech ↔
  text ↔ conversation); calls back into n8n via webhook mid-call for
  lookups/routing, and once more at the end of the call with a full
  report
- **Docker Compose** — local/single-host deployment

## What's real vs. placeholder

Implemented and tested end-to-end: the webhook contract, the
guardrail allow-list (verified to correctly block a disallowed
action), and the audit trail (verified to correctly log both allowed
and blocked actions).

Intentionally left as placeholders for a POC: the actual "look
something up" business logic (currently echoes back what it was
asked, not wired to a real system), live human-handoff notification
(currently just flags a status in the audit log rather than paging
anyone), and real telephony (tested via the voice platform's
browser-based test call, not a live phone number).

## Running it

```
cp .env.example .env      # set a real password
docker compose up -d
```

Then apply `sql/schema.sql` to a database named `automation`, import
`n8n-workflows/phone-vapi-webhook.json` into n8n, point a Postgres
credential at your `automation` database, and configure your voice AI
platform's tool-calling webhook to hit `/webhook/vapi` on your n8n
instance.

## Notes

See [`docs/lessons-learned.md`](docs/lessons-learned.md) for the more
interesting part: three non-obvious issues hit during the build and
how they were diagnosed (a workflow-versioning quirk, a third-party
API whose real payloads didn't match its own docs, and a cross-system
verification gap).
