# Central management

## Deployment layout

One Pages project hosts `/manage`, `/admin/*`, `/agent/*` and `/s/<random-token>`.
Its `CENTRAL` service binding invokes a separate Worker. The Worker has no public
workers.dev route and owns D1, quota coordination and a ten-minute Cron Trigger.
Actual proxy traffic goes directly to the VPS, never through the control plane.

The current release uses a high-entropy administrator token, not a multi-admin
login/role system. The UI stores the token only in memory. Ordinary proxy users
are not administration accounts. `admin` is a proxy identity without personal
traffic accounting; its subscription shows all registered servers' vendor totals,
including paused servers, which still have real provider billing.

Retiring a server explicitly removes it from the current fleet and vendor
aggregate, clears its vendor credential, and stops issuing node credit.
Its accounting identity and historical reservations remain for safety; they are
not reassigned. Stop the VPS service before retiring it, because an offline node
cannot receive instant revocation. Rejoining requires a new server identity.

## Domain preparation

1. Add the existing domain to Cloudflare and finish nameserver delegation at the
   registrar. Wait for the zone to become **Active**. Preserve website, MX, TXT
   and other existing DNS records.
2. Deploy and test using `<project>.pages.dev` first; no custom DNS change is
   needed for initial validation.
3. In **Pages / Custom domains**, attach, for example, `panel.example.com` and
   `sub.example.com` to the same project. Use Cloudflare's instructed CNAME
   records and wait for domain/certificate validation. Do not point these names
   at a VPS or create a competing Worker route.
4. Use `panel.example.com/manage` for management and
   `sub.example.com/s/<token>` for subscriptions. They serve the same application.
   Replace only the hostname in a generated subscription link if needed.
5. Agents can use either the Pages hostname or the stable custom domain as their
   HTTPS central URL. Public node/WS hostnames are separate settings.

Cloudflare Access can additionally protect administration paths on **every**
reachable hostname, including the pages.dev hostname where applicable. Backend
administrator-token authentication remains mandatory. Do not put `/s/*` or
`/agent/*` behind an interactive Access login.

No DNS changes are performed by the deployment workflow.

## GitHub Actions initialization

Use the **Deploy central Cloudflare platform** workflow on `main`. Create a
GitHub `production` environment and configure required reviewers if desired.
The workflow requires explicit production confirmation and is not triggered by
ordinary pushes. Do not also enable Pages Git auto-deployment.

Set these **GitHub environment/repository secrets**:

| Secret | Meaning |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | Scoped deployment token; never share in chat |
| `SUBFLOW_ADMIN_TOKEN` | At least 32 random URL-safe characters |
| `SUBFLOW_CREDENTIAL_KEY` | 32 random bytes encoded as 64 lowercase hex characters |

Set these **variables**:

| Variable | Meaning |
| --- | --- |
| `CLOUDFLARE_ACCOUNT_ID` | Target Cloudflare account ID |
| `SUBFLOW_D1_DATABASE_ID` | Persistent D1 ID; can be empty only for initialization |
| `SUBFLOW_PAGES_PROJECT` | Direct Upload Pages project, default `subflow` |
| `SUBFLOW_WORKER_NAME` | Worker name, default `subflow-central` |

The deployment token needs account-scoped **Workers Scripts / Edit**,
**D1 / Edit**, and **Cloudflare Pages / Edit**. No domain-wide DNS edit or VPS SSH
private key is needed by this workflow. Confirm the currently available permission
labels in Cloudflare before creating the token.

For the first run, select `initialize=true`. It reuses or creates `subflow-central`
D1 and creates a Direct Upload Pages project only if missing. Save the D1 ID
printed by the workflow as `SUBFLOW_D1_DATABASE_ID` for future runs.

The job tests/builds, applies forward migrations, validates the encryption-key
fingerprint, deploys the Worker and its secrets, deploys Pages and checks
`/healthz`. It never deletes a database. Failed deployments can leave an already
applied schema migration or published Worker; this is not an all-platform
transaction. Back up D1 before production schema changes.

Keep `SUBFLOW_CREDENTIAL_KEY` stable and backed up. Changing it without a proper
re-encryption migration makes stored vendor credentials unreadable; the workflow
refuses an unexpected key change. Administrator-token rotation is independent.

## Join each VPS

Install the application and a trusted sing-box build with `with_v2ray_api`.
Configure the server's public address and at least one protocol, then create
the server in the central UI. Registration outputs a one-hour, one-use token.

On the VPS, save that token in a root-only file without putting it in shell
history or the command line. Then run:

```bash
subflow agent enroll --url https://subflow.pages.dev --token-file /root/subflow-enrollment-token
subflow enable --service agent
subflow start --service agent
subflow status --service agent
```

Remove the enrollment-token file after successful registration. The chosen agent
identity is durably stored in the user database path plus `.central`; default:
`/etc/sing-box-manager/user-manager.json.central`. Do not clone, reset or roll back
this file independently of accounting/configuration state. A lost-response retry
must use the same saved enrollment attempt.

The installer writes, but does not start, the agent service on an unenrolled
host. Updates restart it when an enrolled server ID exists. Stopping or failing
the agent service stops sing-box as a fail-closed safety measure. Use a staging
server to validate this behavior before production deployment.

In managed mode, user policy comes from the central system. Local diagnostic,
protocol and routing operations remain available; conflicting local user/quota
mutations are rejected.

## Quota and accounting semantics

- User quota is one pool shared across permitted servers. Units in storage and
  wire contracts are actual bytes; the UI uses GiB. No old display-doubling factor.
- A server receives cumulative reservations in 64 MiB chunks, topped up when
  less than 32 MiB remains. D1 transactions serialize competing reservations.
- Reservations include unspent credit. They are displayed separately from used
  traffic. Offline credit is never automatically recycled.
- An exhausted small quota can be reserved entirely by one server. Other servers
  may have no credit even though the user's unspent reserved balance is positive.
  This conservative behavior prevents double allocation; it is not a distributed
  bandwidth pool with instant credit transfers.
- Lowering quota below issued reservations is rejected. Disable the user or
  deliberately start a new period instead.
- Nodes sample/enforce usage locally and periodically synchronize with central.
  Counter uncertainty and failed statistics queries are fail-closed; shutdown is
  not byte-exact. The UI is eventually consistent, not a live packet counter.
- Upload and download totals are cumulative per server/user/period. Sequence and
  request-digest checks make retries idempotent; counter regression is rejected.
- Monthly reset uses Asia/Shanghai midnight, days 1–31 clamped to the month, or
  32 for month end. Day 0 is manual reset. Missed cron periods advance on recovery.
- Old-period reports remain valid for history. An offline node can still consume
  its old reservation until it receives the new period. Reset is not instantaneous
  revocation of every running connection.

The HTTP sync envelope is version 1, at most 1 MiB, 128 usage reports, payload
owners and inventory entries per request. This deployment currently supports up
to 100 users and 50 registered server identities. It is aimed at small private
fleets, not an unbounded commercial multi-tenant service.

## Bandwagon statistics

Configure a VEID and KiwiVM API key per server in the UI. Keys are AES-GCM
encrypted with server-specific associated data. Only the central Worker calls
`POST https://api.64clouds.com/v1/getServiceInfo`; no credentials appear in URLs.

The adapter requires `error=0`, `plan_monthly_data`, `data_counter`,
`monthly_data_multiplier`, and `data_next_reset`. It scales both byte fields by
the provider multiplier, preserves the multiplier/reset time, and rejects
missing, negative or unsafe values. This follows the available mirrored KiwiVM
field descriptions; direct official-document retrieval and live account comparison
were not available during implementation. **Compare one live response against
the KiwiVM panel before treating these values as billing-verified.**

Cron collects every ten minutes; a manual refresh is available. Failure preserves
the last success and marks an error. A reset that has passed, an error, absent
data, or data older than thirty minutes makes the aggregate incomplete.

The admin subscription returns 503 rather than inventing a zero balance when
the aggregate is incomplete. Other users' subscriptions do not depend on the
vendor API. Current vendor balances across different billing cycles are summed;
they are not interchangeable credit between servers. Over-quota servers contribute
zero remaining, never a negative amount that reduces another server's balance.

## Subscriptions and readiness

The UI creates/rotates `/s/<256-bit-random-token>` links. Only token hashes are
stored, and links are shown once. Existing username-only routes are disabled when
Pages has the `CENTRAL` binding. Client-format generation remains on Cloudflare.

Nodes enter a subscription only after an agent reports the relevant applied
policy revision, with a payload no more than five minutes old. Policy changes
may temporarily produce 503 until synchronization. A server outage does not
prevent rendering other recently synchronized servers. Token rotation invalidates
the link, not already downloaded node credentials.

## Local validation and cost

```bash
npm ci
npm run typecheck
npm test
npm run dev:central
```

The local server listens on `127.0.0.1:8790`, uses disposable in-memory D1 and a
printed **development-only** admin token. Do not enter real credentials there.
Automated tests use actual local workerd/D1, including concurrent reservation,
rollback and retry behavior. This does not prove actual Cloudflare deployment or
Debian PID1/systemd behavior.

No paid plan is automatically enabled. Free-plan requests, CPU, subrequest and
D1 write/storage limits still apply. The number of users multiplied by sync
frequency can exhaust D1's free write budget even with few VPSes; monitor the
account and tune or upgrade deliberately. Do not interpret the design as a
guarantee of zero operating cost.
