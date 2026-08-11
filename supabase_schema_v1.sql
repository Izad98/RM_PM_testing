-- =====================================================================
-- HEMAS QA System — self-service sign-up + admin approval
-- =====================================================================
-- What this does:
--   1. Adds an approval workflow to public.profiles (status: pending /
--      approved / rejected, plus who approved it and when).
--   2. Adds a trigger on auth.users so that anyone who signs up through
--      the portal's "Create account" form automatically gets a PENDING
--      profile row — never active, never anything other than
--      'procurement' or 'qa', no matter what the client sends.
--   3. Adds row-level security so a user can only ever see/edit their
--      own profile, and only an active admin can see or manage everyone
--      else's (approve, decline, change role, switch access on/off).
--
-- Safe to re-run: every statement is idempotent (IF NOT EXISTS / OR
-- REPLACE / DROP ... IF EXISTS before CREATE), so paste this whole file
-- into the Supabase SQL editor even on a project that already has data.
--
-- Run this before supabase_schema_v2.sql or v3.sql, and before deploying
-- supabase/functions/admin-users — that function's "create" action
-- upserts onto the pending profiles row this file's trigger creates, so
-- it depends on both existing first.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Columns: approval workflow on profiles
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists status text,
  add column if not exists approved_by uuid references public.profiles(id) on delete set null,
  add column if not exists approved_at timestamptz;

-- Backfill existing rows: anyone already active keeps working; anyone
-- already switched off is treated as pending review rather than
-- silently rejected, so an admin sees them in the approval queue once.
update public.profiles
set status = case when is_active then 'approved' else 'pending' end
where status is null;

alter table public.profiles
  alter column status set not null,
  alter column status set default 'pending';

alter table public.profiles
  drop constraint if exists profiles_status_check;
alter table public.profiles
  add constraint profiles_status_check check (status in ('pending','approved','rejected'));

-- New self-signups must never start active until an admin approves them.
alter table public.profiles
  alter column is_active set default false;

-- ---------------------------------------------------------------------
-- 2. Trigger: auto-create a pending profile for every new auth user
-- ---------------------------------------------------------------------
-- Only 'procurement' and 'qa' can ever come from the public sign-up
-- form's metadata — anything else (including 'admin') is downgraded to
-- 'procurement'. Admin accounts are created directly by an existing
-- admin (see the note at the top of this file), never through self
-- sign-up.
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
      when new.raw_user_meta_data->>'role' in ('procurement','qa')
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

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 3. Row level security
-- ---------------------------------------------------------------------
-- Helper run as the table owner (bypasses RLS internally) so policies
-- below can check "is the caller an active admin?" without recursing
-- into the very policy that calls it.
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and is_active = true
  );
$$;

alter table public.profiles enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select
  using (id = auth.uid() or public.is_admin());

-- Only admins change role / is_active / status / approval fields.
-- (Client inserts are blocked entirely — new rows only ever come from
-- the trigger above or the service-role admin-users function.)
drop policy if exists profiles_update_admin on public.profiles;
create policy profiles_update_admin on public.profiles
  for update
  using (public.is_admin())
  with check (public.is_admin());
