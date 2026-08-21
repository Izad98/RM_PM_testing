-- =====================================================================
-- HEMAS QA System — intake documents, sample photo, R&D contact
-- =====================================================================
-- What this does:
--   1. Adds three fields to the Procurement intake form:
--      - intake_documents: any number of supporting files (COA / TDS /
--        MSDS / etc), each just a name + Storage URL. Optional.
--      - intake_photo_path: a photo of the sample as handed over,
--        distinct from the QA-side inspection photo (photo_path) taken
--        later during testing. Optional.
--      - rnd_responsible_id / _text / _post: which R&D person Procurement
--        wants as the contact for this sample, if any — separate from,
--        and set earlier than, the stability_handover_by_id (QA's actual
--        routing to R&D) supabase_schema_v5.sql added. Optional.
--   2. Creates the intake-documents Storage bucket (public, Procurement/
--      Admin can upload) directly in SQL, same reproducible-on-a-fresh-
--      project approach v5 used for stability-documents.
--   3. Extends request_stability_test() (from v5) so that if Procurement
--      already named an R&D contact on the sample, the notification goes
--      to that person specifically instead of every active R&D account.
--
-- Prerequisite: supabase_schema_v1.sql through v5.sql already applied.
-- Safe to re-run: every statement is idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. samples: new intake-side columns
-- ---------------------------------------------------------------------
alter table public.samples
  add column if not exists intake_documents jsonb not null default '[]'::jsonb,
  add column if not exists intake_photo_path text,
  add column if not exists rnd_responsible_id uuid references public.profiles(id) on delete set null,
  add column if not exists rnd_responsible text,
  add column if not exists rnd_responsible_post text;

-- ---------------------------------------------------------------------
-- 2. Storage: intake documents/photo bucket
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('intake-documents', 'intake-documents', true)
on conflict (id) do nothing;

drop policy if exists intake_documents_read on storage.objects;
create policy intake_documents_read on storage.objects
  for select to public
  using (bucket_id = 'intake-documents');

drop policy if exists intake_documents_write on storage.objects;
create policy intake_documents_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'intake-documents'
    and exists (
      select 1 from public.profiles
      where id = auth.uid() and is_active = true and role in ('procurement','admin')
    )
  );

-- ---------------------------------------------------------------------
-- 3. request_stability_test(): notify the named R&D contact specifically
--    when Procurement set one at intake, else fall back to v5's original
--    behaviour (notify every active R&D account). Full CREATE OR REPLACE
--    of v5's function (same signature) -- everything else unchanged.
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

  -- New in v6: if Procurement already named an R&D contact for this
  -- sample at intake (and that account is still active R&D/admin),
  -- notify only them. Otherwise, same broadcast v5 always did.
  if v_sample.rnd_responsible_id is not null and exists (
    select 1 from public.profiles
    where id = v_sample.rnd_responsible_id and is_active = true and role in ('rnd','admin')
  ) then
    insert into public.notifications (user_id, sample_id, type, title, body)
    values (
      v_sample.rnd_responsible_id, p_sample_id, 'stability_request',
      coalesce(v_sample.sample_code, 'A sample') || ' needs stability testing',
      coalesce(v_handover.full_name, v_handover.email) || ' sent "' || coalesce(v_sample.material_description, '') || '" for stability testing.'
    );
  else
    for v_rnd in select id from public.profiles where role = 'rnd' and is_active = true loop
      insert into public.notifications (user_id, sample_id, type, title, body)
      values (
        v_rnd.id, p_sample_id, 'stability_request',
        coalesce(v_sample.sample_code, 'A sample') || ' needs stability testing',
        coalesce(v_handover.full_name, v_handover.email) || ' sent "' || coalesce(v_sample.material_description, '') || '" for stability testing.'
      );
    end loop;
  end if;

  return v_sample;
end;
$$;

revoke all on function public.request_stability_test(uuid,uuid) from public;
grant execute on function public.request_stability_test(uuid,uuid) to authenticated;
