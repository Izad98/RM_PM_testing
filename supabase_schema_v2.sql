-- =====================================================================
-- HEMAS QA System — manager approval workflow, e-signatures, QR reports
-- =====================================================================
-- What this does:
--   1. Adds a "can approve reports" flag to profiles, so an admin can
--      mark specific QA/Admin accounts as eligible approvers (managers).
--   2. Adds approval-workflow, signature and QR-verification columns to
--      samples, plus a status check constraint covering the new
--      'Pending Approval' stage.
--   3. Locks every one of those new columns (and the status transitions
--      into 'Pending Approval' / 'Released') behind two SECURITY DEFINER
--      functions — request_approval() and decide_approval() — so an
--      analyst can never write their own "approved by" fields and a
--      report can never self-release, even though the client only ever
--      holds the public anon key. A trigger enforces this at the table
--      level regardless of what RLS policy is in place on samples.
--   4. Adds an in-app notifications table (RLS: everyone only ever sees
--      their own).
--   5. Adds a get_report_by_code() function for the public QR
--      verification page (verify.html) — exact-code lookup only, no
--      listing, so the anon key can never enumerate other reports.
--
-- Safe to re-run: every statement is idempotent, so paste this whole
-- file into the Supabase SQL editor even on a project that already has
-- data (and already has supabase_schema.sql applied).
--
-- IMPORTANT — things this file cannot verify for you:
--   - If public.samples.status already has a CHECK constraint limiting
--     it to the old three values, this file's new constraint (added
--     under a new name, samples_status_check_v2) will fail to attach
--     unless you first drop the old one. Open Table Editor → samples →
--     find the constraint under "Constraints" and drop it, or run:
--       alter table public.samples drop constraint <its name>;
--     then re-run this file.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. profiles: who is allowed to be sent reports for approval
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists can_approve boolean not null default false;

-- Any signed-in user needs to see the *names* of eligible approvers to
-- pick one (the existing profiles_select policy only lets you see your
-- own row). Scoped tightly: only rows already flagged as approvers,
-- and only to logged-in users, never anon.
drop policy if exists profiles_select_approvers on public.profiles;
create policy profiles_select_approvers on public.profiles
  for select to authenticated
  using (can_approve = true and is_active = true);

-- ---------------------------------------------------------------------
-- 2. samples: approval workflow, signatures, QR verification code
-- ---------------------------------------------------------------------
alter table public.samples
  add column if not exists requested_approver_id uuid references public.profiles(id) on delete set null,
  add column if not exists requested_at timestamptz,
  add column if not exists analyst_signature text,
  add column if not exists approver_id uuid references public.profiles(id) on delete set null,
  add column if not exists approved_at timestamptz,
  add column if not exists approver_signature text,
  add column if not exists released_at timestamptz,
  add column if not exists rejected_reason text,
  add column if not exists verify_code text;

create unique index if not exists samples_verify_code_key on public.samples(verify_code) where verify_code is not null;

alter table public.samples
  drop constraint if exists samples_status_check_v2;
alter table public.samples
  add constraint samples_status_check_v2
  check (status in ('Awaiting QA','Under Test','Pending Approval','Released'));

-- ---------------------------------------------------------------------
-- 3. Guard trigger: approval-flow columns only ever change through the
--    two functions below (which set this flag for the duration of
--    their own UPDATE). A direct .update() from the client — even with
--    a role allowed by samples' own RLS — is rejected.
-- ---------------------------------------------------------------------
create or replace function public.guard_samples_approval_fields()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('hemas.allow_approval_write', true), '') = 'on' then
    return new;
  end if;

  if new.status is distinct from old.status and new.status in ('Pending Approval','Released') then
    raise exception 'Use the approval workflow (Send for approval / Approve / Reject) to change this report''s status.';
  end if;

  if new.requested_approver_id is distinct from old.requested_approver_id
     or new.requested_at is distinct from old.requested_at
     or new.analyst_signature is distinct from old.analyst_signature
     or new.approver_id is distinct from old.approver_id
     or new.approved_at is distinct from old.approved_at
     or new.approver_signature is distinct from old.approver_signature
     or new.released_at is distinct from old.released_at
     or new.verify_code is distinct from old.verify_code
     or new.rejected_reason is distinct from old.rejected_reason
  then
    raise exception 'These fields can only change through the approval workflow.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_guard_samples_approval on public.samples;
create trigger trg_guard_samples_approval
  before update on public.samples
  for each row execute function public.guard_samples_approval_fields();

-- ---------------------------------------------------------------------
-- 4. notifications
-- ---------------------------------------------------------------------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  sample_id uuid references public.samples(id) on delete cascade,
  type text not null check (type in ('approval_request','approved','rejected')),
  title text not null,
  body text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.notifications enable row level security;

drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- No insert/delete policy for clients on purpose: rows only ever come
-- from the SECURITY DEFINER functions below, which bypass RLS as the
-- function owner.

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications'
     )
  then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. request_approval() — analyst sends a tested sample to a manager
-- ---------------------------------------------------------------------
create or replace function public.request_approval(
  p_sample_id uuid,
  p_approver_email text,
  p_analyst_signature text,
  p_analyzed_by text,
  p_analyzed_by_post text
)
returns public.samples
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me public.profiles;
  v_approver public.profiles;
  v_sample public.samples;
begin
  select * into v_me from public.profiles where id = auth.uid();
  if v_me is null or v_me.is_active is not true or v_me.role not in ('qa','admin') then
    raise exception 'Not authorized to submit results for approval.';
  end if;

  select * into v_sample from public.samples where id = p_sample_id for update;
  if v_sample is null then
    raise exception 'Sample not found.';
  end if;
  if v_sample.status = 'Released' then
    raise exception 'This report has already been released.';
  end if;

  select * into v_approver from public.profiles
    where lower(email) = lower(trim(p_approver_email))
      and is_active = true
      and can_approve = true
      and role in ('qa','admin');
  if v_approver is null then
    raise exception 'No active approver is registered with that email. Ask an admin to flag your manager as an approver.';
  end if;
  if v_approver.id = v_me.id then
    raise exception 'You cannot send a report to yourself for approval.';
  end if;
  if p_analyst_signature is null or length(p_analyst_signature) < 100 then
    raise exception 'Sign the report before sending it for approval.';
  end if;

  perform set_config('hemas.allow_approval_write', 'on', true);

  update public.samples set
    status = 'Pending Approval',
    requested_approver_id = v_approver.id,
    requested_at = now(),
    analyst_signature = p_analyst_signature,
    analyzed_by = coalesce(nullif(trim(p_analyzed_by), ''), v_me.full_name),
    analyzed_by_post = coalesce(nullif(trim(p_analyzed_by_post), ''), v_me.designation),
    qa_user = v_me.id,
    approver_id = null,
    approved_at = null,
    approver_signature = null,
    approved_by = null,
    approved_by_post = null,
    rejected_reason = null
  where id = p_sample_id
  returning * into v_sample;

  insert into public.notifications (user_id, sample_id, type, title, body)
  values (
    v_approver.id, p_sample_id, 'approval_request',
    coalesce(v_sample.sample_code, 'A sample') || ' is waiting on your approval',
    coalesce(v_me.full_name, v_me.email) || ' sent you "' || coalesce(v_sample.material_description, '') || '" to review and release.'
  );

  return v_sample;
end;
$$;

revoke all on function public.request_approval(uuid,text,text,text,text) from public;
grant execute on function public.request_approval(uuid,text,text,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- 6. decide_approval() — manager approves & releases, or rejects
-- ---------------------------------------------------------------------
create or replace function public.decide_approval(
  p_sample_id uuid,
  p_decision text,          -- 'approved' | 'rejected'
  p_signature text,         -- required when approved
  p_reason text,            -- required when rejected
  p_approved_by text,
  p_approved_by_post text
)
returns public.samples
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me public.profiles;
  v_sample public.samples;
  v_analyst_id uuid;
begin
  if p_decision not in ('approved','rejected') then
    raise exception 'Invalid decision.';
  end if;

  select * into v_me from public.profiles where id = auth.uid();
  if v_me is null or v_me.is_active is not true then
    raise exception 'Not authorized.';
  end if;

  select * into v_sample from public.samples where id = p_sample_id for update;
  if v_sample is null then
    raise exception 'Sample not found.';
  end if;
  if v_sample.status <> 'Pending Approval' then
    raise exception 'This report is not currently waiting for approval.';
  end if;
  if v_sample.requested_approver_id is distinct from v_me.id and v_me.role <> 'admin' then
    raise exception 'This report was not sent to you for approval.';
  end if;
  if v_me.role <> 'admin' and v_me.can_approve is not true then
    raise exception 'Your approver access has been revoked. Ask an admin.';
  end if;

  v_analyst_id := v_sample.qa_user;
  perform set_config('hemas.allow_approval_write', 'on', true);

  if p_decision = 'approved' then
    if p_signature is null or length(p_signature) < 100 then
      raise exception 'Sign the report before approving it.';
    end if;

    update public.samples set
      status = 'Released',
      approver_id = v_me.id,
      approved_at = now(),
      released_at = now(),
      approver_signature = p_signature,
      approved_by = coalesce(nullif(trim(p_approved_by), ''), v_me.full_name),
      approved_by_post = coalesce(nullif(trim(p_approved_by_post), ''), v_me.designation),
      -- gen_random_uuid() is native to Postgres core (unlike gen_random_bytes(),
      -- which needs the pgcrypto extension — often installed outside the
      -- `public` schema on Supabase, where this SECURITY DEFINER function's
      -- search_path can't see it). Trimmed to 12 hex chars: same ~48 bits.
      verify_code = coalesce(v_sample.verify_code, substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
      rejected_reason = null
    where id = p_sample_id
    returning * into v_sample;

    if v_analyst_id is not null then
      insert into public.notifications (user_id, sample_id, type, title, body)
      values (
        v_analyst_id, p_sample_id, 'approved',
        coalesce(v_sample.sample_code, 'Report') || ' was approved and released',
        coalesce(v_me.full_name, v_me.email) || ' approved and released this report.'
      );
    end if;
  else
    if p_reason is null or length(trim(p_reason)) = 0 then
      raise exception 'Add a reason so the analyst knows what to fix.';
    end if;

    update public.samples set
      status = 'Under Test',
      requested_approver_id = null,
      requested_at = null,
      rejected_reason = trim(p_reason)
    where id = p_sample_id
    returning * into v_sample;

    if v_analyst_id is not null then
      insert into public.notifications (user_id, sample_id, type, title, body)
      values (
        v_analyst_id, p_sample_id, 'rejected',
        coalesce(v_sample.sample_code, 'Report') || ' was sent back for changes',
        coalesce(v_me.full_name, v_me.email) || ': ' || trim(p_reason)
      );
    end if;
  end if;

  return v_sample;
end;
$$;

revoke all on function public.decide_approval(uuid,text,text,text,text,text) from public;
grant execute on function public.decide_approval(uuid,text,text,text,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- 7. get_report_by_code() — public QR verification lookup
-- ---------------------------------------------------------------------
-- Exact-code match only, and only ever returns a row for a Released
-- sample. There is no listing/search variant of this function, so
-- holding the anon key alone never lets anyone enumerate other reports
-- — you have to already have the one code from the QR on that report.
create or replace function public.get_report_by_code(p_code text)
returns table (
  sample_code text, doc_ref text, material_type text, material_description text,
  supplier_name text, sample_size text, rnd_ref text, batch_no text,
  date_received date, date_tested date, used_for text,
  test_results jsonb, final_status text, comments text, photo_path text,
  analyzed_by text, analyzed_by_post text, analyst_signature text,
  approved_by text, approved_by_post text, approver_signature text,
  released_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select
    sample_code, doc_ref, material_type, material_description,
    supplier_name, sample_size, rnd_ref, batch_no,
    date_received, date_tested, used_for,
    test_results, final_status, comments, photo_path,
    analyzed_by, analyzed_by_post, analyst_signature,
    approved_by, approved_by_post, approver_signature,
    released_at
  from public.samples
  where verify_code = p_code and status = 'Released'
  limit 1;
$$;

revoke all on function public.get_report_by_code(text) from public;
grant execute on function public.get_report_by_code(text) to anon, authenticated;
