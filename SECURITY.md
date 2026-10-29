# Security boundaries

- The VPS owns sing-box server keys. Raw payloads explicitly project only the
  requesting user's client credentials, client TLS fields and Reality public keys.
  Server private keys, ACME credentials, listener addresses and other users'
  credentials must never leave this boundary.
- The central platform owns user policy and global quota reservations. Each VPS
  receives an independent agent credential; no remote shell endpoint exists.
- Subscriptions use 256-bit random bearer links. Only token hashes are stored.
  Replacing a link does not revoke already downloaded proxy credentials.
- Every dynamic subscription and administrative response is `no-store`.
  Template/rule caching is separate and must not include user credentials.
- The management API requires a high-entropy administrator token. The UI keeps it
  only in memory, never localStorage, cookies or URLs. Backend checks are required
  even when Cloudflare Access protects the UI. Do not apply interactive Access
  challenges to agent or subscription routes.
- Bandwagon keys are encrypted using AES-GCM, bound to their server ID. The
  encryption key is a Workers secret, separate from D1. Back up this key securely.
  Deployment rejects accidentally changing its fingerprint for an existing DB.
- Agent enrollment credentials expire after one hour. Enrollment retries are
  accepted only for the same persistent instance and agent credential.
- Treat the node's `.central` state as part of its credential and accounting
  identity. Do not clone it to another VPS, restore stale copies, or delete it
  to repair a quota issue. Register a new node identity instead.

## Operational limits

Local traffic enforcement is sampled, not byte-exact. Nodes may consume already
reserved credit during central outages, but cannot obtain new credit. Unspent
offline credit is not automatically reassigned. Counter uncertainty is handled
fail-closed, not by inventing an empty usage history.

Disabling a user or server takes effect on its next successful policy sync.
After a manual/monthly reset, disconnected nodes can still consume the previous
period's reserved credit until they synchronize. Accounting retains these reports
under the old period. No claim of instantaneous distributed revocation is made.

## Reporting and provenance

Do not put live tokens, private keys or full subscription URLs in public issues.
Use the repository's private vulnerability reporting feature when available.

See [third-party provenance](THIRD_PARTY.md) and the independent node manager's
[input record](internal/nodehost/PROVENANCE.md). A language rewrite or history
rewrite is not a legal certification.
