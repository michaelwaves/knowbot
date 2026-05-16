# Knowbot — MVP Implementation Plan

Hackathon scope: keep everything as small as it can be and still demo.

## Stack
- **Frontend:** Next.js 15 (App Router) on Vercel — `knowbot/`
- **Backend:** FastAPI on Railway — `backend/`
- **Worker:** arq (Redis-backed async queue) — same repo, separate Railway service
- **DB + auth:** Supabase (Postgres + email/password auth)
- **Cache + queue:** Redis on Railway
- **AI:** Anthropic Claude — `claude-haiku-4-5` for classification, `claude-opus-4-7` for review replies
- **Voice:** ElevenLabs Conversational AI (webhook tool calls back into FastAPI)
- **Email:** Resend (free tier sandbox sender is fine for demo)
- **Mocked Knowcross:** small router inside `backend/` exposing `/knowcross/api/v1/tasks`

## Architecture
```
 ┌─────────────────────┐         ┌──────────────────────┐
 │  Next.js (Vercel)   │ ──────▶ │  FastAPI (Railway)   │ ──┐
 │  guest + staff UIs  │ ◀────── │   /api/*             │   │ enqueue
 └─────────────────────┘  JWT    └──────────────────────┘   ▼
          ▲                            ▲             ┌───────────────┐
          │ ElevenLabs widget          │ webhook     │ arq worker    │
          ▼                            │             │ (Railway)     │
 ┌─────────────────────┐               │             └──────┬────────┘
 │ ElevenLabs Agent    │ ──────────────┘                    │
 └─────────────────────┘                                    │ Claude / Resend / Knowcross mock
                                                            ▼
                                                  ┌──────────────────┐
                                                  │ Supabase Postgres│
                                                  └──────────────────┘
```

## Schema additions (append to `create_tables.sql`)
- `guests.current_room_number text` + `guests.checked_in_at timestamptz` — set at onboarding, cleared at checkout.
- `review_status` enum `('draft','published')`; add `reviews.status review_status not null default 'draft'`.
- New table `scheduled_emails(id, to_email, subject, body, send_at, sent_at, request_id?, review_id?, created_at)`.
- New table `conversations(id, guest_id, source enum('chat','voice'), transcript jsonb, request_id?, created_at)` — for debugging and so chat/voice flows have somewhere to land their messages.

## Auth (email/password only)
- Two signup pages, one Supabase project: `/guest/signup` and `/staff/signup`. Different page, same `supabase.auth.signUp`; after success POST to `/api/me/init` with the chosen role so the right profile row gets inserted.
- `/api/me` looks up the JWT's `sub` in `guests` then `staff` and returns `{ role, profile }`.
- Supabase dashboard: enable Email provider, **turn off "Confirm email"** for the demo.

## Frontend routes
| Route | Who | Purpose |
|---|---|---|
| `/` | public | landing, "I'm a guest" / "I'm staff" CTAs |
| `/guest/signup`, `/guest/login` | public | email/password |
| `/staff/signup`, `/staff/login` | public | email/password |
| `/guest/onboarding` | guest, first login | input room number (would be Opera; mocked) |
| `/guest` | guest | active requests list + "New request" modal (3 tabs) + "Check out" button |
| `/guest/review` | guest, post-checkout | submit star rating + message |
| `/staff` | staff | tabs: **My requests** (assigned to me), **Reviews** (all, edit AI draft replies) |

The "New request" modal has 3 tabs:
1. **Form** — room prefilled, description, category, priority.
2. **Chat** — SSE stream to `/api/agent/chat`; Claude has a `create_request` tool it calls when it has enough info.
3. **Voice** — embed the ElevenLabs widget; it calls our webhook when the user is done.

## Backend endpoints
```
POST  /api/me/init                 # role-aware profile create
GET   /api/me

POST  /api/onboarding/room         # set guests.current_room_number
POST  /api/checkout                # clear room, queue review prompt email

POST  /api/requests                # manual form -> insert + enqueue knowbot
GET   /api/requests                # role-filtered (guest=own, staff=assigned)
PATCH /api/requests/{id}           # staff updates status

POST  /api/reviews                 # guest submits review (also enqueues draft_reply)
GET   /api/reviews
PATCH /api/reviews/{id}            # staff edits reply / publishes / re-drafts

POST  /api/agent/chat              # SSE; Claude tool-use -> create_request
POST  /api/agent/voice/webhook     # ElevenLabs webhook -> create_request
```
All authed endpoints verify Supabase JWT in a FastAPI dependency. FastAPI talks to Postgres with the **service-role key** so we can skip RLS for MVP.

## Knowbot pipeline
Triggered after every `INSERT` into `requests` or `reviews`. Always async via arq so the API stays snappy.

**`process_request(request_id)`** — runs on new request:
1. Load request + guest profile + the `knowcross_call_descriptions` table.
2. Claude Haiku with a `pick_call_description(category_id, call_description_id)` tool. Picks the best match.
3. Pick assignee by category → staff `role` (housekeeping / maintenance / concierge / frontdesk). Fall back to a manager.
4. Update the request row: `assigned_to`, `category`, `priority`, `knowcross_call_description_id`, `status='assigned'`.
5. POST to the mocked Knowcross endpoint with `private_key`/`property_id` pulled from `integrations`. Stash returned `knowcross_task_id` and `knowcross_synced_at`, or `knowcross_sync_error` on failure.
6. Claude Haiku again: read the request text and update guest profile fields (`preferences`, `past_issues`, `past_compliments`). Append, don't replace.
7. Insert a `scheduled_emails` row for ~1h after creation (or `due_at - 30min` if set): "Following up on your request…".

**`draft_review_reply(review_id)`** — runs on new review:
1. Load review + guest profile (so reply can reference past stays / preferences).
2. Claude Opus drafts a personalized reply.
3. Save into `reviews.reply` with `status='draft'`, `replied_by = knowbot_staff_id`. Staff publishes from `/staff`.

## Background jobs (arq, one worker process)
- `process_request` — enqueued by API on create.
- `draft_review_reply` — enqueued by API on review create.
- `email_dispatcher` — cron every 60s: `SELECT ... FOR UPDATE SKIP LOCKED` on `scheduled_emails` where `send_at <= now() AND sent_at IS NULL`, send via Resend, stamp `sent_at`.
- `mark_overdue` — cron every 5min: requests where `due_at < now() AND status NOT IN ('closed')` → `status='overdue'`.

## Voice (ElevenLabs)
1. Create a Conversational AI agent in ElevenLabs dashboard.
2. Add one custom tool `submit_request(description, category, priority)` → `POST {RAILWAY_URL}/api/agent/voice/webhook`, with a static `Authorization: Bearer ${ELEVENLABS_WEBHOOK_SECRET}` header.
3. Pass guest identity through `dynamic_variables.guest_id` when initializing the widget; the webhook trusts it because the page only loads after Supabase login.
4. Agent system prompt: "You are Knowbot, a friendly concierge. Ask what they need, confirm room number, then call submit_request once."

## Mocked Knowcross
A FastAPI router mounted at `/knowcross/api/v1`:
- `POST /tasks` — validates the `public_key` header against the `integrations` row, sleeps 200ms, returns `{ task_id: "kc_" + uuid4() }`.
- This lets the real client code path stay identical for the post-hackathon real integration.

## Deployment
- **Supabase:** new project, run `create_tables.sql` in SQL editor, enable Email auth with "Confirm email" off.
- **Railway:** import `backend/`. Two services from the same repo:
  - `web`: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`
  - `worker`: `arq workers.main.WorkerSettings`
  - Redis plugin attached.
  - Env: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `ANTHROPIC_API_KEY`, `RESEND_API_KEY`, `ELEVENLABS_WEBHOOK_SECRET`, `REDIS_URL`.
- **Vercel:** import `knowbot/`. Env: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_API_URL` (Railway web URL), `NEXT_PUBLIC_ELEVENLABS_AGENT_ID`.

## Build order (suggested)
1. **Schema + auth** — apply schema, both signup pages working, `/api/me` returns role. (~1.5h)
2. **Manual request flow** — guest form → row → staff sees it. No AI. Proves the whole loop end-to-end. (~2h)
3. **Knowbot v1** — `process_request` job: classify, assign, mock-sync Knowcross. (~2h)
4. **Checkout + review + AI draft reply** — including staff edit/publish UI. (~2h)
5. **Scheduled email worker** + Resend. (~1h)
6. **Chat mode** — SSE streaming, Claude `create_request` tool. (~1.5h)
7. **Voice mode** — ElevenLabs agent + webhook. Last because it's the riskiest external dep. (~1.5h)
8. **Polish** — empty states, loading spinners, a friendly landing page.

## Explicitly NOT in MVP
- Google OAuth (email only).
- Real Knowcross / real Opera integrations.
- RLS policies (service-role from backend; revisit post-hackathon).
- Bookings/stays table (just the current room on `guests`).
- Multi-property support, audit log, retries beyond arq defaults, observability beyond `print()`.
