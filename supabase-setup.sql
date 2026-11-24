-- Supabase setup:
-- 1. Run this file in the project's SQL Editor.
-- 2. Create the first admin in Authentication > Users.
-- 3. Add that user's UUID to admin_users, for example:
--    insert into public.admin_users (user_id)
--    values ('AUTH_USER_UUID');
-- 4. Set the project URL and anon key in both HTML pages.
-- Never put a Supabase service_role key in browser code.

create table if not exists public.orders (
  id text primary key,
  nama text not null,
  email text not null,
  wa text not null,
  usaha text not null,
  jenis text not null default '',
  kota text not null default '',
  alamat text not null default '',
  it jsonb not null default '[]'::jsonb,
  total bigint not null check (total >= 0),
  st smallint not null default 0 check (st between 0 and 9),
  paid boolean not null default false,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users (id) on delete cascade
);

create table if not exists public.dashboard_stats (
  id boolean primary key default true check (id),
  served_clients bigint not null default 0,
  in_progress bigint not null default 0,
  completed bigint not null default 0
);

insert into public.dashboard_stats (id)
values (true)
on conflict (id) do nothing;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.admin_users where user_id = auth.uid()
  );
$$;

create or replace function public.completed_order_review_details(p_order_id text, p_email text)
returns table (customer_name text, business_label text, service_names text[])
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    o.nama,
    coalesce(nullif(o.jenis, ''), o.usaha),
    coalesce(array_agg(item.value ->> 'n') filter (where item.value ->> 'n' is not null), array[]::text[])
  from public.orders o
  left join lateral jsonb_array_elements(o.it) as item(value) on true
  where o.id = p_order_id
    and lower(o.email) = lower(p_email)
    and o.st = 8
  group by o.nama, o.jenis, o.usaha;
$$;

create or replace function public.refresh_dashboard_stats()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.dashboard_stats (
    id, served_clients, in_progress, completed
  )
  select
    true,
    count(distinct lower(email)),
    count(*) filter (where st between 1 and 7),
    count(*) filter (where st = 8)
  from public.orders
  on conflict (id) do update set
    served_clients = excluded.served_clients,
    in_progress = excluded.in_progress,
    completed = excluded.completed;
  return null;
end;
$$;

drop trigger if exists orders_refresh_dashboard_stats on public.orders;
create trigger orders_refresh_dashboard_stats
after insert or update or delete on public.orders
for each statement execute function public.refresh_dashboard_stats();

alter table public.orders enable row level security;
alter table public.admin_users enable row level security;
alter table public.dashboard_stats enable row level security;

drop policy if exists "Public can create pending orders" on public.orders;
create policy "Public can create pending orders"
on public.orders for insert to anon, authenticated
with check (st = 0 and paid = false and note is null);

drop policy if exists "Admins can read orders" on public.orders;
create policy "Admins can read orders"
on public.orders for select to authenticated
using (public.is_admin());

drop policy if exists "Admins can update orders" on public.orders;
create policy "Admins can update orders"
on public.orders for update to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "Users can read their own admin access" on public.admin_users;
create policy "Users can read their own admin access"
on public.admin_users for select to authenticated
using (user_id = auth.uid());

drop policy if exists "Anyone can read dashboard aggregates" on public.dashboard_stats;
create policy "Anyone can read dashboard aggregates"
on public.dashboard_stats for select to anon, authenticated
using (true);

grant usage on schema public to anon, authenticated;
grant insert on public.orders to anon, authenticated;
grant select, update on public.orders to authenticated;
grant select on public.admin_users to authenticated;
revoke all on public.dashboard_stats from anon, authenticated;
grant select on public.dashboard_stats to anon, authenticated;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;
revoke all on function public.completed_order_review_details(text, text) from public;
grant execute on function public.completed_order_review_details(text, text) to anon, authenticated;
revoke all on function public.refresh_dashboard_stats() from public, anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'dashboard_stats'
  ) then
    alter publication supabase_realtime add table public.dashboard_stats;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'orders'
  ) then
    alter publication supabase_realtime add table public.orders;
  end if;
end
$$;
