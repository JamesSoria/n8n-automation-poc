# n8n Automation POC — Four Assistants on One Backbone

A proof of concept for four AI-assisted business workflows — phone,
inbox, documents, and CRM follow-up — deliberately built on **one**
self-hosted n8n instance and **one** Postgres database, to test whether
a shared guardrail-and-audit backbone actually holds up across
channels or only looks good on a diagram.

The recurring pattern in all four: an AI does the reading or the
reasoning, a deterministic check decides whether its output is allowed
to have an effect, and every action leaves a row in one queryable audit
log — including the actions that were refused.

This is a showcase of the build, not a step-by-step tutorial. The more
interesting part is the debugging, written up in
[`docs/lessons-learned.md`](docs/lessons-learned.md).

## The shared backbone

```
  Phone          Inbox          Documents        CRM sync
    │              │                │               │
    ▼              ▼                ▼               ▼
┌──────────────────────────────────────────────────────────┐
│                    n8n (self-hosted)                     │
│                                                          │
│   Each workflow ends in a check that decides whether     │
│   the AI's output is allowed to have an effect:          │
│                                                          │
│     Phone      → allow-list on callable functions        │
│     Inbox      → confidence gate before a draft exists   │
│     Documents  → confidence flag on a stored record      │
│     CRM        → sync-state flag, so retries can't       │
│                  double-write                            │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
         PostgreSQL — audit_log + documents
         one database, every product writes here
```

The guardrails are intentionally *not* identical, because the risk
isn't. Blocking is right when an action is irreversible (a phone agent
about to invoke a function). Flagging is right when the action is cheap
and reversible (writing a database row) — there, discarding a
low-confidence extraction loses information for no benefit, so the row
gets written with `status = 'needs_review'` instead. Same backbone,
different verdict shape per workflow.

## The four workflows

| Workflow | Trigger | AI does | Check before effect |
|---|---|---|---|
| [Phone](n8n-workflows/phone-vapi-webhook.json) | Webhook, mid-call | Handles the live conversation | Allow-list — disallowed function calls are blocked and logged |
| [Inbox](n8n-workflows/inbox-gmail-draft-assistant.json) | Unread mail poll | Drafts a reply from a documented Q&A set | Confidence gate — no draft is created at all if the answer isn't covered |
| [Documents](n8n-workflows/documents-extraction-assistant.json) | Unread mail with a PDF | Reads the document, extracts fields + page refs | Confidence flag — record always written, marked `needs_review` when unsure |
| [CRM](n8n-workflows/crm-escalation-sync.json) | Schedule | *(none — deterministic)* | Sync flag written only after both CRM writes succeed |

Two design notes worth calling out:

**Inbox never sends.** It creates a Gmail *draft* on the original
thread. A human opens their mailbox and presses send, or doesn't. The
uncovered-question path produces no draft and an escalation row instead
of a hedged non-answer.

**Documents needs no separate OCR step.** The model's API takes PDFs
directly as a document content block and images as an image block, so
scanned photos and native PDFs go through one code path that branches
only on MIME type. That removed an entire vendor from the stack
compared to a traditional OCR-then-LLM pipeline.

## Stack

- **n8n** (self-hosted, Docker) — orchestration/business logic layer
- **PostgreSQL** — audit log + application data, in a separate database
  from n8n's own internal state
- **A voice AI platform** — handles the live phone call; calls back
  into n8n via webhook mid-call and again at the end
- **An LLM API** (Anthropic Messages API, `claude-sonnet-5` as
  configured here) — drafting for Inbox, document reading for Documents
- **Gmail API** — intake and draft creation for Inbox and Documents
- **A CRM platform** — contact/deal upsert target for the sync workflow
- **Docker Compose** — local/single-host deployment

## What's real vs. placeholder

**Verified end-to-end**, against server-side evidence rather than
"it looked right":

- **Phone** — a disallowed action was confirmed blocked; a legitimate
  one confirmed logged.
- **Inbox** — both outcomes confirmed: a covered question produced a
  real threaded draft; an uncovered one produced no draft and a clean
  escalation row. The unattended polling trigger was confirmed
  specifically, not just a manual run.
- **Documents** — every field extracted correctly from a generated
  sample invoice, including per-field page references, and the stored
  bytes matched the original file size exactly, confirming the base64
  round-trip through Postgres `decode()` was lossless.
- **CRM** — contact and deal confirmed correctly linked in the CRM's
  own UI, after fixing a silent ID-field bug (see lessons-learned).

**Deliberately left as placeholders for a POC:**

- The Inbox knowledge base is four generic Q&A pairs in a code node,
  not a real content source.
- Documents processes only the *first* attachment per email
  (`attachment_0` is hardcoded); multi-attachment mail needs a loop.
- Documents has only been tested against clean generated PDFs — real
  scans, photos, and faxes will need prompt tuning.
- Phone's "look something up" logic echoes its input rather than
  querying a real system, and telephony was tested through the voice
  platform's browser test call, not a live number.
- No monitoring/alerting layer. Failures are visible in the audit log
  if you go looking, which is not the same thing.
- Single-tenant. Multi-client would need credential isolation per
  tenant — realistically an instance per client, not row-level
  separation in one instance.

## Running it

```
cp .env.example .env      # set a real password
docker compose up -d
```

Then:

1. Apply `sql/schema.sql` to a database named `automation`.
2. Import the workflows from `n8n-workflows/` into n8n. They import
   **inactive** — credentials must be attached before any of them are
   safe to enable, particularly the Gmail-polling ones.
3. Create credentials in n8n and attach them. Every workflow file has
   its credential IDs replaced with placeholders like
   `<your-n8n-postgres-credential-id>`; n8n will show these nodes as
   needing credentials until you point them at your own.
4. For Phone, configure the voice platform's tool-calling webhook to
   hit `/webhook/vapi` on your n8n instance.

### Scaling note

`documents.file_bytes` stores real file bytes in Postgres. That is
fine at POC volume and will grow the database noticeably faster than
the other workflows' mostly-text rows once real volume arrives. The
migration — swap the column for an object-storage key — is small, but
it is much easier to do before there is data to move than after.

## Notes

See [`docs/lessons-learned.md`](docs/lessons-learned.md) for the
non-obvious failures hit during these builds. The short version: every
single one of them ran without throwing an error and silently produced
wrong output, which is more dangerous than a crash.
