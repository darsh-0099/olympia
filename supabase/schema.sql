-- Run in the Supabase SQL Editor. Never put a service-role key in the iOS app.
create table if not exists public.training_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  revision bigint not null default 1,
  updated_at timestamptz not null default now()
);

alter table public.training_data enable row level security;

drop policy if exists "Owner reads training data" on public.training_data;
drop policy if exists "Owner creates training data" on public.training_data;
drop policy if exists "Owner updates training data" on public.training_data;
drop policy if exists "Owner deletes training data" on public.training_data;

create policy "Owner reads training data" on public.training_data
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Owner creates training data" on public.training_data
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Owner updates training data" on public.training_data
  for update to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
create policy "Owner deletes training data" on public.training_data
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Expected client payload: OlympiaBackup (workouts, sessions, programs, weights).
-- Revision supports optimistic concurrency when syncing multiple devices.
