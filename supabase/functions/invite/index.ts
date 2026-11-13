import { createClient } from 'npm:@supabase/supabase-js@2';

// Redeems invite links (create account) and reset links (set new password).
// No email is sent: the organiser shares links privately.
// Deployed with verify_jwt = false (invitees have no session yet); the token is the credential.
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  let b: any;
  try { b = await req.json(); } catch { return json({ error: 'Bad request' }, 400); }
  const token = String(b.token || '');
  if (!/^[0-9a-f-]{36}$/i.test(token)) return json({ error: 'That link is not valid' }, 400);

  const { data: inv } = await admin.from('invites').select('*').eq('token', token).maybeSingle();
  if (!inv || inv.used_at || new Date(inv.expires_at) < new Date()) {
    return json({ error: 'This link has expired or already been used. Ask the organiser for a new one.' }, 400);
  }

  if (b.action === 'check') {
    let name = inv.display_name;
    if (inv.kind === 'reset') {
      const { data: p } = await admin.from('profiles').select('display_name').eq('id', inv.user_id).maybeSingle();
      name = p?.display_name;
    }
    return json({ kind: inv.kind, display_name: name });
  }

  const password = String(b.password || '');
  if (password.length < 8) return json({ error: 'Password must be at least 8 characters' }, 400);

  if (b.action === 'redeem' && inv.kind === 'join') {
    const email = String(b.email || '').trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: 'Enter a valid email' }, 400);
    const name = String(b.display_name || inv.display_name || '').trim().slice(0, 40);
    if (!name) return json({ error: 'Enter your name' }, 400);
    const { error: e1 } = await admin.from('invites').update({ claimed_email: email }).eq('token', token).is('used_at', null);
    if (e1) return json({ error: 'Could not use invite' }, 500);
    const { error } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { invite: token, display_name: name },
    });
    if (error) {
      const msg = /already/i.test(error.message) ? 'That email already has an account. Sign in instead.'
        : /duplicate|unique/i.test(error.message) ? 'That name is taken. Pick another.' : error.message;
      return json({ error: msg }, 400);
    }
    return json({ ok: true, email });
  }

  if (b.action === 'reset' && inv.kind === 'reset') {
    const { data: u, error } = await admin.auth.admin.updateUserById(inv.user_id, { password });
    if (error) return json({ error: error.message }, 400);
    await admin.from('invites').update({ used_at: new Date().toISOString() }).eq('token', token);
    return json({ ok: true, email: u.user?.email });
  }

  return json({ error: 'Unknown action' }, 400);
});
