// supabase/functions/admin-users/index.ts
//
// Backs the two admin-only actions on the Users page that a plain RLS
// policy can't do, because they need the service role: creating a user
// directly (with a password, bypassing the public sign-up + approval
// queue) and fully deleting one (auth user + profile, not just switching
// them off).
//
// The client calls this as:
//   supabase.functions.invoke('admin-users', {
//     body: { action: 'create', full_name, email, designation, role, password }
//   })
//   supabase.functions.invoke('admin-users', {
//     body: { action: 'delete', id }
//   })
//
// Every response is JSON. Expected/validation failures come back as a
// 200 with { error: "..." } — the client only reads `data.error`, not
// the non-2xx error path, so a real HTTP error status here would just
// show a generic "did not respond" message instead of the real reason.
// Only genuinely unexpected exceptions fall through to a 500.
//
// Deploy:
//   supabase functions deploy admin-users
// (SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are
// provided automatically by the Edge Functions runtime — do not set
// them yourself.)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Inlined rather than imported from ../_shared/cors.ts: the Supabase
// dashboard's function editor deploys only the one file you paste in, not
// the rest of supabase/functions/ — a cross-file import there fails with
// "Module not found ... _shared/cors.ts". Keeping this self-contained
// means it deploys the same way via the CLI or a dashboard paste.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

function ok(body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
function fail(status: number, error: string) {
  return new Response(JSON.stringify({ error }), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Who is calling, and are they an active admin? Checked against the
    // caller's own row under RLS (profiles_select already permits
    // id = auth.uid()) — no need for the service role for this part.
    const authHeader = req.headers.get("Authorization") || "";
    const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user: caller }, error: authErr } = await callerClient.auth.getUser();
    if (authErr || !caller) return fail(401, "Not signed in.");

    const { data: callerProfile, error: profErr } = await callerClient
      .from("profiles").select("role, is_active").eq("id", caller.id).single();
    if (profErr || !callerProfile || callerProfile.role !== "admin" || !callerProfile.is_active) {
      return fail(403, "Admin access required.");
    }

    const body = await req.json().catch(() => ({}));
    const action = body?.action as string | undefined;
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    if (action === "create") {
      const full_name = String(body?.full_name || "").trim();
      const email = String(body?.email || "").trim().toLowerCase();
      const designation = String(body?.designation || "").trim();
      const role = String(body?.role || "");
      const password = String(body?.password || "");

      if (!full_name || !email) return ok({ error: "Name and email are both needed." });
      if (!["procurement", "qa", "admin"].includes(role)) return ok({ error: "Pick a valid role." });
      if (password.length < 8) return ok({ error: "Use a password of at least 8 characters." });

      const { data: created, error: createErr } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
        user_metadata: { full_name, designation, role },
      });
      if (createErr || !created?.user) {
        const msg = createErr?.message || "Could not create the account.";
        return ok({ error: /already.*registered|already.*exists/i.test(msg)
          ? "An account with that email already exists."
          : msg });
      }

      // The handle_new_user() trigger already inserted a pending row for
      // this id the instant createUser() ran — overwrite it with what an
      // admin-created account actually is: approved and active, with the
      // role picked here (including 'admin', which self sign-up can never
      // set — the trigger downgrades anything outside procurement/qa).
      const { error: upsertErr } = await admin.from("profiles").upsert({
        id: created.user.id, email, full_name,
        designation: designation || null,
        role, is_active: true, status: "approved",
        approved_by: caller.id, approved_at: new Date().toISOString(),
        // The password above is one an admin typed in, not the user's own
        // choice — force them to replace it with something only they know
        // the first time they sign in.
        must_change_password: true,
      }, { onConflict: "id" });
      if (upsertErr) {
        // The auth user exists but the profile write failed — surface it
        // rather than leaving a silent half-created account.
        return ok({ error: `Account created but the profile could not be set up: ${upsertErr.message}` });
      }

      return ok({ ok: true, id: created.user.id });
    }

    if (action === "delete") {
      const id = String(body?.id || "");
      if (!id) return ok({ error: "No user id given." });
      if (id === caller.id) return ok({ error: "You cannot remove your own account." });

      const { error: delErr } = await admin.auth.admin.deleteUser(id);
      if (delErr) return ok({ error: delErr.message || "Could not remove the account." });

      // Belt-and-braces: only a no-op if a cascade already took care of it.
      await admin.from("profiles").delete().eq("id", id);

      return ok({ ok: true });
    }

    return ok({ error: "Unknown action." });
  } catch (e) {
    // Log the real error server-side (visible in the function's logs in
    // the Supabase dashboard) but never echo exception details — such as
    // a stack trace or an internal Postgres message — back to the caller.
    console.error("admin-users unexpected error:", e);
    return fail(500, "Something went wrong. Try again, or check the function logs.");
  }
});
