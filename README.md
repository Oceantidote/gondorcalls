# gondorcalls.com

Invite-only site for the Warhammer group: Secret Santa, meetups, birthday presents, ventures, gallery.
Planning and decisions live in the site's own vault project, not here.

## How it fits together

| Piece | Where it runs | Source here |
|---|---|---|
| The page (single-file app) | Cloudflare Pages project `gondorcalls`, git-connected: **push to `main` = deploy**, output dir `public`, no build. Custom domain `gondorcalls.com` | `public/index.html` |
| Worker | Cloudflare Worker `gondorcalls`: owns `www.gondorcalls.com` (301 → apex) and the daily cron | `worker/` |
| Database, auth, rules | Supabase project `vhlalqnxkasijbspyrrp` ("Warhammer Secret Santa", eu-west-2, free tier) | `supabase/migrations/` |
| Invite / password-reset links | Supabase Edge Function `invite` (`verify_jwt = false`, the link token is the credential) | `supabase/functions/invite/` |
| Photos | Supabase Storage bucket `models` (public read, members upload into their own folder) | — |

- **Daily cron** (06:17 UTC) on the Worker calls `ping()`, which keeps the free Supabase project from pausing
  and opens birthday gift plans 28 days ahead.
- **Old address** `secret-santa.leonardpercival.workers.dev` is a separate Worker that 301s here, keeping
  `#invite=` / `#reset=` links working.
- **Secrecy model:** tables have RLS; anything one member must not see uses `hidden_from uuid[]` + `can_see()`.
  Secret Santa assignments are readable only by the giver; the draw runs server-side in `ss_run_draw()`.
- **Email** goes through Resend from `hello@gondorcalls.com` (DKIM/return-path records and a monitoring-only
  DMARC in Cloudflare DNS; API key in the Supabase secret `RESEND_API_KEY`). Edge function `email`:
  `invite` (admin, emails a join link), `forgot` (public, emails a 2-hour reset link, max 3 an hour),
  `outbox` (sends what database triggers queued in `email_outbox`; the Worker calls it every 5 minutes).
  Notifications: new proposal, venture launched / live, new meetup, gift plan opened (never to the birthday
  person), gift bought (pay the buyer back), Secret Santa drawn (no names), task assigned. Members can opt
  out on their profile; invites and resets always send. Supabase Auth's own mailer is not used.

## Deploying

- **Page:** push to `main`. Cloudflare Pages publishes it in under a minute. Check the deployment's source
  commit in the Pages dashboard, not just that the push succeeded. (Until 13 Nov 2026 the page was served from
  the `public.site_files` table by the Worker; that row is now a stale leftover and nothing reads it for the apex.)
- **Worker:** `cd worker && npx wrangler deploy`.
- **Edge function:** `supabase functions deploy invite --no-verify-jwt --project-ref vhlalqnxkasijbspyrrp`.
- **Schema:** migrations here are the as-applied history from 2026-11-13 (the earlier v1 token-based schema
  was dropped with no data). Every function body was verified identical to the live database at commit time.

The publishable key in `index.html` and `worker.js` is meant to be public; all protection is in RLS and the
security-definer functions. Never commit the service-role key.
