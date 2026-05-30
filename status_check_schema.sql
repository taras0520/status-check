

-- 0. Розширення для uuid (у Supabase зазвичай уже є) --------
create extension if not exists "pgcrypto";

-- 1. Enum статусів комітменту ------------------------------
--    Збігається з гілками воркфлоу та станами картки на фронті.
do $$
begin
  if not exists (select 1 from pg_type where typname = 'commitment_status') then
    create type commitment_status as enum (
      'to_check',
      'expired',
      'done',
      'not_actual',
      'ideas_backlog'
    );
  end if;
end$$;

-- 2. Користувачі -------------------------------------------
--    author_id / checker_id посилаються сюди.
--    telegram_chat_id потрібен cron-нотифікації рев'юеру.
--    Якщо використовуєш Supabase Auth — можна замість цієї
--    таблиці посилатися на auth.users(id); див. коментар нижче.
create table if not exists public.users (
  id               uuid primary key default gen_random_uuid(),
  email            text unique not null,
  full_name        text,
  telegram_chat_id text,                       -- для Telegram-нотифікацій
  created_at       timestamptz not null default now()
);

-- 3. Комітменти --------------------------------------------
create table if not exists public.commitments (
  id           uuid primary key default gen_random_uuid(),
  author_id    uuid not null references public.users(id) on delete restrict,
  title        text not null,
  description  text,
  project      text not null,                  -- фільтр #1
  assignee     text,                           -- відповідальний виконавець (може бути зовнішнім)
  checker_id   uuid not null references public.users(id) on delete restrict, -- фільтр #2
  deadline     timestamptz,                    -- конкретний час АБО лише дата (див. is_all_day)
  is_all_day   boolean not null default false, -- true => фронт рендерить як all-day подію
  status       commitment_status not null default 'to_check',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- 4. Індекси -----------------------------------------------
-- Під GET /list з фільтрами project + checker_id:
create index if not exists idx_commitments_project    on public.commitments (project);
create index if not exists idx_commitments_checker    on public.commitments (checker_id);
-- Під cron-запит (status='to_check' AND deadline < now()):
create index if not exists idx_commitments_status_dl  on public.commitments (status, deadline);

-- 5. Авто-оновлення updated_at -----------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end$$;

drop trigger if exists trg_commitments_updated_at on public.commitments;
create trigger trg_commitments_updated_at
  before update on public.commitments
  for each row execute function public.set_updated_at();

-- 6. Row Level Security (Supabase) -------------------------
--    Supabase за замовчуванням блокує доступ, поки немає політик.
--    n8n ходить через service_role key (RLS оминає), тож для MVP
--    достатньо ввімкнути RLS і дозволити доступ авторизованим.
alter table public.commitments enable row level security;
alter table public.users        enable row level security;

-- Спільна база-календар: будь-який залогінений користувач бачить усі комітменти.
drop policy if exists "auth read commitments" on public.commitments;
create policy "auth read commitments"
  on public.commitments for select
  to authenticated using (true);



