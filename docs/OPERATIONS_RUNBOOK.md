# QBOClone development operations and recovery runbook

**This is an operational baseline, not evidence of a production backup or security attestation.** It must be adopted and validated using actual hosting credentials before launch.

## Service monitoring
- API liveness: `GET /health`, process responds.
- API readiness: `GET /ready`, confirms database access; use for load balancer routing and alerting.
- Monitor non-2xx billing endpoints and `/stripe/webhook` 5xx retries. Configure Stripe Dashboard failure alerts and event-replay drills.
- Keep application, managed database and job logs with restricted access and appropriate retention. Never log Stripe signatures, Supabase JWTs, invitation links, or API credentials.
- Enable uptime checks and latency/SLO alerts. Configure rate-limit alerting and explicit incident ownership.

## Backup scheduling
Use the hosting platform's managed Postgres point-in-time recovery and automated snapshots. Additionally, if organizational policy requires logical exports:
1. Inject `DATABASE_URL` from a secrets manager as an environment variable.
2. Set `BACKUP_DIR` to a locked-down encrypted disk or temporary staging location.
3. Run `sh scripts/backup-postgres.sh` from a trusted worker on a schedule.
4. Encrypt and transfer the resulting `.dump` and `.sha256` to independent off-host storage.
5. Rotate backups per documented retention and regulatory obligations. Do not assume a generic retention period overrides CRA requirements.
6. Monitor backup success/failure and alert if a scheduled job is missed.

The script verifies PostgreSQL archive structure, but is NOT itself a scheduler or cloud-backup uploader. The CLI backup can expose secrets if the environment is not secured. Use an account with only the necessary permissions.

## Recovery rehearsal
- Restore to a **new disposable database**, never a live accounting tenant:
  `createdb qboclone_restore && pg_restore --no-owner --no-acl -d qboclone_restore /secure/backup.dump`.
- Verify migration versions, role policies, journal integrity, subscription references, and RLS policies.
- Validate a real sample tenant's trial balance, posted documents and bank reconciliation balances.
- Verify application sign-in using a real Supabase Auth project. A generic PostgreSQL dump is not a complete Supabase managed platform backup.
- Record recovery time (RTO), recovery point (RPO), backup age, and incident logs.

GitHub's PostgreSQL integration job restores a test fixture to a new database; this proves the restore workflow in CI, not production recovery.

## Operations controls
- Rotate Stripe/Supabase/Resend credentials using a secret manager. Service-role credentials are only present on the API server.
- Configure Supabase Auth allowed password-reset redirect URLs and verified-email policies.
- Configure the Resend sending domain and sender identity, then exercise invitation delivery in development.
- Enable auditing of privileged database administration separately, because a database superuser can disable triggers.
- Restrict production database and Stripe dashboard access, require MFA, and maintain tested least-privilege support access.
- Keep a documented incident response contact and a controlled financial data export procedure.
- Test exports and account recovery in a disposable Supabase environment before onboarding customers.

## Scale limitations
- API exports are capped at 10,000 records per table and 20 MiB. The endpoint fails explicitly if either limit is exceeded, it never silently truncates.
- API export response construction uses memory, it is suitable for small and medium organizations. Larger organizations need a queued encrypted archive job.
- Bank import quotas are based on unique newly ingested CSV rows by UTC calendar month; duplicate reimports do not consume quota. Resetting an import does not refund quota.
- Web pagination supports audit events in pages of 50. Financial document and journal-list pagination still requires future refinement.

## Production acceptance checklist
- [ ] Real Supabase schema migration and RLS negative tests
- [ ] Stripe test-mode checkout, renewal, cancellation and webhook replay
- [ ] Resend invitation delivery and verified-email redemption
- [ ] Auth password reset, session revocation and MFA
- [ ] Backend rate-limit testing and response security header inspection
- [ ] Production backup schedule, encrypted off-site storage and restored snapshot
- [ ] SLO monitoring and operational incident runbook drill
- [ ] Canadian privacy, retention and accountant acceptance review
