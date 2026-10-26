-- ZooДом — соцсеть владельцев собак (применять после schema.sql)
-- Прогулки и живая карта, групповые прогулки, друзья, опасности, места, потерявшиеся питомцы,
-- баллы соседской помощи. См. docs/10-dog-owners-social-network.md

-- ---------- Профиль собаки: совместимость ----------

create type energy_level as enum ('low', 'medium', 'high');

alter table pets
  add column energy          energy_level,
  add column good_with_big   boolean,
  add column good_with_small boolean,
  add column good_with_males boolean,
  add column good_with_females boolean,
  add column good_with_cats  boolean,
  add column is_reactive     boolean not null default false,
  add column play_style      text;           -- «мяч», «догонялки», «спокойный»

-- ---------- Приватность пользователя ----------

create type map_visibility as enum ('everyone', 'friends', 'invisible');

alter table profiles
  add column home_location     geography(point, 4326),   -- никогда не отдаётся другим; зона приватности и радиус оповещений
  add column privacy_radius_m  int not null default 300 check (privacy_radius_m between 100 and 1000),
  add column map_visibility    map_visibility not null default 'friends',
  add column is_adult_confirmed boolean not null default false,
  add column phone_verified    boolean not null default false;

-- ---------- Друзья ----------

create table friendships (
  requester_id uuid not null references profiles(id) on delete cascade,
  addressee_id uuid not null references profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'blocked')),
  created_at   timestamptz not null default now(),
  primary key (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);

create or replace function are_friends(a uuid, b uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from friendships f
    where f.status = 'accepted'
      and ((f.requester_id = a and f.addressee_id = b) or (f.requester_id = b and f.addressee_id = a))
  );
$$;

-- ---------- Прогулки ----------

create type walk_kind   as enum ('live', 'group');            -- live: «Я гуляю сейчас»; group: запланированная
create type walk_status as enum ('scheduled', 'active', 'ended', 'cancelled');
create type walk_mood   as enum ('looking_for_company', 'just_walking', 'do_not_approach');

create table walks (
  id             uuid primary key default gen_random_uuid(),
  host_id        uuid not null references profiles(id) on delete cascade,
  kind           walk_kind not null,
  status         walk_status not null,
  mood           walk_mood not null default 'just_walking',
  visibility     map_visibility not null default 'friends',
  title          text,                                  -- для групповых
  description    text,
  meeting_point  geography(point, 4326),                -- для групповых (публичное место, не дом)
  scheduled_at   timestamptz,
  capacity       int check (capacity between 2 and 100),
  size_filter    pet_size[],                            -- «только крупные» и т. п.
  started_at     timestamptz,
  auto_end_at    timestamptz,                           -- live: started_at + 2 часа
  ended_at       timestamptz,
  created_at     timestamptz not null default now(),
  check (kind = 'live' or (meeting_point is not null and scheduled_at is not null))
);
create index walks_active_idx on walks (status) where status = 'active';
create index walks_meeting_point_idx on walks using gist (meeting_point);

create table walk_pets (
  walk_id uuid not null references walks(id) on delete cascade,
  pet_id  uuid not null references pets(id) on delete cascade,
  primary key (walk_id, pet_id)
);

create table walk_participants (
  walk_id    uuid not null references walks(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  status     text not null default 'requested' check (status in ('requested', 'accepted', 'declined', 'left')),
  created_at timestamptz not null default now(),
  primary key (walk_id, user_id)
);

-- Только ПОСЛЕДНЯЯ огрублённая точка активной прогулки. Истории маршрута нет.
create table walk_live_positions (
  walk_id     uuid primary key references walks(id) on delete cascade,
  position    geography(point, 4326),     -- null = пользователь в зоне приватности (не показывать)
  updated_at  timestamptz not null default now()
);
create index walk_live_positions_idx on walk_live_positions using gist (position);

-- Огрубление координат до сетки ~200 м
create or replace function fuzz_point(p_lat double precision, p_lng double precision)
returns geography language sql immutable as $$
  select st_setsrid(st_makepoint(round(p_lng / 0.003) * 0.003, round(p_lat / 0.002) * 0.002), 4326)::geography;
$$;

-- Клиент присылает точную позицию; в БД попадает только огрублённая и только вне зоны приватности
create or replace function update_walk_position(p_walk_id uuid, p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_home   geography;
  v_radius int;
begin
  select pr.home_location, pr.privacy_radius_m into v_home, v_radius
  from walks w join profiles pr on pr.id = w.host_id
  where w.id = p_walk_id and w.host_id = auth.uid() and w.status = 'active';
  if not found then
    raise exception 'walk not found or not active';
  end if;

  insert into walk_live_positions (walk_id, position, updated_at)
  values (
    p_walk_id,
    case when v_home is not null
              and st_dwithin(v_home, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, v_radius)
         then null
         else fuzz_point(p_lat, p_lng) end,
    now())
  on conflict (walk_id) do update set position = excluded.position, updated_at = excluded.updated_at;
end;
$$;

-- Завершение прогулки удаляет позицию
create or replace function end_walk(p_walk_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update walks set status = 'ended', ended_at = now()
  where id = p_walk_id and host_id = auth.uid() and status = 'active';
  delete from walk_live_positions where walk_id = p_walk_id;
end;
$$;

-- Плановая задача (pg_cron / Edge Function раз в 5 минут): автоокончание и удаление позиций
create or replace function expire_walks() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with ended as (
    update walks set status = 'ended', ended_at = now()
    where status = 'active' and kind = 'live' and auto_end_at < now()
    returning id
  )
  delete from walk_live_positions wlp using ended where wlp.walk_id = ended.id;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Живая карта: кто сейчас гуляет рядом (с учётом видимости, дружбы, ночного режима, блокировок)
create or replace function nearby_live_walks(
  p_lat double precision, p_lng double precision, p_radius_km numeric default 2
)
returns table (
  walk_id     uuid,
  host_id     uuid,
  host_name   text,
  mood        walk_mood,
  lat         double precision,
  lng         double precision,
  updated_at  timestamptz,
  pets        jsonb
)
language sql stable security definer set search_path = public as $$
  select
    w.id, w.host_id, pr.full_name, w.mood,
    st_y(wlp.position::geometry), st_x(wlp.position::geometry), wlp.updated_at,
    (select jsonb_agg(jsonb_build_object('name', p.name, 'size', p.size, 'energy', p.energy,
                                         'reactive', p.is_reactive, 'photo', p.photo_urls[1]))
       from walk_pets wp join pets p on p.id = wp.pet_id where wp.walk_id = w.id)
  from walks w
  join walk_live_positions wlp on wlp.walk_id = w.id and wlp.position is not null
  join profiles pr on pr.id = w.host_id and not pr.is_blocked
  join profiles me on me.id = auth.uid() and me.phone_verified and me.is_adult_confirmed
  where w.status = 'active'
    and w.kind = 'live'
    and w.host_id <> me.id
    and wlp.updated_at > now() - interval '5 minutes'
    and st_dwithin(wlp.position, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_km * 1000)
    and w.visibility <> 'invisible'
    and not exists (select 1 from friendships f where f.status = 'blocked'
                    and ((f.requester_id = w.host_id and f.addressee_id = me.id)
                      or (f.requester_id = me.id and f.addressee_id = w.host_id)))
    and (
      are_friends(w.host_id, me.id)
      or (w.visibility = 'everyone'
          and extract(hour from now() at time zone 'Europe/Warsaw') between 6 and 21)  -- ночью только друзья
    );
$$;

-- ---------- Места на карте ----------

create type place_type as enum ('dog_park', 'off_leash_area', 'vet', 'vet_24h', 'pet_shop',
                                'groomer', 'dog_friendly_cafe', 'water', 'waste_bin', 'other');

create table places (
  id          uuid primary key default gen_random_uuid(),
  type        place_type not null,
  name        text not null,
  description text,
  location    geography(point, 4326) not null,
  address     text,
  phone       text,
  opening_hours text,
  source      text not null default 'user' check (source in ('user', 'osm', 'city', 'partner')),
  external_id text,                          -- id в OpenStreetMap и т. п.
  created_by  uuid references profiles(id),
  is_verified boolean not null default false,
  is_partner  boolean not null default false, -- платная карточка партнёра (этап 2)
  created_at  timestamptz not null default now()
);
create index places_location_idx on places using gist (location);

-- ---------- Опасности (отрава, стекло, агрессивная собака…) ----------

create type hazard_type as enum ('poison_bait', 'glass', 'aggressive_dog', 'wild_boar', 'ticks', 'other');

create table hazard_reports (
  id            uuid primary key default gen_random_uuid(),
  reporter_id   uuid not null references profiles(id),
  type          hazard_type not null,
  location      geography(point, 4326) not null,
  description   text,
  photo_urls    text[] not null default '{}',
  confirmations int not null default 0,
  status        text not null default 'active' check (status in ('active', 'resolved', 'rejected')),
  expires_at    timestamptz not null default now() + interval '72 hours',  -- продлевается подтверждениями
  reported_to_authorities boolean not null default false,
  created_at    timestamptz not null default now()
);
create index hazard_reports_location_idx on hazard_reports using gist (location) where status = 'active';

create table hazard_confirmations (
  hazard_id  uuid not null references hazard_reports(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  still_there boolean not null,
  created_at timestamptz not null default now(),
  primary key (hazard_id, user_id)
);

-- ---------- Потерялся / нашёлся ----------

create table lost_found_alerts (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null references profiles(id),
  kind        text not null check (kind in ('lost', 'found')),
  pet_id      uuid references pets(id),           -- для lost
  species     pet_species not null,
  description text not null,
  photo_urls  text[] not null default '{}',
  last_seen_location geography(point, 4326) not null,
  last_seen_at timestamptz not null,
  status      text not null default 'active' check (status in ('active', 'reunited', 'closed')),
  created_at  timestamptz not null default now()
);
create index lost_found_alerts_location_idx on lost_found_alerts using gist (last_seen_location) where status = 'active';

-- Кому отправить push о событии в точке (опасность, потерявшаяся собака): по зоне дома
create or replace function users_to_notify(p_lat double precision, p_lng double precision, p_radius_km numeric)
returns table (user_id uuid)
language sql stable security definer set search_path = public as $$
  select pr.id
  from profiles pr
  where pr.home_location is not null
    and not pr.is_blocked
    and st_dwithin(pr.home_location, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_km * 1000);
$$;

-- ---------- Соседская помощь: баллы («лапки») ----------

create table help_points_ledger (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  delta       int not null check (delta <> 0),
  reason      text not null check (reason in ('welcome_bonus', 'helped_neighbor', 'received_help',
                                              'cancellation_penalty', 'hazard_report_confirmed', 'admin_adjustment')),
  booking_id  uuid references bookings(id),
  created_at  timestamptz not null default now()
);
create index help_points_ledger_user_idx on help_points_ledger (user_id);

create view help_points_balance as
  select user_id, sum(delta)::int as balance from help_points_ledger group by user_id;

-- Режимы бесплатной помощи в бронированиях
create type booking_mode as enum ('paid', 'friend_of_dog', 'neighbor_exchange');
alter table bookings add column mode booking_mode not null default 'paid';

-- ---------- Row Level Security ----------

alter table friendships          enable row level security;
alter table walks                enable row level security;
alter table walk_pets            enable row level security;
alter table walk_participants    enable row level security;
alter table walk_live_positions  enable row level security;   -- без политик: доступ только через функции
alter table places               enable row level security;
alter table hazard_reports       enable row level security;
alter table hazard_confirmations enable row level security;
alter table lost_found_alerts    enable row level security;
alter table help_points_ledger   enable row level security;

create policy "friendships: own"         on friendships for all
  using (auth.uid() in (requester_id, addressee_id)) with check (auth.uid() = requester_id);

-- Групповые прогулки видны всем; live-прогулки — только хозяину (остальным — через nearby_live_walks)
create policy "walks: group public or own" on walks for select using (kind = 'group' or host_id = auth.uid());
create policy "walks: host manages"      on walks for all using (host_id = auth.uid()) with check (host_id = auth.uid());
create policy "walk_pets: host manages"  on walk_pets for all
  using (exists (select 1 from walks w where w.id = walk_id and w.host_id = auth.uid()));
create policy "walk_participants: read"  on walk_participants for select
  using (user_id = auth.uid() or exists (select 1 from walks w where w.id = walk_id and w.host_id = auth.uid()));
create policy "walk_participants: join"  on walk_participants for insert with check (user_id = auth.uid());

create policy "places: read all"         on places for select using (true);
create policy "places: add"              on places for insert with check (created_by = auth.uid() and not is_partner);

create policy "hazards: read active"     on hazard_reports for select using (status = 'active' or reporter_id = auth.uid());
create policy "hazards: report"          on hazard_reports for insert with check (reporter_id = auth.uid());
create policy "hazard_conf: add own"     on hazard_confirmations for insert with check (user_id = auth.uid());

create policy "lost_found: read"         on lost_found_alerts for select using (true);
create policy "lost_found: create own"   on lost_found_alerts for insert with check (author_id = auth.uid());
create policy "lost_found: update own"   on lost_found_alerts for update using (author_id = auth.uid());

create policy "points: read own"         on help_points_ledger for select using (user_id = auth.uid());
-- начисление баллов — только серверными функциями (service role)
