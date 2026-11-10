# Platform administration and organization invitations

## Platform administrator vs. organization administrator

A **platform superadmin** is an operator for the Ledger North SaaS installation. It can view a limited list of businesses, provision new organizations, and assign an existing *verified* Supabase user as their owner. It **does not** inherit tenant membership, bypass financial RLS, or gain permission to inspect customer books.

An **organization administrator** is a scoped business role. An owner/administrator may invite staff into that business, subject to subscription seat entitlements. Only an organization owner can invite another organization administrator according to the current role rules.

## Promote the first platform superadmin

1. Apply `supabase/migrations/20261110420000_platform_administration.sql` after every earlier migration.
2. Register a user using the web application and complete email confirmation. Find the intended user's UUID under Supabase Dashboard > Authentication > Users.
3. From the **Supabase SQL Editor**, while authenticated as the database administrator (never via a browser SDK or public API), replace the placeholder below with the **verified** user UUID and execute:

```sql
insert into private.platform_superadmins(user_id)
select id
from auth.users
where id = 'REPLACE_WITH_VERIFIED_USER_UUID'::uuid
  and email_confirmed_at is not null
on conflict (user_id) do nothing;
```

To revoke platform privileges later:

```sql
delete from private.platform_superadmins
where user_id = 'REPLACE_WITH_USER_UUID'::uuid;
```

No public registration path, user metadata, invitation or organization role can grant platform-superadmin access. Do not hardcode a privileged email/UUID or share the Supabase service-role key with a browser. Rotate credentials and audit manual operator changes separately.

4. Sign out and sign back in. The navigation sidebar displays **Platform admin** only if the authenticated user is in the allowlist.
5. Open Platform admin, enter a business name and **an already registered, verified account's email address**, then select **Provision organization**. The target user becomes the owner and gets the standard chart of accounts and current fiscal period. The provisioning event is recorded in `private.platform_admin_events`.
6. The resulting organization appears in the platform list. It will appear in the owner's organization dropdown after they sign in.

## Member invitations

Open an organization as an owner/administrator, then go to **Settings > Team and accountant access > Invite a team member**. Choose a role and one of:

- **Secure invitation link** (default): create a one-time, seven-day link, then share it directly with the intended email holder. Works even without Resend. The recipient must sign in to a *verified* account matching the invited email and accept the invitation.
- **Send email via Resend**: requires `RESEND_API_KEY`, `INVITATION_EMAIL_FROM`, verified sending domain, and reachable `/api/organizations/invite-email`. If Resend rejects the request, the endpoint attempts to revoke the newly created invitation; the UI reports the failure instead of claiming delivery.

**Subscription restriction:** An unsubscribed organization may have only its initial owner. Additional users cannot accept invitations until a qualifying subscription is active and has available seats. A platform superadmin does not bypass this billing restriction.

## Verification

Run the complete ordered migrations, `supabase/tests/platform_admin_regression.sql`, web/API TypeScript checks, Vitest and builds through GitHub CI. Against an isolated staging environment, verify a platform admin can provision a business, an ordinary account receives 403 from platform endpoints, the platform user cannot read the organization's financial records, and signed invitations are correctly redeemed by the matching verified email.

This feature does not substitute for a production security assessment, CPA validation or the Milestone 10 release gates.
