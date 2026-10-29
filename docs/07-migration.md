# 07 · Migration and compatibility

## Scope

The initial Go port has been replaced by a separately implemented
[node manager](../internal/nodehost), with its
[restricted-input provenance](../internal/nodehost/PROVENANCE.md) retained.
See [third-party sources](../THIRD_PARTY.md); neither changing language nor
rewriting history is a legal certification.

The target is Go for VPS business logic and TypeScript for the Cloudflare
gateway. Only the minimal download/install bootstrap remains Shell. The
application is not a Go wrapper around the previous Bash or Python programs.

The migration is complete only when all replacement implementations build,
their tests pass, release archives are usable, and legacy runtime invocations
are absent. A successful API smoke test alone does not certify the installer
or every routing operation.

## Existing data

Do not delete or reset these paths:

- `/etc/subflow/subflow.env`
- `/etc/sing-box/config.json`
- `/etc/sing-box-manager/user-manager.json`
- `/etc/sing-box-manager/meta.json`

The legacy username convention remains `<node>@<business-user>`; node users
without `@` belong to `admin`. Quotas, usage counters, reset periods and
expiration dates must survive the migration. Business dates use Asia/Shanghai
unless explicitly configured otherwise.

The new state helper uses the same default manager lock path:
`/var/lock/singbox-manager.lock`. This supports a controlled transition, not
indefinite simultaneous operation of two different managers.

## Production rollout

Do not use the **legacy** `sf update` to cross the language-migration boundary:
that updater expects the old Python/Shell repository layout. Use a completed,
published Go application release and its new bootstrap instead. The new
application's `sf update` manages subsequent native application releases.

1. Build/test the candidate and create a checksummed release archive.
2. Back up the old binary/scripts, env file, service units and persistent data.
3. Test the candidate against copies of the real JSON files in an isolated
   environment. Never test modifying commands against live production files.
4. Stop old scheduled writers before switching runtime
   entry points. Retire old cron entries when installing replacement scheduling.
5. Switch the API to `subflow serve` and verify authenticated health/raw
   requests. Verify disabled users and other tenants are not exposed.
6. Exercise user changes, statistics, expiration/reset behavior, protocol
   configuration, relays/WARP and subscription formats.
7. Deploy the TypeScript gateway using the same VPS URL and token.

If a migration fails, restore the previous executable/service configuration
and the matching data snapshot before restarting the previous writers.
Restoring only a binary is not sufficient after a data-changing operation.

## Compatibility entry points

- `sf` opens deployment management.
- `s` opens sing-box management.
- `--periodic-sync` maps to the new periodic synchronization entry.
- `--daily-maintenance` maps to the new maintenance entry.
- Older retired cron flags remain harmless no-ops with a deprecation message.
- Standalone links, query aliases and environment-variable names remain available.
  Joining central management requires new random-token subscription links;
  username-only routes are disabled on the central Pages site.

The human-facing management implementation may evolve, but removing an
operation is not an acceptable substitute for porting it.

## Deliberate operational corrections

- Empty API tokens fail at startup.
- Invalid numeric/boolean/timezone configuration fails explicitly.
- Corrupt required JSON state yields a diagnostic and `503`, not a fake `404`.
- `/healthz` requires authentication, matching the original code rather than
  the previous documentation.
- Config defaults are embedded from JSON; there is no generated Shell/Python
  constants file to get out of sync.
- Application and kernel releases are separate. Kernel CI neither selects
  application releases as its version nor removes them.
- New self-signed certificates are stored as sing-box PEM arrays; existing
  certificate paths and files are preserved.
- Local manager Clash exports use JSON-compatible YAML. The public gateway's
  six subscription formats are regression-tested against the previous output.
- Chinese numbered menus remain, but use structured data tables rather than
  full-screen ANSI rendering. Mutations require confirmation; EOF cancels.
- Configured statistics failures stop accounting-sensitive mutations rather
  than silently losing traffic updates.
- Safe raw payloads now require `schema_version: 1` and client-field allowlists.
- Subscription caching is always `no-store`; traffic/quota values are no longer
  doubled for display.
- Joining central management is an explicit policy takeover, not automatic
  import of each VPS's independent user balances. Back up local state, create
  central users and permissions, then validate their new subscriptions.
- WARP still needs an external WireProxy SOCKS endpoint. The menu discovers
  and checks that endpoint and provides installation guidance; it no longer
  executes a downloaded third-party installation script.

## Validation environments

Linux is the production target. Run Go tests with race detection on Linux
(a development VM or WSL is suitable) and compile both Linux architectures.
Windows can be used for editing and type checking; application-control policy
may restrict execution of newly built test binaries. Do not disable host
security policies to run tests.

Unit tests and fake-command tests do not replace a staging VPS rollout.
Cloudflare provisioning additionally requires operator-controlled credentials
and should be tested outside production first.

CI contains separate Debian 12 and Debian 13 userspace jobs. They execute tests,
compile the application, and check the bootstrap inside official Debian images.
These containers do not run systemd as PID 1: they do not certify service
startup, reboot persistence, networking, firewall behavior or distribution
upgrades. Validate those operations on disposable Debian VMs or staging VPSes
before production rollout. An added CI job is not evidence that it has run.
