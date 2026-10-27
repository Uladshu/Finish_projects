# Карта базы данных

Читать этот файл вместо SQL. Нужен код — `grep -n "<имя>" db/*.sql`, затем читать только найденный кусок.
Порядок применения: `schema.sql` → `social.sql` → `listings.sql`. Проверено на PostgreSQL 16 + PostGIS.
Тестовый запуск: Supabase-заглушки `auth.users`, `auth.uid()` (через `current_setting('test.uid')`), роли `anon`/`authenticated`.

| Файл | Объекты | Назначение |
|---|---|---|
| `schema.sql` | типы `pet_species` (10 видов), `pet_size`, `service_type`, `price_unit`, `booking_status`, `verification_status`, `home_type`; таблицы `cities`, `profiles`, `pets`, `sitter_profiles`, `sitter_services`, `availability_blocks`, `bookings`, `booking_pets`, `booking_updates`, `conversations`, `messages`, `reviews`, `verifications`, `reports`, `devices`; функция `search_sitters()` | Ядро: пользователи, питомцы, ситтеры, бронирования, чат, отзывы, RLS |
| `social.sql` | `pets` +совместимость; `profiles` +`home_location`, приватность; `friendships`, `are_friends()`; `walks`, `walk_pets`, `walk_participants`, `walk_live_positions`, `fuzz_point()`, `update_walk_position()`, `end_walk()`, `expire_walks()`, `nearby_live_walks()`; `places`; `hazard_reports`, `hazard_confirmations`; `lost_found_alerts`, `users_to_notify()`; `help_points_ledger`, `help_points_balance`; `bookings.mode` | Соцсеть, живая карта с приватностью, опасности, потерялся/нашёлся, баллы |
| `listings.sql` | `profiles` +«Мой дом», надёжность, скрытие `phone`/`home_location` через column grants; `profile_level()`; `listings`, `listing_pets`, `listing_responses`, `price_offers`, `make_price_offer()`; `bookings` +поля договорённости; `propose_agreement()`, `confirm_agreement()`, `get_contact()`, `search_listings()`, `price_hint()`, `matching_users_for_listing()` | Присмотр по модели BlaBlaCar |

| `survey.sql` | `survey_answers(respondent_id, question_id, answer jsonb, lang)` + RLS: аноним только вставляет/обновляет | Ответы мини-опроса |

## Чего ещё нет (нужно для соцсети-первой версии)
- Группы и участники, посты ленты (вопрос / помощь / отдам / фото), комментарии, реакции.
- Генерация плакатов о потере (PDF + QR).
- Жизненный цикл: у объявлений `confirmed_at`, `poll_sent_at`, `status` (active/asked/expired/closed) + задача раз в час (pg_cron); таблица `found_claims(post_id, finder_id, note, status)` — закрытие только владельцем.
- Медали `achievements(user_id, medal, earned_at)`; расширить `help_points_ledger.reason` (см. features/gamification.md).
- Журналы ухода (аквариум: параметры воды; рептилии: кормление, линька).
