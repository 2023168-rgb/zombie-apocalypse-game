-- 공개 전시관에는 선택한 무기 정보만 저장합니다. 게임 저장 데이터 전체는 공개하지 않습니다.
create table if not exists public.trophy_showcases (
  user_id uuid primary key references auth.users(id) on delete cascade,
  weapons jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.trophy_showcases enable row level security;

drop policy if exists "Anyone can view trophy showcases" on public.trophy_showcases;
create policy "Anyone can view trophy showcases"
  on public.trophy_showcases for select
  to anon, authenticated
  using (true);

drop policy if exists "Users can publish their own trophy showcase" on public.trophy_showcases;
create policy "Users can publish their own trophy showcase"
  on public.trophy_showcases for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Users can update their own trophy showcase" on public.trophy_showcases;
create policy "Users can update their own trophy showcase"
  on public.trophy_showcases for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

grant select on public.trophy_showcases to anon, authenticated;
grant insert, update on public.trophy_showcases to authenticated;
