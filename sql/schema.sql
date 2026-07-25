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
