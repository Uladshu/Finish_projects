-- ZooДом — стартовая схема БД (PostgreSQL 15+ / Supabase, PostGIS)
-- Рассчитана на Supabase: таблица auth.users создаётся самим Supabase Auth.

create extension if not exists postgis;
create extension if not exists pgcrypto;
create extension if not exists btree_gist;   -- gist-индексы по (uuid, range)

-- ---------- Справочники ----------

create type pet_species     as enum ('dog', 'cat', 'rabbit', 'rodent', 'ferret', 'bird',
                                     'reptile', 'amphibian', 'fish', 'other');
create type pet_size        as enum ('xs', 's', 'm', 'l', 'xl');           -- до 3 / 3–10 / 10–25 / 25–45 / 45+ кг
create type service_type    as enum ('boarding', 'house_sitting', 'drop_in', 'walking', 'day_care');
create type price_unit      as enum ('night', 'day', 'visit', 'walk');
create type booking_status  as enum ('requested', 'accepted', 'declined', 'in_progress',
                                     'completed', 'cancelled_by_owner', 'cancelled_by_sitter', 'disputed');
create type verification_status as enum ('none', 'pending', 'approved', 'rejected');
create type home_type       as enum ('apartment', 'house', 'house_with_yard');

create table cities (
  id          serial primary key,
  name        text not null,
  country     char(2) not null,                -- 'RU', 'BY', 'KZ'
  currency    char(3) not null,                -- 'RUB', 'BYN', 'KZT'
  timezone    text not null,                   -- 'Europe/Minsk'
  center      geography(point, 4326) not null,
  is_active   boolean not null default false
);

-- ---------- Пользователи ----------

create table profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  full_name     text not null,
  avatar_url    text,
  phone         text unique,
  city_id       int references cities(id),
  is_sitter     boolean not null default false,
  is_admin      boolean not null default false,
  is_blocked    boolean not null default false,
  created_at    timestamptz not null default now()
);

create table pets (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references profiles(id) on delete cascade,
  name          text not null,
  species       pet_species not null,
  breed         text,
  birth_date    date,
  weight_kg     numeric(5,2),
  size          pet_size,
  sex           char(1) check (sex in ('m', 'f')),
  is_neutered   boolean,
  temperament   text,                          -- характер, страхи, отношение к другим животным
  medical_notes text,                          -- лекарства, аллергии, хронические болезни
  vet_contact   text,
  vaccinated    boolean not null default false,
  photo_urls    text[] not null default '{}',
  created_at    timestamptz not null default now()
);

create table sitter_profiles (
  user_id             uuid primary key references profiles(id) on delete cascade,
  headline            text not null,
  about               text,
  experience_years    int check (experience_years >= 0),
  home                home_type,
  has_children        boolean,
  has_own_pets        boolean,
  own_pets_note       text,
  accepts_species     pet_species[] not null default '{dog,cat}',
  accepts_sizes       pet_size[]    not null default '{xs,s,m,l,xl}',
  max_pets            int not null default 1 check (max_pets between 1 and 10),
  -- точный адрес не публикуется; в поиске показываем approx_location
  location            geography(point, 4326) not null,
  approx_location     geography(point, 4326) not null,
  service_radius_km   numeric(4,1) not null default 5,
  photo_urls          text[] not null default '{}',
  verification        verification_status not null default 'none',
  is_founder          boolean not null default false,   -- первые 500 ситтеров
  is_listed           boolean not null default false,   -- анкета прошла модерацию
  rating_avg          numeric(3,2) not null default 0,
  rating_count        int not null default 0,
  completed_bookings  int not null default 0,
  response_minutes_median int,
  created_at          timestamptz not null default now()
);
create index sitter_profiles_approx_location_idx on sitter_profiles using gist (approx_location);

create table sitter_services (
  id          uuid primary key default gen_random_uuid(),
  sitter_id   uuid not null references sitter_profiles(user_id) on delete cascade,
  service     service_type not null,
  price       numeric(10,2) not null check (price >= 0),
  unit        price_unit not null,
  currency    char(3) not null,
  is_active   boolean not null default true,
  unique (sitter_id, service)
);

-- Даты, когда ситтер НЕ доступен (по умолчанию доступен всегда)
create table availability_blocks (
  id          uuid primary key default gen_random_uuid(),
  sitter_id   uuid not null references sitter_profiles(user_id) on delete cascade,
  period      daterange not null,
  reason      text
);
create index availability_blocks_period_idx on availability_blocks using gist (sitter_id, period);

-- ---------- Бронирования ----------

create table bookings (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references profiles(id),
  sitter_id     uuid not null references profiles(id),          -- любой пользователь: ситтер, сосед, «друг животных»
  service       service_type not null,
  period        tstzrange not null,
  status        booking_status not null default 'requested',
  price_total   numeric(10,2),                 -- договорная сумма (на бесплатном этапе — справочно)
  currency      char(3) not null,
  owner_note    text,
  paid_in_app   boolean not null default false,  -- этап 2: безопасная сделка
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (owner_id <> sitter_id)
);
create index bookings_sitter_period_idx on bookings using gist (sitter_id, period);
create index bookings_owner_idx on bookings (owner_id, created_at desc);

create table booking_pets (
  booking_id  uuid not null references bookings(id) on delete cascade,
  pet_id      uuid not null references pets(id),
  primary key (booking_id, pet_id)
);

-- Ежедневные фото-/видеоотчёты ситтера
create table booking_updates (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references bookings(id) on delete cascade,
  author_id   uuid not null references profiles(id),
  media_urls  text[] not null default '{}',
  fed         boolean,
  walked      boolean,
  mood        smallint check (mood between 1 and 5),
  note        text,
  created_at  timestamptz not null default now()
);

-- ---------- Чат ----------

create table conversations (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references profiles(id),
  sitter_id   uuid not null references profiles(id),
  booking_id  uuid references bookings(id),
  last_message_at timestamptz,
  created_at  timestamptz not null default now(),
  unique (owner_id, sitter_id)
);

create table messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id       uuid not null references profiles(id),
  body            text,
  media_urls      text[] not null default '{}',
  read_at         timestamptz,
  created_at      timestamptz not null default now(),
  check (body is not null or cardinality(media_urls) > 0)
);
create index messages_conversation_idx on messages (conversation_id, created_at);

-- ---------- Отзывы, верификация, жалобы ----------

create table reviews (
  id            uuid primary key default gen_random_uuid(),
  booking_id    uuid not null references bookings(id) on delete cascade,
  author_id     uuid not null references profiles(id),
  target_id     uuid not null references profiles(id),
  rating        smallint not null check (rating between 1 and 5),
  body          text,
  is_published  boolean not null default false,   -- публикуются одновременно или через 14 дней
  created_at    timestamptz not null default now(),
  unique (booking_id, author_id)
);
create index reviews_target_idx on reviews (target_id) where is_published;

create table verifications (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references profiles(id) on delete cascade,
  document_path text,              -- приватный бакет; удаляется после проверки
  selfie_path   text,
  status        verification_status not null default 'pending',
  reviewer_id   uuid references profiles(id),
  comment       text,
  created_at    timestamptz not null default now(),
  reviewed_at   timestamptz
);

create table reports (
  id            uuid primary key default gen_random_uuid(),
  reporter_id   uuid not null references profiles(id),
  target_user_id uuid references profiles(id),
  booking_id    uuid references bookings(id),
  message_id    uuid references messages(id),
  reason        text not null,
  status        text not null default 'open' check (status in ('open', 'in_review', 'resolved', 'rejected')),
  created_at    timestamptz not null default now()
);

create table devices (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  platform    text not null check (platform in ('ios', 'android', 'web')),
  push_token  text not null unique,
  created_at  timestamptz not null default now()
);

-- ---------- Поиск ситтеров ----------

create or replace function search_sitters(
  p_lat        double precision,
  p_lng        double precision,
  p_radius_km  numeric,
  p_service    service_type,
  p_start      date,
  p_end        date,
  p_species    pet_species default null,
  p_size       pet_size    default null,
  p_limit      int         default 50
)
returns table (
  sitter_id     uuid,
  full_name     text,
  headline      text,
  distance_km   numeric,
  price         numeric,
  unit          price_unit,
  currency      char(3),
  rating_avg    numeric,
  rating_count  int,
  verification  verification_status,
  score         numeric
)
language sql stable as $$
  with origin as (
    select st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography as g
  )
  select
    sp.user_id,
    pr.full_name,
    sp.headline,
    round((st_distance(sp.approx_location, o.g) / 1000)::numeric, 1) as distance_km,
    ss.price, ss.unit, ss.currency,
    sp.rating_avg, sp.rating_count, sp.verification,
    round((
        0.35 * (1 - least(st_distance(sp.approx_location, o.g) / 1000 / p_radius_km, 1))
      + 0.25 * (sp.rating_avg / 5)
      + 0.15 * least(sp.completed_bookings / 20.0, 1)
      + 0.10 * (1 - least(coalesce(sp.response_minutes_median, 240) / 240.0, 1))
      + 0.10 * (case when sp.verification = 'approved' then 1 else 0 end)
      + 0.05 * (case when sp.created_at > now() - interval '30 days' then 1 else 0 end)
    )::numeric, 4) as score
  from sitter_profiles sp
  join profiles pr       on pr.id = sp.user_id and not pr.is_blocked
  join sitter_services ss on ss.sitter_id = sp.user_id and ss.service = p_service and ss.is_active
  cross join origin o
  where sp.is_listed
    and st_dwithin(sp.approx_location, o.g, p_radius_km * 1000)
    and (p_species is null or p_species = any (sp.accepts_species))
    and (p_size    is null or p_size    = any (sp.accepts_sizes))
    and not exists (
      select 1 from availability_blocks ab
      where ab.sitter_id = sp.user_id
        and ab.period && daterange(p_start, p_end, '[]')
    )
    and (
      select count(*) from bookings b
      where b.sitter_id = sp.user_id
        and b.status in ('accepted', 'in_progress')
        and b.period && tstzrange(p_start::timestamptz, (p_end + 1)::timestamptz)
    ) < sp.max_pets
  order by score desc
  limit p_limit;
$$;

-- ---------- Row Level Security (базовые политики) ----------

alter table profiles        enable row level security;
alter table pets            enable row level security;
alter table sitter_profiles enable row level security;
alter table sitter_services enable row level security;
alter table bookings        enable row level security;
alter table messages        enable row level security;
alter table conversations   enable row level security;
alter table verifications   enable row level security;

create policy "profiles: read all"          on profiles for select using (true);
create policy "profiles: update self"       on profiles for update using (auth.uid() = id);

create policy "pets: owner full access"     on pets for all using (auth.uid() = owner_id);

create policy "sitters: read listed"        on sitter_profiles for select using (is_listed or auth.uid() = user_id);
create policy "sitters: manage self"        on sitter_profiles for all using (auth.uid() = user_id);

create policy "services: read all"          on sitter_services for select using (true);
create policy "services: manage self"       on sitter_services for all using (auth.uid() = sitter_id);

create policy "bookings: participants"      on bookings for select using (auth.uid() in (owner_id, sitter_id));
create policy "bookings: owner creates"     on bookings for insert with check (auth.uid() = owner_id);
create policy "bookings: participants upd"  on bookings for update using (auth.uid() in (owner_id, sitter_id));

create policy "conversations: participants" on conversations for select using (auth.uid() in (owner_id, sitter_id));
create policy "messages: participants read" on messages for select using (
  exists (select 1 from conversations c
          where c.id = conversation_id and auth.uid() in (c.owner_id, c.sitter_id)));
create policy "messages: participants send" on messages for insert with check (
  sender_id = auth.uid() and exists (select 1 from conversations c
          where c.id = conversation_id and auth.uid() in (c.owner_id, c.sitter_id)));

create policy "verifications: own"          on verifications for select using (auth.uid() = user_id);
create policy "verifications: submit own"   on verifications for insert with check (auth.uid() = user_id);
