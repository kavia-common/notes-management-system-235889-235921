#!/bin/bash
set -euo pipefail

# Repeatable schema provisioning for the notes app.
# Runs safely on every startup (uses IF NOT EXISTS / CREATE OR REPLACE patterns).
#
# Uses existing container conventions:
# - Reads connection command from db_connection.txt
# - Executes schema statements against the configured DB
#
# Notes on escaping:
# - We execute SQL via psql using heredoc to avoid complex shell escaping.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${SCRIPT_DIR}/db_connection.txt"

if [ ! -f "${CONN_FILE}" ]; then
  echo "❌ ${CONN_FILE} not found. startup.sh should create it before provisioning schema."
  exit 1
fi

# db_connection.txt typically contains: psql postgresql://user:pass@host:port/db
PSQL_CMD="$(cat "${CONN_FILE}")"

echo "Applying notes app schema (repeatable)..."
echo "Using connection: ${PSQL_CMD}"

# Apply schema
${PSQL_CMD} -v ON_ERROR_STOP=1 <<'SQL'
-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Users table (authentication managed by backend; this table stores hashed password, etc.)
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ NULL
);

-- Enforce case-insensitive unique email
CREATE UNIQUE INDEX IF NOT EXISTS users_email_unique_ci_idx ON users (lower(email));

-- Notes table
CREATE TABLE IF NOT EXISTS notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  is_archived BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Per-user listing indexes (common query patterns: list notes for user, order by updated/created)
CREATE INDEX IF NOT EXISTS notes_user_updated_at_idx ON notes (user_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS notes_user_created_at_idx ON notes (user_id, created_at DESC);

-- Lightweight filtering support for archived/non-archived lists
CREATE INDEX IF NOT EXISTS notes_user_archived_updated_at_idx ON notes (user_id, is_archived, updated_at DESC);

-- Search:
-- Use GIN full-text index on (title + content) for fast search per user.
-- We include user_id in the index to keep searches efficient per-user.
ALTER TABLE notes
  ADD COLUMN IF NOT EXISTS search_document tsvector
  GENERATED ALWAYS AS (
    setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(content, '')), 'B')
  ) STORED;

CREATE INDEX IF NOT EXISTS notes_user_search_gin_idx
  ON notes
  USING GIN (user_id, search_document);

-- updated_at maintenance trigger (kept generic and re-usable)
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS users_set_updated_at_trg ON users;
CREATE TRIGGER users_set_updated_at_trg
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS notes_set_updated_at_trg ON notes;
CREATE TRIGGER notes_set_updated_at_trg
BEFORE UPDATE ON notes
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
SQL

echo "✅ Schema applied successfully."
