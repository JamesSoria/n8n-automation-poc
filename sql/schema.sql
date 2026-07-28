-- Run against a fresh database named "automation" (kept separate from
-- n8n's own internal database so application data never mixes with
-- the platform's own schema).

CREATE TABLE audit_log (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  source TEXT NOT NULL,       -- which product wrote this row, e.g. 'phone'
  actor TEXT,                 -- caller id / user / system that triggered the action
  action TEXT NOT NULL,       -- what happened
  details JSONB,              -- full context/payload
  status TEXT NOT NULL,       -- success / blocked / escalated / error
  reason TEXT                 -- why, especially for guardrail blocks
);

CREATE INDEX idx_audit_log_source_created ON audit_log (source, created_at DESC);

-- Sync-tracking columns, added for the CRM workflow.
-- These live on audit_log rather than in a separate sync table on purpose:
-- the thing being synced IS an audit row (an escalation), and a second table
-- would just need joining back to this one on every query.
ALTER TABLE audit_log
  ADD COLUMN synced_to_crm   BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN crm_contact_id  TEXT,
  ADD COLUMN crm_task_id     TEXT;

-- Partial index: the sync job only ever scans for unsynced escalations, so
-- indexing the synced rows too would be dead weight.
CREATE INDEX idx_audit_log_pending_sync
  ON audit_log (created_at)
  WHERE synced_to_crm = false AND status = 'escalated';


-- Structured output from the document-extraction workflow.
CREATE TABLE documents (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  source TEXT NOT NULL,       -- intake channel, e.g. 'documents'
  source_ref TEXT,            -- message/thread id the file arrived on
  file_name TEXT,

  -- The actual file bytes, not a pointer back into the mailbox. A reference
  -- would break the moment the source email is deleted, and storing the file
  -- here keeps the record self-contained if another intake channel is added
  -- later. See the README's scaling note before running this at volume.
  file_bytes BYTEA,

  document_type TEXT,         -- invoice / receipt / form / ...
  vendor TEXT,
  total_amount NUMERIC,
  document_date DATE,

  -- Full model output, including per-field page references so any extracted
  -- value can be traced back to where on the document it came from.
  extracted JSONB,

  status TEXT NOT NULL,       -- extracted / needs_review
  reason TEXT
);

CREATE INDEX idx_documents_status ON documents (status, created_at DESC);
CREATE INDEX idx_documents_vendor ON documents (vendor);
