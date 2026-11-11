# Ledger North mobile receipt capture

## Scope
The principal is the **organization owner**. Owners configure tenant-specific locations in the web app. A member of the same organization enables background geofencing in the Expo iOS/Android app. The OS schedules a local notification following an entry event and a configurable dwell interval, default five minutes. Tapping it opens camera/receipt intake.

The mobile app uses the existing Fastify receipt upload endpoint (private Supabase Storage) and the existing consent-required Google Cloud Vision OCR route. After extraction, an authenticated Supabase RPC creates a **needs_review** candidate classified as outgoing expense or incoming payment evidence. **Nothing is automatically posted into the general ledger, expenses, customer receipts, or invoice settlement**. Human review of totals, tax treatment, vendor and payment reference is required. An incoming-payment receipt is evidence, not proof a specific invoice was paid.

## Required configuration
1. Apply migration `20261111170000_location_receipt_capture.sql` **after** existing receipt migrations in staging. Validate RLS, owner-only writes and audit trail.
2. Set `EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_ANON_KEY`, `EXPO_PUBLIC_API_URL` (HTTPS API base ending in `/api`) as EAS build environment variables, and `EAS_PROJECT_ID` as a GitHub Actions variable.
3. Create an Expo EAS project and configure Apple certificates/provisioning and Google Play service account in EAS. Set protected `mobile-release` GitHub environment, `EXPO_TOKEN` secret, and configuration variables used in `.github/workflows/mobile.yml`.
4. Replace `SET_APP_STORE_CONNECT_APP_ID` in `apps/mobile/eas.json` before iOS store submission.
5. Create a private `receipts` Supabase Storage bucket and configure Google Cloud Vision on the existing API as documented in `docs/MILESTONE_7.md`.
6. Run `npm install` from repository root to update the lockfile, then `npm run typecheck -w @qboclone/mobile`; build with `npx eas-cli build --platform all --profile preview` from `apps/mobile`, after native credentials are configured.
7. Manually invoke the Mobile validation and EAS builds GitHub workflow. Production submission is opt-in and protected by the `mobile-release` environment.

## Platform reliability and privacy
- Native platform geofences monitor location without polling GPS continuously. Foreground, background and notification permissions must be granted.
- iOS permits 20 active monitored regions. This first version deliberately refuses more than 20 instead of silently dropping locations. Multi-organization simultaneous monitoring is not yet implemented.
- Local notification timers are cancelled on exit where the OS delivers exit promptly; exact five-minute dwell is **not guaranteed**. Android OEM restrictions, iOS scheduling and permission revocation can affect delivery. Do not describe these as guaranteed push messages.
- Disabled locations already registered on a device are removed when the user refreshes and re-enables monitoring. Real-time server-to-device geofence invalidation requires a future change.
- No continuous coordinate history is uploaded. Locations are configured by owners in Supabase and monitored locally, with local notifications rather than server push.
- App Store background-location privacy disclosure, explicit consent, physical device testing and privacy policy updates are mandatory before publication.
- OCR is third-party processing and only proceeds after the member opts in for that receipt. Receipts are retained privately and subject to existing access controls.
- Migrations and application builds are not evidence of real-provider financial/compliance acceptance.
