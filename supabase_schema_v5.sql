-- =====================================================================
-- HEMAS QA System — R&D stability testing, handover/receiver tracking
-- =====================================================================
-- What this does:
--   1. Adds a fourth role, 'rnd', for R&D staff. R&D's only capability
--      is recording stability test results — it is deliberately never
--      added to any approver-eligibility check, so an R&D account can
--      never approve or release a QA sample, no matter what a client
--      request claims.
--   2. Adds "handed over by" / "received by" tracking, picked from
--      registered portal users (not free text), for both legs that
--      already move a physical sample between people:
--        - Procurement → QA at intake (handover_by_id / received_by_id)
--        - QA → R&D when stability testing is requested
--          (stability_handover_by_id / stability_received_by_id)
--   3. Adds stability-testing columns to samples and makes a passing
--      stability result a REQUIRED gate before a sample flagged as
--      needing it can be sent for approval/release — enforced in
--      request_approval() itself, not just in the UI.
--   4. R&D can record a stability result either as work done in-house or
--      on behalf of a third-party lab (the app never gives the lab its
--      own login — R&D enters the outcome and can attach the lab's
--      certificate/report as a file).
--   5. Locks every new workflow-transition field behind two new
--      SECURITY DEFINER functions, request_stability_test() and
--      record_stability_result(), using the same guard-trigger pattern
--      supabase_schema_v2.sql already established for the approval
--      workflow — a direct client update() can set none of them.
--
-- Prerequisite: supabase_schema_v1.sql through v4.sql already applied
-- (this file extends the guard trigger and request_approval() that v2
-- created, and the profiles/samples columns v1/v2/v4 added).
--
-- Safe to re-run: every statement is idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. profiles: add the 'rnd' role
-- ---------------------------------------------------------------------
alter table public.profiles
  drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_check check (role in ('procurement','qa','rnd','admin'));

-- Self sign-up may now also produce 'rnd' accounts, same trust level as
-- 'procurement'/'qa' (pending admin approval, never active by default).
-- 'admin' remains impossible to self sign-up as, unchanged from v1.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, designation, role, is_active, status)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    nullif(new.raw_user_meta_data->>'designation', ''),
    case
      when new.raw_user_meta_data->>'role' in ('procurement','qa','rnd')
        then new.raw_user_meta_data->>'role'
      else 'procurement'
    end,
    false,
    'pending'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Any signed-in user needs to see colleagues' names to populate the new
-- "handed over by" / "received by" pickers below (procurement picking a
-- colleague, QA picking a colleague, R&D picking a colleague) — the
-- existing profiles_select policy only ever allowed your own row (or, if
-- admin, everyone). Scoped to active accounts only, same spirit as the
-- existing profiles_select_approvers policy from v2 (which this makes
-- redundant but does not replace, to avoid editing an already-shipped
-- migration file).
drop policy if exists profiles_select_active_colleagues on public.profiles;
create policy profiles_select_active_colleagues on public.profiles
  for select to authenticated
  using (is_active = true);

-- ---------------------------------------------------------------------
-- 2. samples: handover/receiver tracking + stability testing
-- ---------------------------------------------------------------------
alter table public.samples
  -- Procurement → QA leg. submitted_by/qa_user already exist (v0/app
  -- code) but track "who has the session that clicked the button", which
  -- is not always the same person who physically handed over or
  -- received the sample — these are separate, explicitly-picked fields.
  add column if not exists handover_by_id uuid references public.profiles(id) on delete set null,
  add column if not exists handover_by text,
  add column if not exists handover_by_post text,
  add column if not exists received_by_id uuid references public.profiles(id) on delete set null,
  add column if not exists received_by text,
  add column if not exists received_by_post text,

  -- Stability testing (QA → R&D leg)
  add column if not exists requires_stability_test boolean not null default false,
  add column if not exists stability_status text not null default 'Not Required',
  add column if not exists stability_handover_by_id uuid references public.profiles(id) on delete set null,
  add column if not exists stability_handover_by text,
  add column if not exists stability_handover_by_post text,
  add column if not exists stability_received_by_id uuid references public.profiles(id) on delete set null,
  add column if not exists stability_received_by text,
  add column if not exists stability_received_by_post text,
  add column if not exists stability_performed_by text,
  add column if not exists stability_lab_name text,
  add column if not exists stability_notes text,
  add column if not exists stability_certificate_path text,
  add column if not exists stability_requested_at timestamptz,
  add column if not exists stability_result_set_at timestamptz;

alter table public.samples
  drop constraint if exists samples_stability_status_check;
alter table public.samples
  add constraint samples_stability_status_check
  check (stability_status in ('Not Required','Awaiting R&D','Pass','Fail'));

alter table public.samples
  drop constraint if exists samples_stability_performed_by_check;
alter table public.samples
  add constraint samples_stability_performed_by_check
  check (stability_performed_by is null or stability_performed_by in ('Internal R&D','Third Party'));

-- ---------------------------------------------------------------------
-- 3. Guard trigger: extend v2's trigger to also protect the new
--    stability fields. CREATE OR REPLACE on the same function name, so
--    the one trigger already attached in v2 (trg_guard_samples_approval)
--    picks up this new body with no need to re-create the trigger itself.
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

  if new.requires_stability_test is distinct from old.requires_stability_test
     or new.stability_status is distinct from old.stability_status
     or new.stability_handover_by_id is distinct from old.stability_handover_by_id
     or new.stability_handover_by is distinct from old.stability_handover_by
     or new.stability_handover_by_post is distinct from old.stability_handover_by_post
     or new.stability_received_by_id is distinct from old.stability_received_by_id
     or new.stability_received_by is distinct from old.stability_received_by
     or new.stability_received_by_post is distinct from old.stability_received_by_post
     or new.stability_performed_by is distinct from old.stability_performed_by
     or new.stability_lab_name is distinct from old.stability_lab_name
     or new.stability_notes is distinct from old.stability_notes
     or new.stability_certificate_path is distinct from old.stability_certificate_path
     or new.stability_requested_at is distinct from old.stability_requested_at
     or new.stability_result_set_at is distinct from old.stability_result_set_at
  then
    raise exception 'Stability testing fields can only change through the R&D workflow.';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. request_stability_test() — QA sends a sample to R&D
-- ---------------------------------------------------------------------
create or replace function public.request_stability_test(
  p_sample_id uuid,
  p_handover_by_id uuid
)
returns public.samples
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me public.profiles;
  v_handover public.profiles;
  v_sample public.samples;
  v_rnd record;
begin
  select * into v_me from public.profiles where id = auth.uid();
  if v_me is null or v_me.is_active is not true or v_me.role not in ('qa','admin') then
    raise exception 'Not authorized to send a sample to R&D.';
  end if;

  select * into v_sample from public.samples where id = p_sample_id for update;
  if v_sample is null then
    raise exception 'Sample not found.';
  end if;
  if v_sample.status = 'Released' then
    raise exception 'This report has already been released.';
  end if;
  if v_sample.stability_status = 'Awaiting R&D' then
    raise exception 'This sample has already been sent to R&D.';
  end if;

  select * into v_handover from public.profiles
    where id = coalesce(p_handover_by_id, v_me.id) and is_active = true and role in ('qa','admin');
  if v_handover is null then
    raise exception 'Pick who is handing this sample to R&D.';
  end if;

  perform set_config('hemas.allow_approval_write', 'on', true);

  update public.samples set
    requires_stability_test = true,
    stability_status = 'Awaiting R&D',
    stability_handover_by_id = v_handover.id,
    stability_handover_by = v_handover.full_name,
    stability_handover_by_post = v_handover.designation,
    stability_received_by_id = null,
    stability_received_by = null,
    stability_received_by_post = null,
    stability_performed_by = null,
    stability_lab_name = null,
    stability_notes = null,
    stability_certificate_path = null,
    stability_requested_at = now(),
    stability_result_set_at = null
  where id = p_sample_id
  returning * into v_sample;

  for v_rnd in select id from public.profiles where role = 'rnd' and is_active = true loop
    insert into public.notifications (user_id, sample_id, type, title, body)
    values (
      v_rnd.id, p_sample_id, 'stability_request',
      coalesce(v_sample.sample_code, 'A sample') || ' needs stability testing',
      coalesce(v_handover.full_name, v_handover.email) || ' sent "' || coalesce(v_sample.material_description, '') || '" for stability testing.'
    );
  end loop;

  return v_sample;
end;
$$;

revoke all on function public.request_stability_test(uuid,uuid) from public;
grant execute on function public.request_stability_test(uuid,uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. record_stability_result() — R&D records the outcome
-- ---------------------------------------------------------------------
create or replace function public.record_stability_result(
  p_sample_id uuid,
  p_performed_by text,      -- 'Internal R&D' | 'Third Party'
  p_lab_name text,          -- required when p_performed_by = 'Third Party'
  p_result text,            -- 'Pass' | 'Fail'
  p_notes text,
  p_certificate_path text,
  p_received_by_id uuid
)
returns public.samples
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me public.profiles;
  v_received public.profiles;
  v_sample public.samples;
begin
  if p_performed_by not in ('Internal R&D','Third Party') then
    raise exception 'Pick whether this was done internally or by a third party.';
  end if;
  if p_performed_by = 'Third Party' and coalesce(trim(p_lab_name), '') = '' then
    raise exception 'Enter the third-party lab''s name.';
  end if;
  if p_result not in ('Pass','Fail') then
    raise exception 'Record a pass or fail result.';
  end if;

  select * into v_me from public.profiles where id = auth.uid();
  if v_me is null or v_me.is_active is not true or v_me.role not in ('rnd','admin') then
    raise exception 'Not authorized to record a stability result.';
  end if;

  select * into v_sample from public.samples where id = p_sample_id for update;
  if v_sample is null then
    raise exception 'Sample not found.';
  end if;
  if v_sample.stability_status <> 'Awaiting R&D' then
    raise exception 'This sample is not currently awaiting a stability result.';
  end if;

  select * into v_received from public.profiles
    where id = coalesce(p_received_by_id, v_me.id) and is_active = true and role in ('rnd','admin');
  if v_received is null then
    raise exception 'Pick who at R&D handled this.';
  end if;

  perform set_config('hemas.allow_approval_write', 'on', true);

  update public.samples set
    stability_status = p_result,
    stability_performed_by = p_performed_by,
    stability_lab_name = case when p_performed_by = 'Third Party' then trim(p_lab_name) else null end,
    stability_notes = nullif(trim(coalesce(p_notes, '')), ''),
    stability_certificate_path = p_certificate_path,
    stability_received_by_id = v_received.id,
    stability_received_by = v_received.full_name,
    stability_received_by_post = v_received.designation,
    stability_result_set_at = now()
  where id = p_sample_id
  returning * into v_sample;

  if v_sample.qa_user is not null then
    insert into public.notifications (user_id, sample_id, type, title, body)
    values (
      v_sample.qa_user, p_sample_id, 'stability_result',
      coalesce(v_sample.sample_code, 'A sample') || ' — stability testing ' || lower(p_result) || 'ed',
      coalesce(v_received.full_name, v_received.email) || ' recorded a ' || p_result || ' stability result' ||
        (case when p_performed_by = 'Third Party' then ' (via ' || trim(p_lab_name) || ')' else '' end) || '.'
    );
  end if;

  return v_sample;
end;
$$;

revoke all on function public.record_stability_result(uuid,text,text,text,text,text,uuid) from public;
grant execute on function public.record_stability_result(uuid,text,text,text,text,text,uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6. notifications: widen the type check for the two new kinds above
-- ---------------------------------------------------------------------
alter table public.notifications
  drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in ('approval_request','approved','rejected','stability_request','stability_result'));

-- ---------------------------------------------------------------------
-- 7. request_approval(): add the stability gate. Full CREATE OR REPLACE
--    of v2's function (same signature) — everything below is unchanged
--    from v2 except the new IF block flagged inline.
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

  -- New in v5: a sample flagged as needing stability testing can't be
  -- sent for approval until R&D (or the third party, via R&D) has
  -- recorded a passing result. Enforced here, not just in the UI, so it
  -- holds even if request_approval() is ever called directly.
  if v_sample.requires_stability_test and v_sample.stability_status <> 'Pass' then
    raise exception 'Stability testing must pass before this report can be sent for approval (currently: %).', v_sample.stability_status;
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

-- Note: 'rnd' is deliberately never included in the role in ('qa','admin')
-- eligibility checks above, in request_stability_test()'s caller check,
-- nor anywhere in decide_approval() (supabase_schema_v2.sql, untouched by
-- this file) — an R&D account has no path, direct or through any
-- function, to approve or release a sample.

-- ---------------------------------------------------------------------
-- 8. get_report_by_code(): surface the stability result on the public
--    verification page too, same spirit as the existing test_results /
--    photo_path / signatures it already exposes for a Released report.
--    Adding columns to a RETURNS TABLE function changes its signature,
--    which CREATE OR REPLACE can't do in place -- drop it first.
--    Everything below is unchanged from v2 except the new columns.
-- ---------------------------------------------------------------------
drop function if exists public.get_report_by_code(text);
create or replace function public.get_report_by_code(p_code text)
returns table (
  sample_code text, doc_ref text, material_type text, material_description text,
  supplier_name text, sample_size text, rnd_ref text, batch_no text,
  date_received date, date_tested date, used_for text,
  test_results jsonb, final_status text, comments text, photo_path text,
  analyzed_by text, analyzed_by_post text, analyst_signature text,
  approved_by text, approved_by_post text, approver_signature text,
  released_at timestamptz,
  requires_stability_test boolean, stability_status text,
  stability_performed_by text, stability_lab_name text, stability_notes text,
  stability_certificate_path text, stability_received_by text, stability_result_set_at timestamptz
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
    released_at,
    requires_stability_test, stability_status,
    stability_performed_by, stability_lab_name, stability_notes,
    stability_certificate_path, stability_received_by, stability_result_set_at
  from public.samples
  where verify_code = p_code and status = 'Released'
  limit 1;
$$;

revoke all on function public.get_report_by_code(text) from public;
grant execute on function public.get_report_by_code(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. Storage: a dedicated bucket for stability certificates/reports.
--    Unlike sample-photos (created by hand on the original project —
--    see AZURE_DEPLOYMENT.md), this one is created here in SQL so it is
--    reproducible on a fresh project without a manual dashboard step.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('stability-documents', 'stability-documents', true)
on conflict (id) do nothing;

drop policy if exists stability_documents_read on storage.objects;
create policy stability_documents_read on storage.objects
  for select to public
  using (bucket_id = 'stability-documents');

drop policy if exists stability_documents_write on storage.objects;
create policy stability_documents_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'stability-documents'
    and exists (
      select 1 from public.profiles
      where id = auth.uid() and is_active = true and role in ('rnd','admin')
    )
  );
