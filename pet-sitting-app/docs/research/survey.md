# Мини-опрос внутри приложения (решено 2026-10-27)

**Принцип:** никаких внешних форм и длинных анкет. Карточка с вопросом сразу в ленте (без «хотите пройти?»),
**3 случайных вопроса** на человека из пула (`SURVEY_POOL` в prototype/index.html) — разные люди отвечают на разные вопросы.
**Каждый ответ сохраняется в момент нажатия** (1/3, 2/3, 3/3): ушёл на середине — уже ответенное у нас. «Пропустить» = null.

| id | Вопрос (PL) | Ответ |
|---|---|---|
| pet | Jakie masz zwierzę? | несколько: pies, kot, ptak, gryzoń/królik, gad, ryby, nie mam |
| lost_before | Czy zgubiło Ci się kiedyś zwierzę albo znalazłeś cudze? | zgubiło się / znalazłem / jedno i drugie / nigdy |
| where_help | Gdzie szukałbyś pomocy, gdy zginie zwierzę? | несколько: grupy FB, plakaty, OLX, schronisko/straż, weterynarz, aplikacja |
| rating | Jak oceniasz tę aplikację? | 1–5 звёзд |
| first_use | Z czego skorzystałbyś najpierw? | несколько: zaginione/znalezione, galeria, trutki, pomoc sąsiadów, oddam, grupy |
| recommend | Poleciłbyś ją znajomym? | tak / może / nie |
| would_help | Pomógłbyś sąsiadowi z jego zwierzęciem? | za darmo / za opłatą / nie |
| district | Gdzie mieszkasz? | Stare Miasto, Śródmieście, Krzyki, Fabryczna, Psie Pole, poza Wrocławiem |
| missing | Czego tu brakuje? | короткий текст |

**Куда сохраняется (по порядку):**
1. `SURVEY_API` — свой сервер (Supabase, таблица из `db/survey.sql`): работает, когда прототип размещён на своём домене
   pupilobok.pl. **Только так ответы смогут оставлять случайные люди без аккаунта.**
2. Общее хранилище артефакта Claude (`survey/<id>`, читает только владелец): только для вошедших в claude.ai
   с доступом «Contributor» — друзья/тестировщики, приглашённые по email.
3. Всегда — браузер человека (продолжить после перезагрузки).

**Чтение ответов:** попросить Claude («покажи ответы опроса») — он прочитает хранилище/таблицу и сведёт в `research/results.md`.
**Цель:** 30–50 человек → по каждому вопросу ~10–17 ответов.
