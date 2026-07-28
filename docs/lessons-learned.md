# Debugging notes from the build

A few non-obvious things surfaced while building this that are worth
recording, since none of them were documented anywhere obvious at the
time.

## 1. n8n's newer "Publish" model doesn't fully engage on CLI-imported workflows

This n8n version replaced the old simple Active on/off toggle with a
proper draft/publish versioning system (backed by dedicated
`workflow_published_version` / `workflow_publish_history` tables).

Importing a workflow via `n8n import:workflow` writes directly into
the legacy `workflow_entity` table and flips `active = true`, and the
UI will even show it as "Published." But the actual webhook route
never got registered correctly — every request came back
`"POST vapi" is not registered`, even after a full container restart.

**Fix:** cycle it through the UI once — Unpublish, then Publish again.
That forces the real save/publish code path (which a raw CLI import
bypasses) and the webhook registers correctly. Confirmed via the
`webhook_entity` table: before the cycle the stored path was mangled
into something like `{workflowId}/vapi%20webhook/vapi`; after, it was
the clean `vapi` the node was actually configured with.

Takeaway: if you're managing n8n workflows as code (CI/CD, IaC-style
imports), budget for a one-time manual publish step per workflow, at
least on this version — don't assume CLI import alone makes a webhook
live.

## 2. Don't trust a voice AI platform's own docs over its actual payloads

The integration expects Vapi to call back with a tool-call event
shaped, per Vapi's own public docs, like:

```json
{ "id": "...", "name": "check_order_status", "parameters": { ... } }
```

What it actually sent in a live call:

```json
{
  "id": "...",
  "type": "function",
  "function": { "name": "check_order_status", "arguments": { ... } }
}
```

Nested under `function`, not flat. The guardrail logic silently
treated every real call as an unrecognized function name until this
was caught by inspecting the actual logged payload rather than
trusting the docs. The code now checks both shapes defensively.

Takeaway: for any fast-moving third-party API, verify field names
against a captured real payload before writing logic against them —
public docs can lag actual behavior.

## 3. An "it worked" from one system doesn't confirm the other side saw anything

During testing, the voice platform's own call log reported a tool
call as successful, while the receiving automation platform showed
zero matching executions for that time window at all — not a failed
execution, no trace whatsoever. Two independent systems each reporting
success/no-record isn't a contradiction to shrug off; it means the
request likely never left the boundary between them (wrong URL,
config not applied to the right assistant, etc.).

Takeaway: verify integration success from the receiving side's own
logs, not the calling side's summary label — a green checkmark on one
end doesn't prove delivery on the other.

## 4. HubSpot's legacy API returns a different ID field name per object type

The CRM workflow upserts a contact, then creates a deal, then
associates the two. It ran green end to end and produced a contact and
a deal — but they were never actually linked.

The cause: HubSpot's legacy v1 API doesn't return a uniform `id`. A
contact comes back with `vid`; a deal comes back with `dealId`. Code
written against a reasonable assumption of `response.id` got
`undefined` for both, and the association call happily fired with an
undefined identifier and returned success.

**Fix:** read the correct field per object type
(`$('Upsert Contact').item.json.vid` and `$json.dealId`), verified by
opening the contact record in HubSpot's own UI and confirming the deal
appeared on it — not by re-reading the execution log that had been
reporting success all along.

Takeaway: an API being "RESTful" implies nothing about field-name
consistency across its own endpoints, and an association call that
accepts an undefined ID without complaint will hide this indefinitely.
Migrating off the legacy v1 endpoints is the real fix; matching its
quirks is the stopgap.

## 5. Gmail's `from` field is a structured object, not a string

Writing `email.from` straight into an audit row stored something like
`[object Object]` rather than an address. Gmail's API returns a
structured value, and JavaScript stringifies it silently rather than
failing.

Worth recording not for the bug itself but for how it recurred: it was
fixed in the Inbox workflow, and then **reappeared in Documents**,
because that workflow's equivalent code node was written fresh from
the same mental template rather than copied from the corrected
version. Nothing links the two — a fix in one n8n workflow has no
mechanism to propagate to another.

Takeaway: once the third workflow reuses the same parsing logic, that
logic needs to live in one place (a shared sub-workflow, or at minimum
a documented snippet with a canonical source) rather than being
re-derived per workflow. Copy-paste inheritance silently reintroduces
fixed bugs.

## 6. n8n's base64 conversion operation has a typo in its own source

The "Extract from File" node's binary-to-base64 operation is
internally named `binaryToPropery` — missing the second `t` in
"Property". That's n8n's own naming, not a transcription error here.

Only relevant if you hand-author workflow JSON; adding the node
through the UI never exposes it. But if you're generating workflow
files programmatically, the correct spelling will silently fail to
match.

Also in the same area: binary attachment data does **not** appear just
because you turn off "Simplify" on the Gmail Trigger. The separate
"Download Attachments" option must be enabled explicitly. This was
settled by reading the trigger node's source rather than inferring
from the UI label.

## 7. Verify a byte round-trip by size, not by eyeball

The Documents workflow base64-encodes an attachment, hands it to
Postgres, and stores it via `decode($4, 'base64')` into a `BYTEA`
column. A corrupted round-trip here would still produce a row, still
look fine in a query result, and only surface much later when someone
tried to open the stored file.

The check that actually settles it is comparing
`length(file_bytes)` against the original file's size on disk —
103,767 bytes in both, in this case. Cheap, unambiguous, and it either
matches or it doesn't.

## The pattern across all of these

Every failure above ran without throwing an error. The workflow went
green, a row got written, a record got created — and the output was
wrong. That's strictly more dangerous than a crash, because "it ran
successfully" gets read as "it did the right thing."

The habit that caught all of them was the same: verify against the
actual captured payload, the actual API response, or the receiving
system's own UI — never against documentation, a UI hint, or an
assumption that an API is internally consistent.
