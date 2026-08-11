-- =====================================================================
-- HEMAS QA System — force a password change for admin-created accounts
-- =====================================================================
-- What this does:
--   Adds profiles.must_change_password. When an admin creates an
--   account directly (Users page → "Add a user directly"), the
--   admin-users Edge Function sets this true, since the password on
--   that account is one the admin typed in, not something only the
--   user knows. The app checks this right after sign-in and blocks
--   access to everything else until a new password is set — see the
--   "Set a new password" screen in index.html.
--
-- Self-signups are unaffected: they set their own password at sign-up,
-- so this column defaults to false and the trigger from
-- supabase_schema_v1.sql never sets it any other way.
--
-- Safe to re-run, and safe on a project with existing data.
-- =====================================================================

alter table public.profiles
  add column if not exists must_change_password boolean not null default false;
