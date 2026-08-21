# Setting up: R&D stability testing, handover & receiver tracking

> **Prerequisite:** this assumes `supabase_schema_v1.sql` through
> `supabase_schema_v4.sql` have already been run — see `SETUP.md` for
> those. This file's migration (`supabase_schema_v5.sql`) extends the
> approval-workflow guard trigger and `request_approval()` that
> `supabase_schema_v2.sql` created, and adds a fourth column onto the
> `profiles.role` set v1 established.

This adds three things to the portal:

1. **A fourth role, R&D** — for stability testing. R&D can pick up a
   sample QA has flagged, record a result (done in-house or by a
   third-party lab, with an optional certificate/report attached), but
   **can never approve or release a sample** — that boundary is enforced
   in the database itself (see "How this is enforced" below), not just
   hidden in the UI.
2. **A required stability gate** — if QA flags a sample as needing
   stability testing, it cannot be sent for manager approval until R&D
   records a **Pass**. A **Fail** (or no result yet) blocks it.
3. **Handover / receiver tracking, picked from registered users** — not
   free text — at both points a physical sample changes hands:
   - Procurement → QA at intake ("Handed over by" / "Received by (QA)")
   - QA → R&D when stability testing is requested ("Handed over to R&D
     by" / "Received by (R&D)")

Everything here is additive — existing samples, users and workflows keep
working. A sample nobody ever flags for stability testing behaves exactly
as it did before this migration.

## 1. Run the database migration

Open the Supabase SQL editor for this project and paste in the whole of
[`supabase_schema_v5.sql`](./supabase_schema_v5.sql), then run it. It's
idempotent, so it's safe to re-run.

This migration:
- Adds `'rnd'` to `profiles.role` (self sign-up can now also produce a
  pending R&D account, same trust level as procurement/QA — never active
  until an admin approves it).
- Adds a `profiles_select_active_colleagues` policy so any signed-in user
  can see active colleagues' names — needed to populate the new
  "handed over by" / "received by" dropdowns. (This makes the existing
  `profiles_select_approvers` policy from v2 redundant, but doesn't
  remove it — no need to edit an already-shipped file.)
- Adds the handover/receiver/stability columns to `samples`.
- Extends the v2 guard trigger so the new stability fields can only
  change through the two functions below — a direct client `update()`
  can't set any of them, even from a valid QA or R&D session.
- Adds `request_stability_test()` (QA → R&D) and
  `record_stability_result()` (R&D's outcome).
- Adds the stability gate inside `request_approval()` itself.
- Extends `get_report_by_code()` so a released report's stability result
  also shows up on the public verification page (`verify.html`), same as
  its existing test results/signatures.
- Creates the `stability-documents` Storage bucket (public, for
  certificate/report uploads) directly via SQL — unlike `sample-photos`
  (set up by hand on the original project, see `AZURE_DEPLOYMENT.md`),
  this one is reproducible on a fresh project with no manual dashboard
  step.

### How this is enforced (not just hidden in the UI)

- `request_stability_test()` only accepts a "handed over by" person whose
  role is `qa`/`admin`, and only a `qa`/`admin` caller can invoke it.
- `record_stability_result()` only accepts a "received by" person whose
  role is `rnd`/`admin`, and only a `rnd`/`admin` caller can invoke it.
- `request_approval()` — the only path that can move a sample towards
  release — raises an error if `requires_stability_test` is true and
  `stability_status` isn't `'Pass'`.
- `'rnd'` is never included in any approver-eligibility check, in either
  `request_approval()` or `decide_approval()` (from v2, untouched by this
  file). There is no function, direct table access, or UI path by which
  an R&D account can approve or release a sample.

## 2. Add R&D accounts

Same two ways as any other role:
- **Self sign-up**, then an admin approves it on the Users page (Role
  shows as "R&D").
- **Admin → Users → "Add a user directly"**, picking the R&D role —
  skips the approval queue, same as creating any other account type.

## 3. Try it end to end

1. As **Procurement**: log a new sample. Pick who's physically handing
   it over in the new "Handed over by" field (defaults to you, but pick
   a colleague if someone else is doing the actual handoff) — this is
   now required, same as material description/supplier/etc.
2. As **QA**: open the sample. Confirm or change "Received by (QA)" in
   the "Handed over by procurement" card. Record test results as usual.
3. If this material needs a stability study: in the new **Stability
   testing** card, pick who's handing it to R&D and click **Send to
   R&D**. Try clicking **Send for approval** now — it's blocked with a
   message that stability testing must pass first.
4. As **R&D**: open **Stability queue** in the nav — the sample is
   there. Open it, pick **Internal R&D** or **Third party** (enter the
   lab's name if third party), add notes, optionally attach a
   certificate/report file, confirm who at R&D handled it, and **Record
   pass** (or **Record fail**, with a reason in the notes).
5. Back as **QA**: **Send for approval** now succeeds once the result is
   a Pass. A Fail keeps it blocked — the analyst can address it and, if a
   later re-test genuinely needs another stability check, the flow can
   be re-run from step 3.
6. Once released, the printed/PDF report and the public QR verification
   page both show a "Stability Testing" section with the result.

## 4. Third-party labs

There's no separate login for a third-party lab — R&D enters the result
on the lab's behalf (same spirit as how the app already only ever needs
one login per internal person, never one per external party). Picking
**Third party** just requires the lab's name and lets R&D attach the
lab's certificate/report as a file alongside the notes.
