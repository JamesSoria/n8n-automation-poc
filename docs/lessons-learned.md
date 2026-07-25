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
