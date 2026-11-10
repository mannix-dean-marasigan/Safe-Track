-- ============================================================================
-- SafeTrack backend schema for Supabase (free tier is enough for a small pilot)
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Then: Authentication -> Providers -> Email: for testing turn OFF "Confirm email"
-- (or users must click the confirmation link before they can sign in).
-- Finally paste your Project URL and "anon" public key into SUPABASE_URL /
-- SUPABASE_ANON_KEY near the top of the "ACCOUNTS, CONTACTS, SOS ALERTS" block
-- in the app's HTML.
--
-- Privacy design
--   * sos_alerts holds the EXACT location. Only the owner and the owner's ACCEPTED
--     contacts can read it (row level security).
--   * Everyone else only ever gets an APPROXIMATE point (rounded to ~200 m, no name,
--     no accuracy) through list_visible_sos(). They can never query the table.
--   * All writes go through functions that check auth.uid(); clients cannot insert
--     or edit other people's rows.
--   * Alerts disappear from other people's maps 2 hours after the last update.
-- Known limits (see README notes): any signed-in user can create an alert (abuse
-- needs moderation/rate limits later); looking up an email reveals whether it is
-- registered; this does not contact police or emergency services.
-- ============================================================================

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'SafeTrack user',
  email text not null,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles for select using (id = auth.uid());

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, email)
  values (new.id,
          coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), split_part(new.email, '@', 1)),
          lower(new.email))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create table if not exists public.contacts (
  id uuid primary key default gen_random_uuid(),
  requester uuid not null references public.profiles(id) on delete cascade,
  addressee uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  check (requester <> addressee)
);
create unique index if not exists contacts_pair_idx
  on public.contacts (least(requester, addressee), greatest(requester, addressee));
alter table public.contacts enable row level security;
drop policy if exists "read my contacts" on public.contacts;
create policy "read my contacts" on public.contacts for select
  using (requester = auth.uid() or addressee = auth.uid());
-- no insert/update/delete policies on purpose: changes only through the functions below

create table if not exists public.sos_alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  lat double precision,
  lon double precision,
  accuracy real,
  confirmed boolean not null default false,
  active boolean not null default true,
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  ended_at timestamptz,
  check ((lat is null) = (lon is null)),
  check (lat between -90 and 90 and lon between -180 and 180)
);
create index if not exists sos_alerts_active_idx on public.sos_alerts (active, updated_at);
create index if not exists sos_alerts_user_idx on public.sos_alerts (user_id, active);
alter table public.sos_alerts enable row level security;
drop policy if exists "owner or accepted contact reads alert" on public.sos_alerts;
create policy "owner or accepted contact reads alert" on public.sos_alerts for select using (
  user_id = auth.uid()
  or exists (
    select 1 from public.contacts c
    where c.status = 'accepted'
      and ((c.requester = auth.uid() and c.addressee = sos_alerts.user_id)
        or (c.addressee = auth.uid() and c.requester = sos_alerts.user_id))
  )
);

-- ---------------------------------------------------------------- contacts API
create or replace function public.list_contacts()
returns table (contact_id uuid, other_id uuid, other_name text, other_email text, status text)
language sql security definer set search_path = public stable as $$
  select c.id, p.id, p.display_name, p.email,
         case when c.status = 'accepted' then 'accepted'
              when c.requester = auth.uid() then 'outgoing'
              else 'incoming' end
  from public.contacts c
  join public.profiles p on p.id = case when c.requester = auth.uid() then c.addressee else c.requester end
  where auth.uid() in (c.requester, c.addressee)
  order by c.created_at;
$$;

create or replace function public.request_contact(p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); other uuid; ex public.contacts;
begin
  if me is null then raise exception 'not signed in'; end if;
  select id into other from public.profiles where email = lower(trim(p_email));
  if other is null then return 'not_found'; end if;
  if other = me then return 'self'; end if;
  select * into ex from public.contacts
   where least(requester, addressee) = least(me, other) and greatest(requester, addressee) = greatest(me, other);
  if found then
    if ex.status = 'accepted' then return 'already'; end if;
    if ex.requester = me then return 'already_requested'; end if;
    update public.contacts set status = 'accepted' where id = ex.id;   -- they had asked me first: now mutual
    return 'accepted';
  end if;
  insert into public.contacts (requester, addressee) values (me, other);
  return 'requested';
end $$;

create or replace function public.respond_contact(p_id uuid, p_accept boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_accept then
    update public.contacts set status = 'accepted' where id = p_id and addressee = auth.uid() and status = 'pending';
  else
    delete from public.contacts where id = p_id and addressee = auth.uid() and status = 'pending';
  end if;
  return found;
end $$;

create or replace function public.remove_contact(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from public.contacts where id = p_id and auth.uid() in (requester, addressee);
  return found;
end $$;

-- --------------------------------------------------------------------- SOS API
create or replace function public.start_sos(p_lat double precision, p_lon double precision, p_acc real, p_confirmed boolean)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); new_id uuid; n int;
begin
  if me is null then raise exception 'not signed in'; end if;
  update public.sos_alerts set active = false, ended_at = now() where user_id = me and active;   -- one active alert per person
  insert into public.sos_alerts (user_id, lat, lon, accuracy, confirmed)
  values (me, p_lat, p_lon, p_acc, coalesce(p_confirmed, false)) returning id into new_id;
  select count(*) into n from public.contacts c
   where c.status = 'accepted' and me in (c.requester, c.addressee);
  return json_build_object('id', new_id, 'notified', n);
end $$;

create or replace function public.update_sos(p_id uuid, p_lat double precision, p_lon double precision, p_acc real, p_confirmed boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update public.sos_alerts
     set lat = p_lat, lon = p_lon, accuracy = p_acc, confirmed = coalesce(p_confirmed, confirmed), updated_at = now()
   where id = p_id and user_id = auth.uid() and active;
  return found;
end $$;

create or replace function public.end_sos(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update public.sos_alerts set active = false, ended_at = now(), updated_at = now()
   where id = p_id and user_id = auth.uid() and active;
  return found;
end $$;

-- What a signed-in user may see: accepted contacts' alerts with exact position and name;
-- everyone else's alerts as an approximate point (~200 m grid), no name, no accuracy.
create or replace function public.list_visible_sos()
returns table (id uuid, kind text, name text, lat double precision, lon double precision,
               accuracy real, confirmed boolean, started_at timestamptz, updated_at timestamptz)
language sql security definer set search_path = public stable as $$
  select a.id,
         case when ct.id is not null then 'contact' else 'public' end,
         case when ct.id is not null then p.display_name end,
         case when a.lat is null then null
              when ct.id is not null then a.lat
              else ((round((a.lat / 0.002)::numeric) * 0.002)::double precision) end,
         case when a.lon is null then null
              when ct.id is not null then a.lon
              else ((round((a.lon / 0.002)::numeric) * 0.002)::double precision) end,
         case when ct.id is not null then a.accuracy end,
         case when ct.id is not null then a.confirmed end,
         a.started_at, a.updated_at
  from public.sos_alerts a
  join public.profiles p on p.id = a.user_id
  left join public.contacts ct
         on ct.status = 'accepted'
        and ((ct.requester = auth.uid() and ct.addressee = a.user_id)
          or (ct.addressee = auth.uid() and ct.requester = a.user_id))
  where auth.uid() is not null
    and a.active
    and a.updated_at > now() - interval '2 hours'
    and a.user_id <> auth.uid()
  order by a.started_at desc;
$$;

-- only signed-in users may call the functions
revoke all on function public.list_contacts() from public, anon;
revoke all on function public.request_contact(text) from public, anon;
revoke all on function public.respond_contact(uuid, boolean) from public, anon;
revoke all on function public.remove_contact(uuid) from public, anon;
revoke all on function public.start_sos(double precision, double precision, real, boolean) from public, anon;
revoke all on function public.update_sos(uuid, double precision, double precision, real, boolean) from public, anon;
revoke all on function public.end_sos(uuid) from public, anon;
revoke all on function public.list_visible_sos() from public, anon;
grant execute on function public.list_contacts() to authenticated;
grant execute on function public.request_contact(text) to authenticated;
grant execute on function public.respond_contact(uuid, boolean) to authenticated;
grant execute on function public.remove_contact(uuid) to authenticated;
grant execute on function public.start_sos(double precision, double precision, real, boolean) to authenticated;
grant execute on function public.update_sos(uuid, double precision, double precision, real, boolean) to authenticated;
grant execute on function public.end_sos(uuid) to authenticated;
grant execute on function public.list_visible_sos() to authenticated;

-- live updates for the app (rows are still filtered by the policies above)
do $$ begin
  begin alter publication supabase_realtime add table public.sos_alerts; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.contacts;   exception when duplicate_object then null; end;
end $$;


-- ============================================================================
-- v2 ADDITIONS (safe to run on top of the schema above, in the same SQL Editor)
--   * location details (building / floor / unit) saved in the profile and copied into alerts
--   * NFC card on/off, enforced here (the app cannot bypass it)
--   * agreeing to the Terms is REQUIRED to create an account and is recorded with a version
--   * feedback & complaints with admin review (admin = profiles.is_admin, set by you in SQL:
--       update public.profiles set is_admin = true where email = 'you@example.com';)
-- ============================================================================
alter table public.profiles
  add column if not exists building text, add column if not exists floor text,
  add column if not exists unit text, add column if not exists details text,
  add column if not exists nfc_active boolean not null default true,
  add column if not exists terms_version text, add column if not exists terms_accepted_at timestamptz,
  add column if not exists is_admin boolean not null default false;
alter table public.sos_alerts
  add column if not exists building text, add column if not exists floor text,
  add column if not exists unit text, add column if not exists details text,
  add column if not exists source text not null default 'button';

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.raw_user_meta_data->>'terms_version', '') = '' then
    raise exception 'You must agree to the Terms and Conditions to register';
  end if;
  insert into public.profiles (id, display_name, email, terms_version, terms_accepted_at)
  values (new.id,
          coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), split_part(new.email, '@', 1)),
          lower(new.email), new.raw_user_meta_data->>'terms_version', now())
  on conflict (id) do nothing;
  return new;
end $$;

create or replace function public.get_my_profile()
returns table (display_name text, email text, building text, floor text, unit text, details text, nfc_active boolean, is_admin boolean)
language sql security definer set search_path = public stable as $$
  select p.display_name, p.email, p.building, p.floor, p.unit, p.details, p.nfc_active, p.is_admin
  from public.profiles p where p.id = auth.uid();
$$;

create or replace function public.save_my_profile(p_building text, p_floor text, p_unit text, p_details text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if length(coalesce(p_building,'')) > 120 or length(coalesce(p_floor,'')) > 20
     or length(coalesce(p_unit,'')) > 40 or length(coalesce(p_details,'')) > 300 then
    raise exception 'a field is too long';
  end if;
  update public.profiles set building = nullif(trim(p_building),''), floor = nullif(trim(p_floor),''),
         unit = nullif(trim(p_unit),''), details = nullif(trim(p_details),'') where id = auth.uid();
  return found;
end $$;

create or replace function public.set_nfc_active(p_active boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update public.profiles set nfc_active = coalesce(p_active, true) where id = auth.uid();
  return found;
end $$;

-- a card tap asks the server first; a disabled card is refused here
create or replace function public.nfc_scan() returns text
language plpgsql security definer set search_path = public stable as $$
declare a boolean;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select nfc_active into a from public.profiles where id = auth.uid();
  return case when a then 'ok' else 'disabled' end;
end $$;

drop function if exists public.start_sos(double precision, double precision, real, boolean);
create or replace function public.start_sos(p_lat double precision, p_lon double precision, p_acc real, p_confirmed boolean, p_source text default 'button')
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); new_id uuid; n int; pr public.profiles;
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into pr from public.profiles where id = me;
  if p_source = 'nfc' and not pr.nfc_active then raise exception 'NFC card is disabled'; end if;
  update public.sos_alerts set active = false, ended_at = now() where user_id = me and active;
  insert into public.sos_alerts (user_id, lat, lon, accuracy, confirmed, building, floor, unit, details, source)
  values (me, p_lat, p_lon, p_acc, coalesce(p_confirmed, false), pr.building, pr.floor, pr.unit, pr.details,
          case when p_source = 'nfc' then 'nfc' else 'button' end) returning id into new_id;
  select count(*) into n from public.contacts c where c.status = 'accepted' and me in (c.requester, c.addressee);
  return json_build_object('id', new_id, 'notified', n);
end $$;

drop function if exists public.list_visible_sos();
create or replace function public.list_visible_sos()
returns table (id uuid, kind text, name text, lat double precision, lon double precision,
               accuracy real, confirmed boolean, started_at timestamptz, updated_at timestamptz,
               building text, floor text, unit text, details text)
language sql security definer set search_path = public stable as $$
  select a.id,
         case when ct.id is not null then 'contact' else 'public' end,
         case when ct.id is not null then p.display_name end,
         case when a.lat is null then null when ct.id is not null then a.lat
              else ((round((a.lat / 0.002)::numeric) * 0.002)::double precision) end,
         case when a.lon is null then null when ct.id is not null then a.lon
              else ((round((a.lon / 0.002)::numeric) * 0.002)::double precision) end,
         case when ct.id is not null then a.accuracy end,
         case when ct.id is not null then a.confirmed end,
         a.started_at, a.updated_at,
         case when ct.id is not null then a.building end, case when ct.id is not null then a.floor end,
         case when ct.id is not null then a.unit end,     case when ct.id is not null then a.details end
  from public.sos_alerts a
  join public.profiles p on p.id = a.user_id
  left join public.contacts ct on ct.status = 'accepted'
        and ((ct.requester = auth.uid() and ct.addressee = a.user_id) or (ct.addressee = auth.uid() and ct.requester = a.user_id))
  where auth.uid() is not null and a.active and a.updated_at > now() - interval '2 hours' and a.user_id <> auth.uid()
  order by a.started_at desc;
$$;

create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  category text not null check (category in ('feedback','complaint','technical','suggestion')),
  message text not null check (length(message) between 5 and 2000),
  status text not null default 'new' check (status in ('new','in_review','resolved')),
  created_at timestamptz not null default now()
);
alter table public.feedback enable row level security;   -- no direct policies: access only through the functions below

create or replace function public.submit_feedback(p_category text, p_message text) returns uuid
language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into public.feedback (user_id, category, message) values (auth.uid(), p_category, trim(p_message)) returning id into new_id;
  return new_id;
end $$;

create or replace function public.list_feedback()
returns table (id uuid, category text, message text, status text, created_at timestamptz, author text, mine boolean)
language sql security definer set search_path = public stable as $$
  select f.id, f.category, f.message, f.status, f.created_at,
         case when (select is_admin from public.profiles where id = auth.uid()) then p.display_name || ' <' || p.email || '>' end,
         f.user_id = auth.uid()
  from public.feedback f join public.profiles p on p.id = f.user_id
  where auth.uid() is not null
    and (f.user_id = auth.uid() or (select is_admin from public.profiles where id = auth.uid()))
  order by f.created_at desc limit 200;
$$;

create or replace function public.set_feedback_status(p_id uuid, p_status text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce((select is_admin from public.profiles where id = auth.uid()), false) then raise exception 'admins only'; end if;
  update public.feedback set status = p_status where id = p_id;
  return found;
end $$;

do $$ declare f text; begin
  foreach f in array array[
    'public.get_my_profile()', 'public.save_my_profile(text,text,text,text)', 'public.set_nfc_active(boolean)', 'public.nfc_scan()',
    'public.start_sos(double precision,double precision,real,boolean,text)', 'public.list_visible_sos()',
    'public.submit_feedback(text,text)', 'public.list_feedback()', 'public.set_feedback_status(uuid,text)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
