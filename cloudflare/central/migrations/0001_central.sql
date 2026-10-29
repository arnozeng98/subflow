CREATE TABLE control (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  revision INTEGER NOT NULL DEFAULT 1,
  credential_key_hash TEXT
);
INSERT INTO control (id) VALUES (1);

CREATE TABLE users (
  username TEXT PRIMARY KEY,
  enabled INTEGER NOT NULL CHECK (enabled IN (0,1)),
  quota_bytes INTEGER NOT NULL CHECK (quota_bytes >= 0),
  period INTEGER NOT NULL DEFAULT 1,
  expires_at INTEGER NOT NULL DEFAULT 0,
  reset_day INTEGER NOT NULL DEFAULT 0 CHECK (reset_day BETWEEN 0 AND 32),
  next_reset INTEGER NOT NULL DEFAULT 0,
  revision INTEGER NOT NULL DEFAULT 1,
  token_hash TEXT UNIQUE NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE servers (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  retired INTEGER NOT NULL DEFAULT 0 CHECK (retired IN (0,1)),
  enrollment_hash TEXT NOT NULL UNIQUE,
  enrollment_expires INTEGER NOT NULL,
  instance_id TEXT,
  agent_hash TEXT UNIQUE,
  last_sequence INTEGER NOT NULL DEFAULT 0,
  last_digest TEXT,
  last_response TEXT,
  applied_revision INTEGER NOT NULL DEFAULT 0,
  last_seen INTEGER,
  inventory TEXT NOT NULL DEFAULT '[]',
  veid TEXT,
  vendor_secret TEXT,
  vendor_total INTEGER,
  vendor_used INTEGER,
  vendor_reset INTEGER,
  vendor_multiplier REAL,
  vendor_updated INTEGER,
  vendor_error TEXT
);

CREATE TABLE permissions (
  username TEXT NOT NULL REFERENCES users(username),
  server_id TEXT NOT NULL REFERENCES servers(id),
  nodes TEXT NOT NULL DEFAULT '["*"]',
  PRIMARY KEY (username, server_id)
);

CREATE TABLE usage (
  username TEXT NOT NULL REFERENCES users(username),
  server_id TEXT NOT NULL REFERENCES servers(id),
  period INTEGER NOT NULL,
  up INTEGER NOT NULL DEFAULT 0 CHECK (up >= 0),
  down INTEGER NOT NULL DEFAULT 0 CHECK (down >= 0),
  grant_bytes INTEGER NOT NULL DEFAULT 0 CHECK (grant_bytes >= 0),
  PRIMARY KEY (username, server_id, period)
);

CREATE TABLE payloads (
  server_id TEXT NOT NULL REFERENCES servers(id),
  username TEXT NOT NULL REFERENCES users(username),
  payload TEXT NOT NULL,
  revision INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (server_id, username)
);

CREATE TABLE audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  action TEXT NOT NULL,
  target TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TRIGGER sequence_guard BEFORE UPDATE OF last_sequence ON servers
WHEN NEW.last_sequence <> OLD.last_sequence + 1
BEGIN SELECT RAISE(ABORT, 'sequence conflict'); END;

CREATE TRIGGER usage_monotonic BEFORE UPDATE OF up, down ON usage
WHEN NEW.up < OLD.up OR NEW.down < OLD.down
BEGIN SELECT RAISE(ABORT, 'counter regression'); END;

CREATE TRIGGER quota_guard BEFORE UPDATE OF quota_bytes ON users
WHEN NEW.username <> 'admin' AND NEW.quota_bytes < COALESCE(
  (SELECT SUM(MAX(grant_bytes,up+down)) FROM usage WHERE username=NEW.username AND period=NEW.period),0)
BEGIN SELECT RAISE(ABORT, 'quota reservation conflict'); END;

CREATE TRIGGER credential_key_guard BEFORE UPDATE OF credential_key_hash ON control
WHEN OLD.credential_key_hash IS NOT NULL AND NEW.credential_key_hash IS NOT OLD.credential_key_hash
BEGIN SELECT RAISE(ABORT, 'credential encryption key changed'); END;

CREATE INDEX permissions_server ON permissions(server_id);
CREATE INDEX usage_period ON usage(username, period);
CREATE INDEX usage_server ON usage(server_id,username,period);
CREATE INDEX audit_time ON audit(created_at);
