# Knowbot — MVP Implementation Plan

Hackathon scope: one Next.js app, one deploy, one language. Drop FastAPI / Railway / Redis — Next.js route handlers + Vercel AI SDK + Vercel Cron + `after()` cover everything we need.

## Stack
- **App:** Next.js 16 (App Router) + React 19 on **Vercel** (entire app lives in `knowbot/`)
- **AI:** Vercel **AI SDK** (`ai` + `@ai-sdk/anthropic` + `@ai-sdk/react`)
  - `claude-haiku-4-5` for classification + profile updates
  - `claude-opus-4-7` for review reply drafts
- **DB + auth:** **Supabase** Postgres + Supabase Auth (email/password)
- **Email:** **Resend** (free sandbox sender)
- **Voice:** **ElevenLabs** Conversational AI agent → calls a Next.js route as its tool
- **Background work:** `after()` from `next/server` (fire-and-forget post-response)
- **Scheduled work:** **Vercel Cron** (cron expressions in `vercel.json`)
- **Mocked Knowcross:** a route handler at `/api/knowcross/*` in the same app

## Architecture
```
 ┌──────────────────────────────────────────────────────────┐
 │                  Next.js on Vercel                       │
 │                                                          │
 │  app/(guest)/*  app/(staff)/*    ← UI                    │
 │  app/api/*                       ← route handlers        │
 │     ├─ requests  reviews  me     ← REST                  │
 │     ├─ agent/chat                ← AI SDK streamText     │
 │     ├─ agent/voice               ← ElevenLabs webhook    │
 │     ├─ knowcross/api/v1/tasks    ← mocked 3rd party      │
 │     └─ cron/dispatch-emails      ← Vercel Cron           │
 │        cron/mark-overdue                                 │
 │  lib/ai · lib/supabase · lib/knowcross                   │
 └────────────────┬─────────────────────────────────────────┘
                  │ SQL via service-role key (server only)
                  ▼
         ┌───────────────────┐    ┌──────────────────────┐
         │ Supabase Postgres │    │ Anthropic · Resend · │
         │     + Auth        │    │ ElevenLabs           │
         └───────────────────┘    └──────────────────────┘
```

## Repo layout
```
rosewood/
├── knowbot/                  # the whole app
│   ├── app/
│   │   ├── (marketing)/      # landing
│   │   ├── (guest)/          # /guest, /guest/onboarding, /guest/review, /guest/login...
│   │   ├── (staff)/          # /staff, /staff/login, /staff/signup
│   │   └── api/
│   │       ├── me/route.ts
│   │       ├── requests/route.ts
│   │       ├── requests/[id]/route.ts
│   │       ├── reviews/route.ts
│   │       ├── reviews/[id]/route.ts
│   │       ├── onboarding/room/route.ts
│   │       ├── checkout/route.ts
│   │       ├── agent/chat/route.ts
│   │       ├── agent/voice/route.ts
│   │       ├── knowcross/api/v1/tasks/route.ts
│   │       └── cron/
│   │           ├── dispatch-emails/route.ts
│   │           └── mark-overdue/route.ts
│   ├── lib/
│   │   ├── supabase/         # server + browser clients
│   │   ├── ai/               # processRequest(), draftReply(), tool defs, prompts
│   │   └── knowcross/        # tiny mock client (calls our own /api/knowcross/*)
│   └── vercel.json           # cron config
└── backend/
    └── db/
        ├── create_tables.sql # Supabase schema (run in SQL editor)
        └── plan.md
```
`backend/` is now just a home for SQL — no service deployed.

## Schema additions
Already applied to `create_tables.sql`:
- `guests.current_room_number` + `guests.checked_in_at` — set on onboarding, cleared on checkout.
- `review_status` enum + `reviews.status` default `'draft'`.
- `scheduled_emails(id, to_email, subject, body, send_at, sent_at, request_id?, review_id?, error)`.
- `conversations(id, guest_id, source, transcript jsonb, request_id?)` — chat + voice transcripts.

## Auth (email/password only)
- Two signup pages, one Supabase project: `/guest/signup` and `/staff/signup` both call `supabase.auth.signUp`; the page decides which profile table gets the row via a follow-up POST to `/api/me/init` with `{ role: 'guest' | 'staff' }`.
- `/api/me` looks up the JWT's `sub` in `guests` then `staff` and returns `{ role, profile }`.
- Supabase dashboard: Email provider on, **"Confirm email" off** for the demo.

## Frontend routes
| Route | Who | Purpose |
|---|---|---|
| `/` | public | landing, two CTAs (Guest / Staff) |
| `/guest/signup`, `/guest/login` | public | email/password |
| `/staff/signup`, `/staff/login` | public | email/password |
| `/guest/onboarding` | guest, first login | input room number (mocked Opera) |
| `/guest` | guest | active requests list + "New request" modal (3 tabs) + "Check out" |
| `/guest/review` | guest, post-checkout | submit star rating + message |
| `/staff` | staff | tabs: **My requests** (assigned to me), **Reviews** (edit AI draft reply + publish) |

"New request" modal tabs:
1. **Form** — room prefilled, description, category, priority.
2. **Chat** — `useChat()` from `@ai-sdk/react` → `/api/agent/chat`; Claude has a `submit_request` tool that creates the row.
3. **Voice** — ElevenLabs widget; agent has the same `submit_request` tool pointed at `/api/agent/voice`.

## API route handlers
```
POST  /api/me/init                  # creates guest or staff profile
GET   /api/me

POST  /api/onboarding/room          # set guests.current_room_number
POST  /api/checkout                 # clear room, queue review prompt

POST  /api/requests                 # manual form -> insert + after(() => processRequest(id))
GET   /api/requests                 # role-filtered
PATCH /api/requests/[id]            # staff updates status

POST  /api/reviews                  # guest submits -> insert + after(() => draftReply(id))
GET   /api/reviews
PATCH /api/reviews/[id]             # staff edits reply / status

POST  /api/agent/chat               # AI SDK streamText with submit_request tool
POST  /api/agent/voice              # ElevenLabs webhook, Bearer-secret authed

POST  /api/knowcross/api/v1/tasks   # mocked Knowcross

GET   /api/cron/dispatch-emails     # Vercel Cron (every minute)
GET   /api/cron/mark-overdue        # Vercel Cron (every 5 minutes)
```
All authed routes verify the Supabase JWT (`supabase.auth.getUser()` from the SSR client). Cron routes verify the `Authorization: Bearer ${CRON_SECRET}` header that Vercel injects.

## Knowbot pipeline (no queue — `after()` is enough)
```ts
// app/api/requests/route.ts
import { after } from "next/server";
import { processRequest } from "@/lib/ai/process-request";

export async function POST(req: Request) {
  const { data: row } = await supabase.from("requests").insert(...).select().single();
  after(() => processRequest(row.id));   // runs on the same function after response sent
  return Response.json(row, { status: 201 });
}
```

**`processRequest(id)`** — fetches the row + guest + the call-description lookup, then:
1. Claude Haiku w/ tool `pickCallDescription({ category_id, call_description_id })`.
2. Pick assignee by category → staff role (housekeeping / maintenance / concierge), fall back to manager.
3. Update the request: `assigned_to`, `category`, `priority`, `knowcross_call_description_id`, `status='assigned'`.
4. POST to our mocked `/api/knowcross/api/v1/tasks` with `private_key` / `property_id` from `integrations`. Stash `knowcross_task_id` + `knowcross_synced_at`, or `knowcross_sync_error` on failure.
5. Claude Haiku again: append to guest `preferences` / `past_issues` / `past_compliments`.
6. Insert a `scheduled_emails` row for ~1h after creation (or `due_at - 30min` if set).

**`draftReply(reviewId)`** — Claude Opus drafts a personalized reply using guest profile context. Saves into `reviews.reply` with `status='draft'`, `replied_by = knowbot_staff_id`. Staff publishes from `/staff`.

Total Knowbot pipeline runtime: ~3–7s, well inside Vercel's 60s function cap.

## Scheduled work (Vercel Cron)
`vercel.json`:
```json
{
  "crons": [
    { "path": "/api/cron/dispatch-emails", "schedule": "* * * * *" },
    { "path": "/api/cron/mark-overdue",    "schedule": "*/5 * * * *" }
  ]
}
```
- `dispatch-emails`: `SELECT ... FROM scheduled_emails WHERE send_at <= now() AND sent_at IS NULL FOR UPDATE SKIP LOCKED LIMIT 25`, send each via Resend, stamp `sent_at` (or `error`).
- `mark-overdue`: `UPDATE requests SET status='overdue' WHERE due_at < now() AND status NOT IN ('closed','overdue')`.

Hobby plan gives you 2 cron jobs — exactly what we need.

## Voice (ElevenLabs)
1. Create a Conversational AI agent in the ElevenLabs dashboard.
2. Add one custom tool `submit_request(description, category, priority)` → `POST https://<vercel-url>/api/agent/voice` with `Authorization: Bearer ${ELEVENLABS_WEBHOOK_SECRET}`.
3. Pass `dynamic_variables.guest_id` when initializing the widget — the webhook trusts it because the page only renders after Supabase login.
4. Agent system prompt: "You are Knowbot, a friendly concierge. Ask what they need, confirm the room number, then call submit_request once and end the call."

## Mocked Knowcross
Route handler at `app/api/knowcross/api/v1/tasks/route.ts`:
- Validates the `public_key` header against the `integrations` row.
- `await new Promise(r => setTimeout(r, 200))`.
- Returns `{ task_id: "kc_" + crypto.randomUUID() }`.

`lib/knowcross/client.ts` calls this with the right headers — when the real Knowcross integration ships, swap the base URL and nothing else.

## Deployment
- **Supabase:** new project, run `create_tables.sql` in SQL editor, Email auth on, "Confirm email" off.
- **Vercel:** import `knowbot/`. Env vars:
  ```
  NEXT_PUBLIC_SUPABASE_URL
  NEXT_PUBLIC_SUPABASE_ANON_KEY
  SUPABASE_SERVICE_ROLE_KEY      # server-only
  ANTHROPIC_API_KEY              # server-only
  RESEND_API_KEY                 # server-only
  ELEVENLABS_WEBHOOK_SECRET      # server-only
  CRON_SECRET                    # Vercel auto-injects; we verify in cron routes
  NEXT_PUBLIC_ELEVENLABS_AGENT_ID
  ```
- No second service. No Redis. No Railway.

## Dependencies to add
```bash
npm i ai @ai-sdk/anthropic @ai-sdk/react @supabase/supabase-js @supabase/ssr resend zod
```

## Build order
1. **Schema + auth** — apply schema, both signup pages working, `/api/me` returns role. (~1.5h)
2. **Manual request flow** — guest form → row → staff sees it. No AI yet. (~1.5h)
3. **Knowbot v1** — `processRequest()` job via `after()`: classify, assign, mock-sync Knowcross. (~2h)
4. **Checkout + review + AI draft reply** — including staff edit/publish UI. (~2h)
5. **Cron: email dispatcher + overdue marker.** (~1h)
6. **Chat mode** — `useChat` + `streamText` + `submit_request` tool. (~1h, fastest mode thanks to AI SDK)
7. **Voice mode** — ElevenLabs agent + webhook. Last because it's the riskiest external dep. (~1.5h)
8. **Polish** — empty states, loading spinners, friendly landing page.

## Explicitly NOT in MVP
- Google OAuth (email only).
- Real Knowcross / Opera integrations.
- RLS policies (service-role from route handlers; revisit post-hackathon).
- Bookings/stays table (just `current_room_number` on `guests`).
- Durable job queue (`after()` is fine until a single request needs > 60s — then move to Inngest or Trigger.dev).
- Multi-property support, audit log, retries, observability beyond `console.log`.

## When you'd outgrow this
- A single Knowbot job needs > 60s (hobby cap; Pro is 300s+) → add Inngest or QStash.
- You need retries with backoff → same.
- More than 2 cron jobs on hobby → upgrade Vercel plan or move cron to Supabase `pg_cron`.
- Multi-tenant scale → revisit RLS + service-role usage.
