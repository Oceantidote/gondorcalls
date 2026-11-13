import { createClient } from 'npm:@supabase/supabase-js@2';

// Sends all site email through Resend (secret RESEND_API_KEY).
//   outbox  — no auth: sends whatever the database triggers queued in email_outbox. Harmless to call early.
//   invite  — admin only (JWT): creates a join invite and emails the link.
//   forgot  — public: emails a password-reset link if the address belongs to a member. Always answers "ok".
// Deployed with verify_jwt = false; "invite" checks the caller itself.
const FROM = 'Gondor Calls <hello@gondorcalls.com>';
const SITE = 'https://gondorcalls.com/';
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
function render(name: string | null, subject: string, body: string, link: string | null, cta = 'Open Gondor Calls') {
  const paras = body.split(/\n{2,}/).map(p => `<p style="margin:0 0 14px">${esc(p).replace(/\n/g, '<br>')}</p>`).join('');
  const html = `<!doctype html><html><body style="margin:0;background:#f4efe6;font-family:Georgia,serif;color:#2a231d">
<table width="100%" cellpadding="0" cellspacing="0" style="padding:24px 12px"><tr><td align="center">
<table width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#fffdf8;border:1px solid #e3d6bd;border-radius:10px">
<tr><td style="background:#1f1a16;border-radius:10px 10px 0 0;padding:16px 24px;color:#d4a64a;font-size:20px;letter-spacing:2px;font-weight:bold">⚔ GONDOR CALLS</td></tr>
<tr><td style="padding:24px;font-size:16px;line-height:1.5">
${name ? `<p style="margin:0 0 14px">Hail, ${esc(name)},</p>` : ''}${paras}
${link ? `<p style="margin:22px 0 6px"><a href="${esc(link)}" style="background:#d4a64a;color:#1a130b;text-decoration:none;padding:12px 20px;border-radius:8px;font-family:Arial,sans-serif;font-weight:bold;display:inline-block">${esc(cta)}</a></p>` : ''}
</td></tr>
<tr><td style="padding:14px 24px;border-top:1px solid #eee4d2;font-family:Arial,sans-serif;font-size:12px;color:#8a7d6a">
Gondor Calls is your Warhammer group's private site. You can turn notification emails off on your profile.</td></tr>
</table></td></tr></table></body></html>`;
  const text = `${name ? `Hail, ${name},\n\n` : ''}${body}${link ? `\n\n${cta}: ${link}` : ''}\n\n— Gondor Calls`;
  return { subject, html, text };
}

async function send(messages: { to: string; subject: string; html: string; text: string }[]) {
  if (!messages.length) return;
  const key = Deno.env.get('RESEND_API_KEY');
  if (!key) throw new Error('RESEND_API_KEY is not set');
  for (let i = 0; i < messages.length; i += 100) {
    const r = await fetch('https://api.resend.com/emails/batch', {
      method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(messages.slice(i, i + 100).map(m => ({ from: FROM, to: [m.to], subject: m.subject, html: m.html, text: m.text }))),
    });
    if (!r.ok) throw new Error(`Resend ${r.status}: ${(await r.text()).slice(0, 300)}`);
  }
}

async function flushOutbox() {
  const { data: rows } = await admin.from('email_outbox').select('*').is('sent_at', null).lt('attempts', 5).order('id').limit(20);
  let sent = 0, failed = 0;
  for (const row of rows || []) {
    try {
      const { data: targets, error } = await admin.rpc('email_targets', { p_ids: row.recipients, p_force: false });
      if (error) throw error;
      await send((targets || []).map((t: any) => ({ to: t.email, ...render(t.display_name, row.subject, row.body, row.link) })));
      await admin.from('email_outbox').update({ sent_at: new Date().toISOString(), attempts: row.attempts + 1, last_error: null }).eq('id', row.id);
      sent++;
    } catch (e) {
      await admin.from('email_outbox').update({ attempts: row.attempts + 1, last_error: String((e as Error).message || e).slice(0, 500) }).eq('id', row.id);
      failed++;
    }
  }
  return { sent, failed };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  let b: any = {};
  try { b = await req.json(); } catch { /* empty body is fine for outbox */ }

  try {
    if (!b.action || b.action === 'outbox') return json(await flushOutbox());

    if (b.action === 'invite') {
      const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer /, '');
      const { data: u } = await admin.auth.getUser(jwt);
      const { data: me } = u?.user ? await admin.from('profiles').select('id,display_name,is_admin').eq('id', u.user.id).maybeSingle() : { data: null };
      if (!me?.is_admin) return json({ error: 'Organiser only' }, 403);
      const email = String(b.email || '').trim().toLowerCase();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: 'Enter a valid email' }, 400);
      const name = String(b.display_name || '').trim().slice(0, 40) || null;
      const { data: inv, error } = await admin.from('invites').insert({ kind: 'join', display_name: name, created_by: me.id }).select('token').single();
      if (error) throw error;
      const link = `${SITE}#invite=${inv.token}`;
      await send([{ to: email, ...render(name, `${me.display_name} has invited you to Gondor Calls`,
        `${me.display_name} has invited you to Gondor Calls, the group's private site for Secret Santa, meetups, birthday presents and ventures.\n\nThe link below works once and lasts 14 days. Use it to pick your password.`,
        link, 'Join Gondor Calls') }]);
      return json({ ok: true, token: inv.token });
    }

    if (b.action === 'forgot') {
      const email = String(b.email || '').trim().toLowerCase();
      const { data: uid } = await admin.rpc('user_by_email', { p_email: email });
      if (uid) {
        const since = new Date(Date.now() - 3600_000).toISOString();
        const { count } = await admin.from('invites').select('token', { count: 'exact', head: true }).eq('kind', 'reset').eq('user_id', uid).gte('created_at', since);
        if ((count ?? 0) < 3) {
          const { data: inv, error } = await admin.from('invites').insert({ kind: 'reset', user_id: uid, expires_at: new Date(Date.now() + 2 * 3600_000).toISOString() }).select('token').single();
          if (error) throw error;
          const { data: t } = await admin.rpc('email_targets', { p_ids: [uid], p_force: true });
          await send([{ to: email, ...render(t?.[0]?.display_name ?? null, 'Reset your Gondor Calls password',
            'Someone (hopefully you) asked to reset your password. The link below works once and lasts 2 hours. If it wasn\'t you, ignore this email: nothing changes.',
            `${SITE}#reset=${inv.token}`, 'Choose a new password') }]);
        }
      }
      return json({ ok: true });
    }
    return json({ error: 'Unknown action' }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: 'Email could not be sent. Try again shortly.' }, 500);
  }
});
