# Durable command quotas

The CLI shares one quota store across all MCP HTTP sessions. Every counted command
is durably reserved **before** execution. Reconnecting or restarting the service
does not reset the rolling 24-hour budget. Failed executions may still consume a
reservation; denied policy/approval requests do not. Unlimited profiles are not counted.

By default `quota.json` lives beside the audit log. `SSH_MCP_QUOTA_FILE` selects an
absolute, service-owned persistent local path. The immediate parent must be owned by the service account, not be a symlink, and
not be group/world-writable on POSIX. Its ancestors must also be protected from
replacement by untrusted users. Keep this file in a persistent volume
when using containers. Profile names are the accounting keys: changing a profile's
name deliberately creates a new budget, so configuration access is administrative.

Instances on the **same host** must share the same file. Each reservation acquires
an exclusive directory lock, reloads the latest state and atomically replaces it
with an fsynced mode-0600 file. The synchronous transaction does not yield between
policy checking and quota reservation. Lock contention fails closed for that request;
it does not wait indefinitely or grant a free command. Separate hosts, NFS and
independent volumes are not a supported global quota deployment; use one controller
or a separate central quota service instead.

Corrupt state, unsafe/symlink state files, write failures and lock conflicts refuse
execution. Do not delete state to "fix" a refusal: that resets the budget. A crash
inside a transaction can leave `<quota.json>.lock`. Stop **all** instances using
that state file, verify no transaction remains, preserve the state for inspection,
then remove only the orphaned lock and restart. Automatic time-based lock stealing
is intentionally avoided: a slow live writer must not race a second process.

Quotas are an operational circuit breaker, not protection against the service's
own OS account or a root attacker modifying its state. They do not replace target
permissions, approval or independent audit storage.
