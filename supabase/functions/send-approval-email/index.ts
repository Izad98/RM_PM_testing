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
//   supabase secrets set BREVO_API_KEY=xkeysib-xxx
//   supabase secrets set BREVO_FROM_EMAIL=you@example.com
//   supabase secrets set BREVO_FROM_NAME="HEMAS QA"
// (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided automatically by
// the Edge Functions runtime — do not set them yourself.)
//
// Uses Brevo (https://brevo.com) instead of a provider that requires a
// verified sending *domain*: Brevo's free plan (300 emails/day, no card)
// only needs a single verified sender *email address* — click the
// confirmation link Brevo emails you at Settings → Senders, no DNS or
// domain purchase required — and you can then send to any recipient.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const BREVO_API_KEY = Deno.env.get("BREVO_API_KEY");
const BREVO_FROM_EMAIL = Deno.env.get("BREVO_FROM_EMAIL") || "";
const BREVO_FROM_NAME = Deno.env.get("BREVO_FROM_NAME") || "HEMAS QA";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

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
  if (!BREVO_API_KEY) {
    return { ok: false, error: "BREVO_API_KEY is not configured on this project." };
  }
  if (!BREVO_FROM_EMAIL) {
    return { ok: false, error: "BREVO_FROM_EMAIL is not configured on this project." };
  }
  const res = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: {
      "api-key": BREVO_API_KEY,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      sender: { email: BREVO_FROM_EMAIL, name: BREVO_FROM_NAME },
      to: [{ email: to }],
      subject,
      htmlContent: html,
    }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    return { ok: false, error: `Brevo responded ${res.status}: ${text}` };
  }
  return { ok: true };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
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

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
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
