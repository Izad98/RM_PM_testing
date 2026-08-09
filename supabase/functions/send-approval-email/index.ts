// supabase/functions/send-approval-email/index.ts
//
// Sends the email side of the approval workflow (the in-app notification
// row is always written by request_approval()/decide_approval() in
// supabase_schema_v2.sql regardless of whether this function is deployed
// or an email actually goes out — email here is a best-effort extra, not
// the only way a manager finds out).
//
// The client calls this right after request_approval() / decide_approval()
// succeeds:
//   supabase.functions.invoke('send-approval-email', {
//     body: { sample_id, type: 'approval_request'|'approved'|'rejected', app_url: location.origin }
//   })
//
// Deploy:
//   supabase functions deploy send-approval-email
//   supabase secrets set RESEND_API_KEY=re_xxx
//   supabase secrets set RESEND_FROM="HEMAS QA <qa@yourverifieddomain.com>"
// (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided automatically by
// the Edge Functions runtime — do not set them yourself.)
//
// Requires a Resend account with a verified sending domain (or use their
// onboarding@resend.dev sender for testing before your domain is
// verified). https://resend.com/domains

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const RESEND_API_KEY = Deno.env.get(re_ZNXFzWau_8FvH34mUGdZL4RBWCud6EsTy);
const RESEND_FROM = Deno.env.get("RESEND_FROM") || "HEMAS QA <onboarding@resend.dev>";
const SUPABASE_URL = Deno.env.get(https://zfpnstacxwieooayrnoo.supabase.co)!;
const SERVICE_ROLE_KEY = Deno.env.get(postgresql://postgres:[YOUR-PASSWORD]@db.zfpnstacxwieooayrnoo.supabase.co:5432/postgres)!;
const ANON_KEY = Deno.env.get(sb_publishable_EQjzahCsZx7Am0jggH-gYw_H6YHE3xd)!;

function safeAppUrl(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  try {
    const u = new URL(raw);
    if (u.protocol !== "https:" && u.protocol !== "http:") return null;
    return u.origin + "/";
  } catch {
    return null;
  }
}

async function sendEmail(to: string, subject: string, html: string) {
  if (!RESEND_API_KEY) {
    return { ok: false, error: "RESEND_API_KEY is not configured on this project." };
  }
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${re_ZNXFzWau_8FvH34mUGdZL4RBWCud6EsTy}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ from: RESEND_FROM, to: [to], subject, html }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    return { ok: false, error: `Resend responded ${res.status}: ${text}` };
  }
  return { ok: true };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const callerClient = createClient(https://zfpnstacxwieooayrnoo.supabase.co, sb_publishable_EQjzahCsZx7Am0jggH-gYw_H6YHE3xd, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await callerClient.auth.getUser();
    if (authErr || !user) {
      return new Response(JSON.stringify({ error: "Not signed in." }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json().catch(() => ({}));
    const sampleId = body?.sample_id as string | undefined;
    const type = body?.type as "approval_request" | "approved" | "rejected" | undefined;
    const appUrl = safeAppUrl(body?.app_url) || "";

    if (!sampleId || !["approval_request", "approved", "rejected"].includes(type || "")) {
      return new Response(JSON.stringify({ error: "sample_id and a valid type are required." }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const admin = createClient(https://zfpnstacxwieooayrnoo.supabase.co, postgresql://postgres:[YOUR-PASSWORD]@db.zfpnstacxwieooayrnoo.supabase.co:5432/postgres);
    const { data: sample, error: sErr } = await admin
      .from("samples")
      .select(`
        id, sample_code, material_description, status, rejected_reason,
        requested_approver:requested_approver_id(email, full_name),
        analyst:qa_user(email, full_name),
        approver:approver_id(full_name)
      `)
      .eq("id", sampleId)
      .single();

    if (sErr || !sample) {
      return new Response(JSON.stringify({ error: "Sample not found." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const code = sample.sample_code || "This sample";
    const desc = sample.material_description || "";

    let to: string | undefined;
    let subject = "";
    let html = "";

    if (type === "approval_request") {
      if (sample.status !== "Pending Approval") {
        return new Response(JSON.stringify({ error: "This report is not currently pending approval." }), {
          status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      to = sample.requested_approver?.email;
      subject = `Approval needed — ${code}`;
      html = `<p>Hi ${esc(sample.requested_approver?.full_name || "")},</p>
        <p><b>${esc(sample.analyst?.full_name || "A colleague")}</b> sent <b>${esc(code)}</b>
        (${esc(desc)}) for your review and release.</p>
        ${appUrl ? `<p><a href="${appUrl}">Open the QA portal</a> and go to Approvals.</p>` : ""}`;
    } else if (type === "approved") {
      to = sample.analyst?.email;
      subject = `${code} was approved and released`;
      html = `<p>Hi ${esc(sample.analyst?.full_name || "")},</p>
        <p><b>${esc(sample.approver?.full_name || "Your approver")}</b> approved and released
        <b>${esc(code)}</b> (${esc(desc)}).</p>
        ${appUrl ? `<p><a href="${appUrl}">Open the QA portal</a> to view the signed report.</p>` : ""}`;
    } else {
      to = sample.analyst?.email;
      subject = `${code} was sent back for changes`;
      html = `<p>Hi ${esc(sample.analyst?.full_name || "")},</p>
        <p><b>${code}</b> (${esc(desc)}) was sent back with this note:</p>
        <blockquote>${esc(sample.rejected_reason || "")}</blockquote>
        ${appUrl ? `<p><a href="${appUrl}">Open the QA portal</a> to update it and resend.</p>` : ""}`;
    }

    if (!to) {
      return new Response(JSON.stringify({ error: "No recipient email on file for this report." }), {
        status: 422, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const result = await sendEmail(to, subject, html);
    if (!result.ok) {
      return new Response(JSON.stringify({ error: result.error }), {
        status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e?.message || e) }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

function esc(s: string): string {
  return String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));
}
