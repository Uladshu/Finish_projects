-- Pupil Obok — ответы мини-опроса (Supabase). Анонимные посетители могут только добавлять/обновлять свой ответ.
create table if not exists survey_answers (
  respondent_id text not null,          -- случайный id из браузера
  question_id   text not null,          -- id из SURVEY_POOL
  answer        jsonb,                  -- строка, число, массив или null (пропуск)
  lang          text,
  created_at    timestamptz not null default now(),
  primary key (respondent_id, question_id)
);
alter table survey_answers enable row level security;
create policy "survey: anon insert" on survey_answers for insert to anon with check (length(respondent_id) between 8 and 64);
create policy "survey: anon upsert" on survey_answers for update to anon using (true) with check (true);
-- чтение — только через service role (панель Supabase / Claude), анонимам select не выдаём
