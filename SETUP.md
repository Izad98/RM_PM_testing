# Setting up: manager approval, e-signatures, QR reports

This adds three things to the portal:

1. **Approval workflow** — a QA analyst sends a tested sample to a manager
   (by email) instead of releasing it themselves. The manager gets an
   in-app notification (bell icon) and, optionally, an email. They review,
   sign, and either release the report or send it back with a reason.
2. **E-signatures** — both the analyst and the approver sign on-screen
   (finger, stylus or mouse) instead of a report needing to be printed and
   physically signed.
3. **QR verification** — every released report gets a QR code. Scanning it
   (either with the in-app scanner or any phone camera) opens a read-only,
   public verification page showing exactly what was signed off.

Everything here is additive — existing samples, users and workflows keep
working. Nothing is deleted.

## 1. Run the database migration

Open the Supabase SQL editor for this project and paste in the whole of
[`supabase_schema_v2.sql`](./supabase_schema_v2.sql), then run it. It's
idempotent, so it's safe to re-run.

**One thing it can't check for you:** if `public.samples.status` already
has a CHECK constraint limiting it to the old three values ('Awaiting QA',
'Under Test', 'Released'), the new constraint this file adds
(`samples_status_check_v2`, which allows 'Pending Approval' too) will fail
unless the old one is dropped first. In Table Editor → `samples` → look
under "Constraints" for anything constraining `status`, drop it, then
re-run the file. If there's no such constraint, there's nothing to do.

This migration adds:
- `profiles.can_approve` — who's allowed to be sent reports (see step 2).
- Approval/signature/QR columns on `samples`, all locked behind two
  functions (`request_approval`, `decide_approval`) via a trigger — a
  direct `update()` from the client can never set them, even though the
  app only ever holds the public anon key.
- `notifications`, RLS'd so everyone only ever sees their own.
- `get_report_by_code()` — the public QR lookup. Exact-code match only;
  there is no way to list or enumerate other reports with it.

## 2. Flag your managers as approvers

An analyst can only send a report to someone an admin has explicitly
flagged — this is deliberate, so a mistyped email (or someone who isn't
actually a manager) can never receive a real approval request.

In the app: **Users → Everyone with access**, click the "Cannot approve" /
"Can approve" pill on each QA or Admin account that should be able to
receive and release reports. Procurement accounts can't be flagged (they
don't test or approve anything).

## 3. (Optional) Turn on approval emails

Without this step, the workflow still fully works — the in-app
notification bell is the source of truth. This step adds an email on top.

1. Create a [Resend](https://resend.com) account and verify a sending
   domain (or use their `onboarding@resend.dev` sender to test before
   your domain is verified).
2. From the project folder:
   ```
   supabase functions deploy send-approval-email
   supabase secrets set RESEND_API_KEY=re_xxxxxxxx
   supabase secrets set RESEND_FROM="HEMAS QA <qa@yourverifieddomain.com>"
   ```
   (`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are provided automatically
   by the Edge Functions runtime — don't set those yourself.)

If the function isn't deployed, or a send fails, the app just moves on
silently — the in-app notification already went out.

## 4. Live notification updates (optional but recommended)

The bell polls every 60 seconds regardless, but for instant updates,
confirm Realtime replication is on for the `notifications` table:
**Database → Replication** in the Supabase dashboard → the migration
already adds it to the `supabase_realtime` publication, so this is
usually a no-op — just worth a glance if the bell feels slow.

## 5. Try it end to end

1. As a QA analyst: open a sample in the queue, record results, set a
   final Pass/Fail, then **Send for approval** — pick a flagged
   approver's email and sign.
2. As that approver: the bell shows a red dot; **Approvals** in the nav
   shows the report. Open it, sign, and **Approve & release** (or **Send
   back** with a reason, which returns it to the analyst to fix).
3. Open the released report's PDF/preview — it now shows both
   signatures and a QR code in the footer.
4. Scan that QR (with the in-app scanner — the QR icon in the top bar —
   or any phone camera) to open `verify.html`, a public read-only summary
   of the report. No login needed, and the URL only ever reveals the one
   report whose exact code you have — it can't be used to browse others.

Note: camera access (both the in-app scanner and a phone's own camera app
scanning the printed QR) requires HTTPS. This is a non-issue on your
production/preview URLs; it just won't work if the app is ever opened over
plain `http://`.
