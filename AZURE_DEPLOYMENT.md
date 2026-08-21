# RM & PM Releasing Portal — Azure Hosting Handover

**Prepared for:** IT team hand-over — hosting on Azure App Service (Web App) under a company domain
**Application:** RM & PM Releasing Portal (Hemas Consumer Brands) — a raw & packing material QA testing, manager-approval, e-signature and QR-verification portal.
**Repository:** `izad98/rm_pm_testing` on GitHub

This document explains what the application is built from, exactly how to
put it on Azure, and what decisions/actions are still needed from IT. It
assumes no prior context — everything relevant that could be learned from
the codebase is written down here.

---

## 1. What this application is

A single internal web portal used by three roles (Procurement, QA, Admin):

1. **Procurement** logs a raw/packing material sample and hands it to QA.
2. **QA** records lab test results against it, then either releases it
   directly or sends it to a flagged manager for **approval**.
3. A **manager** reviews, signs on-screen, and approves & releases (or
   sends it back with a reason).
4. Every released report gets an **e-signature** trail (analyst +
   approver) and a **QR code**. Scanning it opens a public, read-only
   verification page (`verify.html`) showing exactly what was signed off
   — no login required, and only the one report whose exact code you
   have is ever revealed (no browsing/enumeration).

There is no separate "backend service" written for this app. It is a
static front end that talks directly to a hosted **Supabase** project
(Postgres database + Auth + Row Level Security + Edge Functions +
Realtime) from the browser. Azure's job is only to serve the static
files — the actual application logic and data live in Supabase, which is
a separate cloud service from Azure. This is the single most important
fact for IT to understand before hosting this: **moving the front end to
Azure does not move the database. See §5 for what that means.**

---

## 2. Architecture at a glance

```
                     ┌──────────────────────────────┐
  Browser  ───────▶  │  Azure App Service (Web App)  │   static files only:
 (any user)          │  index.html · verify.html ·   │   index.html, verify.html,
                     │  favicons, logos               │   images, no server code
                     └──────────────┬────────────────┘   of its own
                                    │  all app logic runs
                                    │  client-side, then calls out to:
                                    ▼
        ┌───────────────────────────────────────────────────┐
        │                    Supabase project                │
        │  ┌───────────┐ ┌────────┐ ┌───────────┐ ┌───────┐  │
        │  │ Postgres   │ │  Auth  │ │  Storage   │ │Realtime│ │
        │  │ (RLS-      │ │(email/ │ │(sample     │ │(notif- │ │
        │  │  protected)│ │password)│ │ photos)    │ │ications)│ │
        │  └───────────┘ └────────┘ └───────────┘ └───────┘  │
        │  ┌───────────────────────────────────────────────┐ │
        │  │ Edge Functions (Deno, service-role privileged) │ │
        │  │  admin-users · send-approval-email             │ │
        │  └───────────────────────┬─────────────────────────┘│
        └────────────────────────────┼───────────────────────┘
                                      │  optional, outbound only
                                      ▼
                              ┌──────────────┐
                              │  Brevo (SMTP  │   transactional email —
                              │  email API)   │   approval notifications
                              └──────────────┘
```

Plus a handful of third-party JavaScript libraries loaded straight from
public CDNs into the browser at runtime (no local copies, no build step
— see §3). There is **no build process at all**: `index.html` and
`verify.html` are the literal files served, unmodified.

---

## 3. Full technology & services inventory

| Layer | Technology / service | Notes |
|---|---|---|
| Front end | Hand-written HTML5, CSS3, vanilla JavaScript | No framework (no React/Vue/etc.), no bundler, no build step. Two pages: `index.html` (the portal) and `verify.html` (public QR verification page). |
| Fonts | Google Fonts — IBM Plex Mono, IBM Plex Sans, Playfair Display | Loaded from `fonts.googleapis.com` / `fonts.gstatic.com`. Requires outbound internet access from the visitor's browser (not from Azure). |
| Supabase client SDK | `@supabase/supabase-js` v2 | Loaded from the jsDelivr CDN (`cdn.jsdelivr.net`). |
| PDF generation | `html2pdf.js` 0.10.1 | Loaded from cdnjs. Renders the on-screen report to a downloadable PDF **entirely client-side** — nothing is generated server-side. |
| QR code generation | `qrcodejs` 1.0.0 | Loaded from cdnjs. Draws the verification QR code on a released report. |
| QR code scanning | `jsQR` 1.4.0 | Tried from three CDN mirrors in order (jsDelivr → unpkg → cdnjs) so one blocked host doesn't disable the in-app camera scanner. |
| Backend / database | **Supabase** (Postgres, hosted, third-party — not Azure) | See §5. Holds all application data: users, samples, test results, notifications. |
| Auth | Supabase Auth | Email + password. Handles sign-up, sign-in, forced password change for admin-created accounts, and self-service "forgot password" email links. |
| Authorization | Postgres Row Level Security (RLS) | Enforced in the database itself, not just in the UI — see the `supabase_schema_*.sql` files. |
| File storage | Supabase Storage, bucket `sample-photos` | Holds the optional inspection photo attached to a sample. **Not created by any SQL file — see §5 and §7.** Signatures, by contrast, are stored as inline base64 PNG text directly in the database, not in Storage. |
| Realtime | Supabase Realtime | Powers instant in-app notification updates (bell icon); falls back to 60-second polling regardless. |
| Serverless functions | Supabase Edge Functions (Deno runtime) — `admin-users`, `send-approval-email` | Run with the Supabase **service role** key (never exposed to the browser) to do things RLS alone can't safely allow from the client: creating/deleting user accounts directly, and sending approval emails. |
| Outbound email (optional) | [Brevo](https://brevo.com) transactional email API | Only used by the `send-approval-email` function. The app fully works without it — the in-app notification bell is the source of truth regardless. |
| Hosting target | **Azure App Service (Web App)** | This package. See §4. |
| Source control / CI | GitHub (`izad98/rm_pm_testing`), GitHub Actions | A CodeQL security-scanning workflow already runs on every push/PR (`.github/workflows/codeql.yml`). This package adds an optional Azure deploy workflow (§4.3). |

**No npm/build dependencies exist for the site itself.** The `package.json`
added in this package exists solely to give Azure's Linux/Node App
Service plan something to run (a static file server) — it is
infrastructure, not application code.

---

## 4. Deploying the front end to Azure App Service

### 4.1 What's in this package

Everything at the root of the repository is the deployable unit — there
is no separate "build output" folder to look for:

```
index.html, verify.html            the two pages that make up the site
favicon.ico, favicon-16.png,
favicon-32.png, apple-touch-icon.png,
"hcb logo.png", "hcb logo dark.png" static assets referenced by the pages

package.json, server.js             ← added: static server for a Linux/Node plan
web.config                          ← added: static hosting config for a Windows/IIS plan
.github/workflows/azure-webapp-deploy.yml   ← added: optional CI deploy

supabase_schema_v0_base_RECONSTRUCTED.sql   ← added: see §5/§9 — reconstructed, verify before use
supabase_schema_v1.sql              profiles approval workflow (restored — see §9)
supabase_schema_v2.sql              approvals/e-signatures/QR/notifications (restored — see §9)
supabase_schema_v3.sql              unique constraint on profiles.email (restored — see §9)
supabase_schema_v4.sql              forced password change on admin-created accounts
supabase_schema_v5.sql              R&D role, stability testing gate, handover/receiver tracking
supabase/functions/admin-users/            Edge Function source
supabase/functions/send-approval-email/    Edge Function source
SETUP.md                            walkthrough for the approval/e-signature/QR feature set
SETUP_STABILITY.md                  walkthrough for the R&D/stability testing feature set
AZURE_DEPLOYMENT.md                 this document
```

You only need **one** of `package.json`+`server.js` **or** `web.config`,
depending which OS you pick for the App Service plan (§4.2) — the unused
one is simply ignored by the other stack, so it's safe to leave both in
place.

### 4.2 Create the Web App

In the Azure Portal:

1. **Create a resource → Web App.**
2. **Resource Group:** create new or use an existing company one.
3. **Name:** this becomes `https://<name>.azurewebsites.net` before a
   custom domain is attached (§4.4).
4. **Publish:** Code.
5. **Runtime stack:**
   - **Node 20 LTS** (recommended) if you want the simplest, most
     standard path — uses `package.json`/`server.js` from this package.
   - Or **.NET / any Windows stack** if you'd rather run this on IIS with
     zero runtime at all — uses `web.config` instead. Either works; pick
     whichever your team is more comfortable operating day-to-day.
6. **Region:** nearest to your users.
7. **Pricing plan:** at minimum a **Basic (B1)** tier — Free/Shared tiers
   don't support custom domains or SSL bindings, both of which you need
   (§4.4).
8. Create the resource.

### 4.3 Deploy the code

Two supported options — pick one:

**Option A — GitHub Actions (recommended for ongoing maintenance).**
This package already includes
`.github/workflows/azure-webapp-deploy.yml`. To wire it up:
1. In the Azure Portal, open the Web App → **Overview → Get publish
   profile** (downloads an XML file).
2. In GitHub: repo → **Settings → Secrets and variables → Actions → New
   repository secret**, name it `AZURE_WEBAPP_PUBLISH_PROFILE`, paste the
   XML content.
3. Edit the workflow file and replace `CHANGE-ME-azure-webapp-name` with
   the real Web App name from step 4.2.
4. Run it from the **Actions** tab (`Deploy to Azure Web App` →
   **Run workflow**). It's manual-trigger-only by default so it can't
   fail on a push before secrets exist — uncomment the `push` trigger at
   the top of the file once you're ready for deploys on every merge.

**Option B — One-off manual deploy (fastest for a first look).**
Azure Portal → Web App → **Deployment Center** → **Local Git** or **ZIP
Deploy**, and upload a zip of the repository root (or use
`az webapp deploy --src-path <zip> --type zip` from the Azure CLI).

Either way, once deployed, `https://<name>.azurewebsites.net` should load
the sign-in screen.

### 4.4 Connect the company domain + SSL

1. **Azure Portal → Web App → Custom domains → Add custom domain.**
2. Enter the desired hostname (e.g. `qa.yourcompany.com` — replace with
   the real subdomain/domain IT wants to use; nothing in this repo
   assumes a specific one).
3. Azure shows the DNS records to add at your domain registrar/DNS host:
   typically a **CNAME** record pointing the subdomain at
   `<name>.azurewebsites.net`, plus a short-lived **TXT** record to prove
   ownership. (Using the bare apex/root domain instead of a subdomain
   needs an **A** record plus the same TXT verification — Azure's wizard
   shows the exact values either way.)
4. Once DNS propagates, click **Validate**, then **Add**.
5. **Add TLS/SSL:** Custom domains → next to the new domain → **Add
   binding** → **App Service Managed Certificate** (free, auto-renewing,
   no certificate purchase or manual renewal needed) → **Create** →
   bind it as **SNI SSL**.
6. **Web App → TLS/SSL settings → HTTPS Only → On.** Camera access (the
   in-app QR scanner and a phone scanning the printed QR) only works over
   HTTPS, so this isn't optional.

---

## 5. The backend: Supabase — a decision is needed first

The app is currently wired to one specific, already-running Supabase
project (its URL and public **anon** key are hard-coded into `index.html`
and `verify.html` — see §8; this is normal and safe for Supabase's anon
key, not a leak — see §10). Hosting the front end on Azure does **not**
move this database anywhere; Supabase remains a separate service that
must be reachable from the browser regardless of where the HTML is
served from.

**Before deploying, decide which of these two paths IT wants:**

| | Keep the existing Supabase project | Migrate to a new, company-owned Supabase project |
|---|---|---|
| Effort | Low — no database work needed | Higher — full re-setup, see below |
| What's needed | Get ownership/admin access to the existing project transferred to a company-controlled account (it currently appears to be tied to the original developer's personal account); update **Auth → URL Configuration** (§7.4) to the new company domain | Create the project, run all schema files in order, deploy both Edge Functions, recreate the `sample-photos` Storage bucket, migrate existing data, then repoint `index.html`/`verify.html` at the new project's URL/key |
| Best for | Getting to production fastest, then transferring ownership as a fast-follow | Full control from day one under company billing/compliance from the start |

Either way, **§7 below is the full list of what the database side needs**,
written so it applies to a fresh project; skip whichever steps are
already done if keeping the existing one.

---

## 6. Configuration values / secrets inventory

| Value | Where it lives | Notes |
|---|---|---|
| Supabase project URL + anon key | Hard-coded near the top of `index.html`'s `<script>` (`BUILTIN_URL`/`BUILTIN_KEY`) and again in `verify.html` | Update both files (search for `BUILTIN_URL`) if migrating to a new Supabase project. Safe to have in client-side code by design — see §10. |
| Supabase **service role** key | Never in this repo. Lives only in the Supabase project's Edge Function environment (set automatically by Supabase, not by you) | Must never be pasted into `index.html`, `verify.html`, or any file that ships to the browser. |
| `BREVO_API_KEY`, `BREVO_FROM_EMAIL`, `BREVO_FROM_NAME` | Supabase project secrets (`supabase secrets set ...`), not in this repo | Optional — only needed if turning on outbound approval emails. See `SETUP.md` §3. |
| `AZURE_WEBAPP_PUBLISH_PROFILE` | GitHub repo secret (Actions) | Only needed if using the GitHub Actions deploy option (§4.3). |

Nothing in this repository is a secret that needs rotating before
hand-over: the only credential embedded in the front-end code is
Supabase's public anon key, which is designed to be public (§10).

---

## 7. Setting up the database side

Run these in order. All the `.sql` files are idempotent (safe to
re-run), per their own headers.

1. **Only if starting from a brand-new, empty Supabase project:** run
   `supabase_schema_v0_base_RECONSTRUCTED.sql` first. **Read the warning
   block at the top of that file before running it** — it is a
   best-effort reconstruction of tables that were never committed to this
   repo, not a verified export. If keeping the existing project, skip
   this file entirely (the real tables already exist).
2. Run `supabase_schema_v1.sql`, then `supabase_schema_v2.sql`, then
   `supabase_schema_v3.sql`, then `supabase_schema_v4.sql`, then
   `supabase_schema_v5.sql`, in that exact order, in the Supabase
   project's SQL editor. (`SETUP.md` covers `v2` in more depth, including
   one manual check it can't do for you around a pre-existing status
   constraint. `SETUP_STABILITY.md` covers `v5` — the R&D role, the
   stability-testing gate, and handover/receiver tracking.)
3. **Create the Storage bucket:** Supabase Studio → **Storage → New
   bucket** → name it exactly `sample-photos` → make it **public**. No
   SQL file creates this bucket or its access policy — it was set up by
   hand on the original project and needs to be redone by hand on a new
   one. Sample photo uploads will fail with a "bucket not found" error
   until this exists. (The second bucket, `stability-documents` for
   stability-testing certificates, does *not* need this manual step —
   `supabase_schema_v5.sql` creates it and its access policy directly in
   SQL, so it exists as soon as that file has been run.)
4. **Deploy the Edge Functions** (needs the [Supabase
   CLI](https://supabase.com/docs/guides/cli)):
   ```
   supabase functions deploy admin-users
   supabase functions deploy send-approval-email
   ```
   `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are
   injected automatically by the Edge Functions runtime — do not set them
   yourself. If deploying via the dashboard UI instead of the CLI, the
   function must be named exactly `admin-users` / `send-approval-email`
   (the dashboard suggests a random name by default) — the app calls them
   by that exact name.
5. **(Optional) Turn on approval emails** — see `SETUP.md` §3 for the
   full Brevo walkthrough.
6. **Critical, easy to miss — update Auth URLs for the new domain.**
   Supabase Studio → **Authentication → URL Configuration**:
   - **Site URL** → the production URL (e.g. `https://qa.yourcompany.com`).
   - **Redirect URLs** → add that same URL (and the `azurewebsites.net`
     one too, if you want it to keep working as a fallback).
   Skipping this step means "forgot password" and account-confirmation
   email links will send users to the wrong place after go-live.
7. **Create the first admin account.** Self sign-up only ever produces
   `procurement` or `qa` accounts pending approval — nobody can approve
   the very first one from inside the app. Use the Supabase CLI/dashboard
   to invoke the `admin-users` function once by hand (or insert directly
   with the service role key) to create the first `admin` user, who can
   then manage everyone else from the Users page.

---

## 8. Known gaps in this handover (read before treating anything as ground truth)

Being direct about these rather than papering over them:

- **The original base-table schema (`CREATE TABLE profiles`,
  `CREATE TABLE samples`) was never committed to this repository at any
  point in its history** — only incremental `ALTER TABLE` migrations
  were. `supabase_schema_v0_base_RECONSTRUCTED.sql` (added in this
  package) is a careful reconstruction from those migrations and from
  the app's own code, **not a verified copy**. If keeping the existing
  Supabase project, this doesn't matter (the real tables are already
  there). If standing up a new project, either use that file as a
  reviewed starting point, or — better — run `supabase db dump` against
  the existing project first and use that instead (instructions inside
  the reconstructed file's header comment).
- **`samples` table Row Level Security policies are likewise not in any
  committed file** and are the security boundary that actually stops,
  say, a Procurement account from editing test results. The reconstructed
  file includes a best-effort policy set inferred from the app's UI
  permission logic, clearly marked, but it has not been checked against
  the real ones. Treat it as a draft for review, not a deployment-ready
  security control.
- **How `sample_code` (the human-facing report code, e.g. an
  `RM-2025-####`-style value) is generated is not in any committed file
  either.** The app never sends a value for it on insert, so the live
  database generates it automatically (a default or trigger) — that
  logic needs to be recovered from the live project before a fresh
  project's sample intake form will work.
- This repo has **no evidence of prior hosting configuration** (no
  `CNAME`, `netlify.toml`, `vercel.json`, etc.) — treat this as a
  first-time production deployment rather than a migration from a known
  working host.

---

## 9. Security notes for IT

- The Supabase key embedded in `index.html`/`verify.html` is the
  **anon/publishable** key, which Supabase is explicitly designed to have
  exposed in client-side code — it grants no access on its own beyond
  what Row Level Security (§7, §8) allows for an unauthenticated or
  signed-in user. This is expected and is not a leak. The separate
  **service role** key (full database access, bypasses RLS) never
  appears anywhere in this repository and must stay that way.
- Both Edge Functions independently verify the caller is a signed-in,
  active admin (for `admin-users`) or signed-in user (for
  `send-approval-email`) before doing anything privileged — they don't
  rely on the front end to have already checked.
- Approval-workflow fields on `samples` (who approved what, signatures,
  release status) are locked behind a database trigger
  (`supabase_schema_v2.sql`) so they can only change through the
  `request_approval()`/`decide_approval()` functions — a direct table
  `update()` from the browser can't forge them, even with a valid
  session.
- The repository already runs GitHub's CodeQL static analysis on every
  push/PR (`.github/workflows/codeql.yml`) — no action needed, just worth
  knowing it's there.
- Camera access for QR scanning requires HTTPS in the browser, which is
  why §4.4 treats HTTPS as mandatory rather than optional.
- **Ownership note:** the live Supabase project this app currently points
  to appears to be under the original developer's personal account
  rather than a company-owned one. Whichever path is chosen in §5,
  billing/ownership should be transferred to a company-controlled account
  before this becomes the production system of record.

---

## 10. Questions during hand-over

This package and document were generated from the repository's code and
git history as of **2026-08-21**. For anything not answered here —
in particular, the exact live Supabase project's real schema/RLS/
`sample_code` generator (§8) — the fastest path is a `supabase db dump`
against the live project (one command, described inline in
`supabase_schema_v0_base_RECONSTRUCTED.sql`), or a short handover call
with whoever holds access to that Supabase project today.
