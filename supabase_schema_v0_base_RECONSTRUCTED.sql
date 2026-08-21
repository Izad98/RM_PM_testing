-- =====================================================================
-- HEMAS QA System — RECONSTRUCTED base schema (profiles + samples)
-- =====================================================================
-- WHAT THIS FILE IS, AND WHY IT EXISTS
--
-- supabase_schema_v1.sql, v2.sql, v3.sql and v4.sql in this repo are all
-- ALTER TABLE migrations — every one of them assumes public.profiles and
-- public.samples already exist. The original statements that CREATEd
-- those two tables in the first place were never committed to this repo
-- (they were almost certainly run once, by hand, in the Supabase SQL
-- editor or built with the Table Editor UI, when the project started).
--
-- This file is a BEST-EFFORT RECONSTRUCTION of that missing starting
-- point, written by working backwards from three sources that ARE
-- committed and verified:
--   1. Every column the v1/v2/v3/v4 migrations ALTER onto these tables
--      (which tells us what must already exist beside them).
--   2. The exact insert/select payloads the app (index.html) sends to
--      and reads from these tables.
--   3. The exact column list returned by public.get_report_by_code() in
--      supabase_schema_v2.sql, which is the most authoritative source
--      for the "core" samples columns.
--
-- IT IS NOT A VERIFIED EXPORT OF THE REAL DATABASE. Column types,
-- defaults, and especially the Row Level Security policies on
-- `samples` below are informed guesses, not certainties — there is no
-- committed source for the original `samples` RLS at all. Treat
-- everything below as a starting point, not ground truth.
--
-- >>> THE CORRECT, AUTHORITATIVE WAY TO GET THE REAL SCHEMA <<<
-- If the existing Supabase project is being kept (see AZURE_DEPLOYMENT.md
-- §5 "Decision: keep or migrate the Supabase project"), you do not need
-- this file at all — the live database already has the real thing.
-- To capture it accurately (e.g. before migrating to a new project, or
-- just to get a verified copy into version control), run, with the
-- Supabase CLI, against the real project:
--     supabase login
--     supabase link --project-ref <project-ref>
--     supabase db dump --schema public -f real_schema_dump.sql
-- That dump is byte-accurate. This file is not a substitute for it —
-- only use this file to stand up a throwaway/dev project quickly, or as
-- a reference while you reconcile against the real dump.
--
-- Run this file FIRST, before v1/v2/v3/v4, and ONLY on a brand-new,
-- empty Supabase project (a project that does not already have
-- profiles/samples). Idempotent (IF NOT EXISTS throughout) so re-running
-- it is harmless either way.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. profiles — one row per app user, keyed to auth.users
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null default '',
  designation text,
  role text not null default 'procurement'
    check (role in ('procurement','qa','admin')),
  is_active boolean not null default false,
  created_at timestamptz not null default now()
);
-- v1 adds: status, approved_by, approved_at (and tightens is_active's default)
-- v2 adds: can_approve
-- v3 adds: a unique constraint on email
-- v4 adds: must_change_password
-- Run those files, in order, right after this one.

alter table public.profiles enable row level security;

-- ---------------------------------------------------------------------
-- 2. samples — one row per material sample logged by Procurement
-- ---------------------------------------------------------------------
create table if not exists public.samples (
  id uuid primary key default gen_random_uuid(),

  -- Human-facing report code (e.g. shown on every printed/PDF report and
  -- used as the QR verification lookup key). ⚠ UNVERIFIED: the app reads
  -- this back immediately after insert without ever sending a value for
  -- it, which means the live project generates it automatically — most
  -- likely a DEFAULT expression or a BEFORE INSERT trigger producing
  -- something like "RM-2025-0001". That generator was never committed
  -- anywhere in this repo. Inspect Database → Functions/Triggers on the
  -- live project (or the `supabase db dump` above) to recover the real
  -- logic before relying on this column on a fresh project — as written
  -- below it will NOT auto-populate, and every insert will fail the
  -- NOT NULL below until you add that generator back.
  sample_code text not null unique,

  -- Set by Procurement at intake (see index.html's "Send to QA" form)
  doc_ref text default 'QA-STR-01',
  material_type text not null check (material_type in ('Raw Material','Packing Material')),
  material_description text not null,
  supplier_name text not null,
  rnd_ref text,
  sample_size text not null,
  batch_no text,
  date_received date not null default current_date,
  used_for text not null,
  intake_notes text,
  priority text not null default 'Normal' check (priority in ('Normal','Urgent')),
  submitted_by uuid references public.profiles(id) on delete set null,

  -- Set by QA while testing (see the report drawer in index.html)
  --
  -- Deliberately no CHECK constraint here: v2 adds one of its own
  -- (samples_status_check_v2, allowing 'Pending Approval' too) but never
  -- drops an earlier one first — by design, since on a *real* pre-
  -- existing project it can't know what that earlier constraint is
  -- named (see v2's own header comment). Adding one here anyway was
  -- tried and confirmed to break: on a project bootstrapped from this
  -- file, both constraints stay active and CHECK constraints AND
  -- together, so 'Pending Approval' satisfies v2's constraint but
  -- fails this file's narrower one — request_approval() fails outright
  -- the first time anything reaches that status. Let v2 be the only
  -- place that constrains this column.
  status text not null default 'Awaiting QA',
  qa_user uuid references public.profiles(id) on delete set null,
  date_tested date,
  test_results jsonb not null default '[]'::jsonb,
    -- array of { test, spec, method, result, status } objects —
    -- status here is per-row 'Pass'/'Fail', independent of final_status.
  final_status text check (final_status in ('PASS','FAIL','PENDING')),
  comments text,
  photo_path text,
    -- public URL of a file in the `sample-photos` Storage bucket — see
    -- AZURE_DEPLOYMENT.md §5 for why that bucket also isn't in any SQL
    -- file and must be created separately.
  analyzed_by text,
  analyzed_by_post text,

  approved_by text,
  approved_by_post text,

  created_at timestamptz not null default now()
);
-- v2 adds: requested_approver_id, requested_at, analyst_signature,
--          approver_id, approved_at, approver_signature, released_at,
--          rejected_reason, verify_code, plus the approval-workflow
--          guard trigger, request_approval()/decide_approval(), and
--          replaces the status check constraint above.

alter table public.samples enable row level security;

-- ---------------------------------------------------------------------
-- 3. samples RLS — ⚠ UNVERIFIED, best-effort only, see the warning below
-- ---------------------------------------------------------------------
-- No policy for `samples` exists in any committed file, yet the app
-- reads and writes this table directly with the public anon key, so
-- SOME policy has always governed it on the live project — its exact
-- shape was never captured. What follows is inferred purely from the
-- `can` permission map in index.html's client-side JS (create: role in
-- procurement/admin; test/record results: role in qa/admin; everyone
-- signed in and active can view). Client-side checks are a UX nicety,
-- not security — the database is the actual enforcement boundary, so
-- ⚠ DO NOT DEPLOY THIS TO ANYTHING REAL WITHOUT AN INDEPENDENT REVIEW.
-- If the existing project is being kept, replace this whole section
-- with its real policies from `supabase db dump` instead of trusting it.

drop policy if exists samples_select on public.samples;
create policy samples_select on public.samples
  for select to authenticated
  using (exists (
    select 1 from public.profiles
    where id = auth.uid() and is_active = true
  ));

drop policy if exists samples_insert on public.samples;
create policy samples_insert on public.samples
  for insert to authenticated
  with check (exists (
    select 1 from public.profiles
    where id = auth.uid() and is_active = true and role in ('procurement','admin')
  ));

-- Column-level restriction of the approval-flow fields is handled by
-- v2's guard trigger, not by this policy — this only gates who can
-- attempt an UPDATE on the row at all (QA recording results, or an
-- admin correcting something).
drop policy if exists samples_update on public.samples;
create policy samples_update on public.samples
  for update to authenticated
  using (exists (
    select 1 from public.profiles
    where id = auth.uid() and is_active = true and role in ('qa','admin')
  ))
  with check (exists (
    select 1 from public.profiles
    where id = auth.uid() and is_active = true and role in ('qa','admin')
  ));

drop policy if exists samples_delete on public.samples;
create policy samples_delete on public.samples
  for delete to authenticated
  using (exists (
    select 1 from public.profiles
    where id = auth.uid() and is_active = true and role = 'admin'
  ));
