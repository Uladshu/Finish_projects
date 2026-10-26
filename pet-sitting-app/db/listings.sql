-- ZooДом — объявления «Ищу присмотр» / «Могу присмотреть», отклики, торг и договорённости
-- (модель BlaBlaCar). Применять после schema.sql и social.sql. См. docs/11-core-product.md

-- ---------- Профиль: «Мой дом» и надёжность ----------

alter table profiles
  add column home_kind          home_type,
  add column has_garden         boolean,
  add column has_children       boolean,
  add column has_other_pets     boolean,
  add column smoking_home       boolean,
  add column sofa_allowed       boolean,
  add column someone_home_daytime boolean,
  add column completed_agreements int not null default 0,
  add column late_cancellations int not null default 0,
  add column rating_avg         numeric(3,2) not null default 0,
  add column rating_count       int not null default 0;

-- Уровень как у BlaBlaCar: считается из опыта, рейтинга и проверки
create or replace function profile_level(p profiles) returns text
language sql stable as $$
  select case
    when p.completed_agreements >= 20 and p.rating_avg >= 4.8 and p.late_cancellations = 0 then 'super_sitter'
    when p.completed_agreements >= 5  and p.rating_avg >= 4.5 then 'experienced'
    when p.phone_verified and p.completed_agreements >= 1 then 'verified'
    else 'newcomer'
  end;
$$;

-- Телефон и точная геопозиция дома не должны читаться напрямую (только через get_contact после договорённости).
-- В Supabase роли anon / authenticated существуют; выдаём доступ только к публичным колонкам.
revoke select on profiles from anon, authenticated;
grant select (id, full_name, avatar_url, city_id, is_sitter, created_at, map_visibility,
              home_kind, has_garden, has_children, has_other_pets, smoking_home, sofa_allowed,
              someone_home_daytime, completed_agreements, late_cancellations, rating_avg, rating_count,
              phone_verified)
  on profiles to anon, authenticated;

-- ---------- Объявления ----------

create type listing_kind   as enum ('need_care', 'offer_care');       -- «Ищу присмотр» / «Могу присмотреть»
create type price_type     as enum ('fixed', 'negotiable', 'free', 'exchange');
create type listing_status as enum ('open', 'agreed', 'closed', 'expired');
create type payment_method as enum ('cash', 'blik', 'bank_transfer', 'free', 'points', 'in_app');

create table listings (
  id             uuid primary key default gen_random_uuid(),
  author_id      uuid not null references profiles(id) on delete cascade,
  kind           listing_kind not null,
  services       service_type[] not null check (cardinality(services) > 0),
  species        pet_species[] not null check (cardinality(species) > 0), -- need_care: виды питомцев; offer_care: кого готов взять
  max_pets       int not null default 1 check (max_pets between 1 and 20),
  period         tstzrange not null,
  is_recurring   boolean not null default false,
  recurrence     text,                                   -- «будни 13:00», «по выходным»
  area           geography(point, 4326) not null,        -- огрублённая точка (fuzz_point), не адрес
  radius_km      numeric(4,1) not null default 2 check (radius_km between 0.2 and 50),
  title          text not null check (length(title) between 5 and 120),
  description    text,
  price_type     price_type not null,
  price          numeric(10,2) check (price >= 0),
  price_unit     price_unit,
  currency       char(3) not null default 'PLN',
  instant_confirm boolean not null default false,        -- «Сразу подтвердить» (только опытным)
  status         listing_status not null default 'open',
  created_at     timestamptz not null default now(),
  check ((price_type = 'fixed' and price is not null and price_unit is not null)
      or (price_type = 'negotiable')
      or (price_type in ('free', 'exchange') and coalesce(price, 0) = 0))
);
create index listings_open_area_idx   on listings using gist (area) where status = 'open';
create index listings_open_period_idx on listings using gist (period) where status = 'open';

create table listing_pets (
  listing_id uuid not null references listings(id) on delete cascade,
  pet_id     uuid not null references pets(id) on delete cascade,
  primary key (listing_id, pet_id)
);

-- ---------- Отклики и торг ----------

create table listing_responses (
  id            uuid primary key default gen_random_uuid(),
  listing_id    uuid not null references listings(id) on delete cascade,
  responder_id  uuid not null references profiles(id) on delete cascade,
  message       text,
  status        text not null default 'pending'
                check (status in ('pending', 'agreed', 'declined', 'withdrawn')),
  created_at    timestamptz not null default now(),
  unique (listing_id, responder_id)
);

-- Каждое предложение цены — отдельная строка; не более 3 предложений от каждой стороны
create table price_offers (
  id           uuid primary key default gen_random_uuid(),
  response_id  uuid not null references listing_responses(id) on delete cascade,
  from_user    uuid not null references profiles(id),
  price        numeric(10,2) not null check (price >= 0),
  price_unit   price_unit not null,
  created_at   timestamptz not null default now()
);

create or replace function make_price_offer(p_response_id uuid, p_price numeric, p_unit price_unit)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_author uuid; v_responder uuid; v_count int; v_id uuid;
begin
  select l.author_id, r.responder_id into v_author, v_responder
  from listing_responses r join listings l on l.id = r.listing_id
  where r.id = p_response_id and r.status = 'pending' and l.status = 'open';
  if not found or auth.uid() not in (v_author, v_responder) then
    raise exception 'response not available';
  end if;
  select count(*) into v_count from price_offers where response_id = p_response_id and from_user = auth.uid();
  if v_count >= 3 then
    raise exception 'offer limit reached (3 per side)';
  end if;
  insert into price_offers (response_id, from_user, price, price_unit)
  values (p_response_id, auth.uid(), p_price, p_unit) returning id into v_id;
  return v_id;
end;
$$;

-- ---------- Договорённости (на базе bookings) ----------

alter table bookings
  add column listing_id       uuid references listings(id),
  add column response_id      uuid references listing_responses(id),
  add column price_type       price_type,
  add column payment_method   payment_method,
  add column proposed_by      uuid references profiles(id),
  add column owner_confirmed_at  timestamptz,
  add column sitter_confirmed_at timestamptz;

-- Одна сторона предлагает договорённость (карточку): цена, даты, способ оплаты
create or replace function propose_agreement(
  p_response_id uuid, p_period tstzrange, p_price numeric, p_payment payment_method
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  l listings; r listing_responses; v_owner uuid; v_sitter uuid; v_id uuid; v_service service_type;
begin
  select * into r from listing_responses where id = p_response_id and status = 'pending';
  select * into l from listings where id = r.listing_id and status = 'open';
  if r.id is null or l.id is null or auth.uid() not in (l.author_id, r.responder_id) then
    raise exception 'response not available';
  end if;

  if l.kind = 'need_care' then v_owner := l.author_id;   v_sitter := r.responder_id;
                          else v_owner := r.responder_id; v_sitter := l.author_id; end if;
  v_service := l.services[1];

  insert into bookings (owner_id, sitter_id, service, period, status, price_total, currency,
                        mode, listing_id, response_id, price_type, payment_method, proposed_by,
                        owner_confirmed_at, sitter_confirmed_at)
  values (v_owner, v_sitter, v_service, p_period, 'requested', p_price, l.currency,
          case when l.price_type = 'exchange' then 'neighbor_exchange'::booking_mode
               when l.price_type = 'free' or p_payment = 'free' then 'friend_of_dog'::booking_mode
               else 'paid'::booking_mode end,
          l.id, r.id, l.price_type, p_payment, auth.uid(),
          case when auth.uid() = v_owner  then now() end,
          case when auth.uid() = v_sitter then now() end)
  returning id into v_id;

  if l.kind = 'need_care' then
    insert into booking_pets (booking_id, pet_id) select v_id, pet_id from listing_pets where listing_id = l.id;
  end if;
  return v_id;
end;
$$;

-- Вторая сторона подтверждает → договорённость заключена, объявление закрыто, остальным откликам отказ
create or replace function confirm_agreement(p_booking_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking_id and status = 'requested';
  if b.id is null or auth.uid() not in (b.owner_id, b.sitter_id) or auth.uid() = b.proposed_by then
    raise exception 'agreement not available';
  end if;

  update bookings set
    status = 'accepted',
    owner_confirmed_at  = coalesce(owner_confirmed_at,  case when auth.uid() = owner_id  then now() end),
    sitter_confirmed_at = coalesce(sitter_confirmed_at, case when auth.uid() = sitter_id then now() end),
    updated_at = now()
  where id = p_booking_id;

  update listing_responses set status = 'agreed' where id = b.response_id;
  update listing_responses set status = 'declined' where listing_id = b.listing_id and id <> b.response_id and status = 'pending';
  update listings set status = 'agreed' where id = b.listing_id and not is_recurring;
end;
$$;

-- Контакты открываются только сторонам подтверждённой договорённости
create or replace function get_contact(p_booking_id uuid)
returns table (user_id uuid, full_name text, phone text)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.full_name, pr.phone
  from bookings b
  join profiles pr on pr.id = case when auth.uid() = b.owner_id then b.sitter_id else b.owner_id end
  where b.id = p_booking_id
    and auth.uid() in (b.owner_id, b.sitter_id)
    and b.status in ('accepted', 'in_progress', 'completed');
$$;

-- ---------- Поиск объявлений ----------

create or replace function search_listings(
  p_kind        listing_kind,
  p_lat         double precision,
  p_lng         double precision,
  p_radius_km   numeric default 3,
  p_start       timestamptz default null,
  p_end         timestamptz default null,
  p_species     pet_species default null,
  p_free_only   boolean default false,
  p_max_price   numeric default null,
  p_limit       int default 50
)
returns table (
  listing_id   uuid,
  author_id    uuid,
  author_name  text,
  author_level text,
  rating_avg   numeric,
  title        text,
  services     service_type[],
  species      pet_species[],
  period       tstzrange,
  price_type   price_type,
  price        numeric,
  price_unit   price_unit,
  currency     char(3),
  distance_km  numeric,
  is_friend    boolean
)
language sql stable security definer set search_path = public as $$
  with origin as (select st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography as g)
  select
    l.id, l.author_id, pr.full_name, profile_level(pr), pr.rating_avg,
    l.title, l.services, l.species, l.period, l.price_type, l.price, l.price_unit, l.currency,
    round((st_distance(l.area, o.g) / 1000)::numeric, 1),
    coalesce(are_friends(l.author_id, auth.uid()), false)
  from listings l
  join profiles pr on pr.id = l.author_id and not pr.is_blocked
  cross join origin o
  where l.status = 'open'
    and l.kind = p_kind
    and upper(l.period) > now()
    and st_dwithin(l.area, o.g, (p_radius_km + l.radius_km) * 1000)
    and (p_species is null or p_species = any (l.species))
    and (p_start is null or p_end is null or
         (case when l.kind = 'offer_care'
               then l.period @> tstzrange(p_start, p_end)     -- ситтер свободен на все нужные даты
               else l.period && tstzrange(p_start, p_end) end))
    and (not p_free_only or l.price_type in ('free', 'exchange'))
    and (p_max_price is null or l.price_type in ('free', 'exchange', 'negotiable') or l.price <= p_max_price)
    and (auth.uid() is null or l.author_id <> auth.uid())
  -- друзья и знакомые выше, затем ближе, затем рейтинг
  order by coalesce(are_friends(l.author_id, auth.uid()), false) desc,
           st_distance(l.area, o.g) asc,
           pr.rating_avg desc
  limit p_limit;
$$;

-- Подсказка цены: медиана платных договорённостей рядом за 180 дней
create or replace function price_hint(
  p_lat double precision, p_lng double precision, p_service service_type, p_species pet_species,
  p_radius_km numeric default 5
) returns table (p25 numeric, median numeric, p75 numeric, samples int)
language sql stable security definer set search_path = public as $$
  select
    percentile_cont(0.25) within group (order by b.price_total)::numeric,
    percentile_cont(0.5)  within group (order by b.price_total)::numeric,
    percentile_cont(0.75) within group (order by b.price_total)::numeric,
    count(*)::int
  from bookings b
  join listings l on l.id = b.listing_id
  where b.status in ('accepted', 'in_progress', 'completed')
    and b.mode = 'paid' and b.price_total > 0
    and b.service = p_service
    and p_species = any (l.species)
    and b.created_at > now() - interval '180 days'
    and st_dwithin(l.area, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_km * 1000);
$$;

-- Кому отправить push «рядом подходящее объявление»: авторы встречных открытых объявлений
create or replace function matching_users_for_listing(p_listing_id uuid)
returns table (user_id uuid, matching_listing_id uuid)
language sql stable security definer set search_path = public as $$
  select m.author_id, m.id
  from listings l
  join listings m on m.kind <> l.kind and m.status = 'open' and m.author_id <> l.author_id
  where l.id = p_listing_id
    and m.species && l.species
    and m.services && l.services
    and m.period && l.period
    and st_dwithin(m.area, l.area, (m.radius_km + l.radius_km) * 1000);
$$;

-- ---------- Row Level Security ----------

alter table listings          enable row level security;
alter table listing_pets      enable row level security;
alter table listing_responses enable row level security;
alter table price_offers      enable row level security;

create policy "listings: read open or own" on listings for select using (status = 'open' or author_id = auth.uid());
create policy "listings: author manages"   on listings for all using (author_id = auth.uid()) with check (author_id = auth.uid());

create policy "listing_pets: read"         on listing_pets for select using (true);
create policy "listing_pets: author"       on listing_pets for all
  using (exists (select 1 from listings l where l.id = listing_id and l.author_id = auth.uid()));

create policy "responses: parties read"    on listing_responses for select using (
  responder_id = auth.uid() or exists (select 1 from listings l where l.id = listing_id and l.author_id = auth.uid()));
create policy "responses: respond"         on listing_responses for insert with check (
  responder_id = auth.uid() and exists (select 1 from listings l where l.id = listing_id
                                        and l.status = 'open' and l.author_id <> auth.uid()));
create policy "responses: withdraw own"    on listing_responses for update using (responder_id = auth.uid());

create policy "offers: parties read"       on price_offers for select using (
  exists (select 1 from listing_responses r join listings l on l.id = r.listing_id
          where r.id = response_id and auth.uid() in (r.responder_id, l.author_id)));
-- новые предложения цены — только через make_price_offer()
