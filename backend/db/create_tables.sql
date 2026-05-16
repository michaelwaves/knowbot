-- Knowbot hackathon MVP schema (Postgres / Supabase)
-- Run this in the Supabase SQL editor.

create extension if not exists "uuid-ossp";

-- ---------- enums ----------
create type request_status   as enum ('open', 'assigned', 'closed', 'overdue');
create type request_priority as enum ('low', 'medium', 'high', 'urgent');
create type staff_role       as enum ('manager', 'frontdesk', 'housekeeping', 'maintenance', 'concierge', 'ai_agent');
create type review_status    as enum ('draft', 'published');
create type conversation_source as enum ('chat', 'voice');

-- ---------- guests ----------
create table guests (
  id              uuid primary key default uuid_generate_v4(),
  auth_user_id    uuid unique references auth.users(id) on delete set null, -- Supabase auth link
  first_name      text not null,
  last_name       text,
  email           text unique not null,
  booked_with     text,          -- e.g. "Expedia", "direct"
  preferences     text,          -- free-form for MVP; promote to jsonb later
  past_issues     text,
  past_compliments text,
  current_room_number text,                -- set at onboarding, cleared at checkout (mocked Opera)
  checked_in_at   timestamptz,
  created_at      timestamptz not null default now()
);

-- ---------- staff ----------
create table staff (
  id            uuid primary key default uuid_generate_v4(),
  auth_user_id  uuid unique references auth.users(id) on delete set null,
  first_name    text not null,
  last_name     text,
  email         text unique,
  phone         text,
  role          staff_role not null default 'frontdesk',
  is_ai         boolean not null default false,
  created_at    timestamptz not null default now()
);

-- ---------- knowcross lookup ----------
-- maps a (category, description) to the Knowcross "call description id".
-- e.g. (17950, 'Ac Too Cold') -> 267159
create table knowcross_call_descriptions (
  call_description_id bigint primary key,
  category_id         bigint not null,
  description         text   not null,
  created_at          timestamptz not null default now()
);
create index on knowcross_call_descriptions (category_id);

-- ---------- requests (work orders) ----------
create table requests (
  id            uuid primary key default uuid_generate_v4(),
  room_number   text not null,
  description   text not null,
  category      text,                              -- "maintenance", "amenity", etc.
  assigned_to   uuid references staff(id)  on delete set null,
  due_at        timestamptz,                       -- "time left" = due_at - now()
  requested_by  uuid references guests(id) on delete set null,
  notes         text,
  priority      request_priority not null default 'medium',
  status        request_status   not null default 'open',
  created_at    timestamptz not null default now(),
  created_by    uuid references staff(id) on delete set null, -- null if guest self-served, else staff (incl. knowbot)

  -- Knowcross sync state
  knowcross_call_description_id bigint references knowcross_call_descriptions(call_description_id),
  knowcross_task_id             text,         -- ID returned by Knowcross after sync
  knowcross_synced_at           timestamptz,
  knowcross_sync_error          text          -- non-null if last sync attempt failed
);

-- ---------- reviews ----------
create table reviews (
  id          uuid primary key default uuid_generate_v4(),
  message     text not null,
  stars       int  check (stars between 1 and 5),
  reply       text,
  replied_by  uuid references staff(id)  on delete set null,
  replied_at  timestamptz,
  status      review_status not null default 'draft',  -- AI writes draft; staff publishes
  created_by  uuid references guests(id) on delete set null,
  created_at  timestamptz not null default now()
);

-- ---------- scheduled emails (worker polls this) ----------
create table scheduled_emails (
  id          uuid primary key default uuid_generate_v4(),
  to_email    text not null,
  subject     text not null,
  body        text not null,
  send_at     timestamptz not null,
  sent_at     timestamptz,                            -- null = not yet sent
  request_id  uuid references requests(id) on delete cascade,
  review_id   uuid references reviews(id)  on delete cascade,
  error       text,                                   -- last send error if any
  created_at  timestamptz not null default now()
);
create index on scheduled_emails (send_at) where sent_at is null;

-- ---------- conversations (chat + voice transcripts) ----------
create table conversations (
  id          uuid primary key default uuid_generate_v4(),
  guest_id    uuid references guests(id) on delete set null,
  source      conversation_source not null,
  transcript  jsonb not null default '[]'::jsonb,     -- [{role, content, ts}, ...]
  request_id  uuid references requests(id) on delete set null,  -- set once the convo produces a request
  created_at  timestamptz not null default now()
);
create index on conversations (guest_id);

-- ---------- indexes ----------
create index on requests (status);
create index on requests (assigned_to);
create index on requests (requested_by);
create index on reviews  (created_by);
create index on reviews  (status);

-- ---------- integrations (3rd-party credentials) ----------
-- One row per provider. For the hackathon Knowcross is mocked, but the shape
-- matches what their setup docs ask for (private_key, public_key, property_id,
-- api_url). Real deployment: keep secrets in a vault, not Postgres.
create table integrations (
  id          uuid primary key default uuid_generate_v4(),
  provider    text not null unique,        -- 'knowcross'
  enabled     boolean not null default true,
  api_url     text,
  property_id text,
  public_key  text,
  private_key text,
  config      jsonb not null default '{}'::jsonb,  -- anything else provider-specific
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- seed: AI agent staff row ----------
insert into staff (first_name, last_name, email, role, is_ai)
values ('Knowbot', 'AI', 'knowbot@rosewoodhotels.com', 'ai_agent', true);

-- ---------- seed: mocked Knowcross integration ----------
insert into integrations (provider, api_url, property_id, public_key, private_key, config)
values (
  'knowcross',
  'https://mock.knowcross.local/api/v1',
  'PROP_MOCK_001',
  'pk_mock_public_key',
  'sk_mock_private_key',
  '{"default_category_id": 17950}'::jsonb
);

-- ---------- seed: Knowcross call descriptions (from Duve docs) ----------
insert into knowcross_call_descriptions (category_id, description, call_description_id) values
  (17791, 'Deliver Item',             263343),
  (17950, 'Ac Controller Not Working', 267152),
  (17950, 'Ac Leaking',                267153),
  (17950, 'Ac Panel Damaged',          267154),
  (17950, 'Other Ac',                  267155),
  (17950, 'Ac Air Flow To Adjust',     267156),
  (17950, 'Ac Bad Smell',              267157),
  (17950, 'Ac Noisy',                  267158),
  (17950, 'Ac Too Cold',               267159),
  (17950, 'Ac Too Warm',               267160),
  (17951, 'Amenity Needed In Room',    267161),
  (17951, 'Bouquet Required',          267162),
  (17952, 'Highlighter Required',      267163),
  (17952, 'Post It Pad Required',      267164),
  (17952, 'Ruler Required',            267165),
  (17952, 'Scissors Required',         267166),
  (17952, 'Scotch Tape Required',      267167),
  (17952, 'Stapler Required',          267168);
