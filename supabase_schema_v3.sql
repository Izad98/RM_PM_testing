-- =====================================================================
-- HEMAS QA System — one account per email (defense in depth)
-- =====================================================================
-- auth.users already enforces unique emails on its own, and the client
-- now also catches Supabase's "silent success" response for a duplicate
-- sign-up (see the PR that added this file). This adds the same
-- guarantee directly on profiles.email, so a future insert path that
-- bypasses the normal signup trigger or the admin-users Edge Function
-- still can't produce two rows for the same address.
--
-- Safe to re-run, and safe on a project with existing data: because
-- auth.users is already unique on email and every profiles row's email
-- is populated from there, there should be nothing to conflict with.
-- =====================================================================

alter table public.profiles
  drop constraint if exists profiles_email_key;
alter table public.profiles
  add constraint profiles_email_key unique (email);
