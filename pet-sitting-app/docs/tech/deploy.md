# Публикация сайта (Netlify, автообновление из GitHub)

**Схема:** Claude (облако) правит `pet-sitting-app/prototype/` → commit + push в ветку `pet-sitting-app-plan`
репозитория `uladshu/finish_projects` → Netlify сам собирает (`netlify.toml` в корне: `build_site.py` → `prototype/dist`)
и публикует за ~1 мин. Пользователю ничего скачивать не нужно — обновить страницу.
Данные карты (`wro0..3.txt`, `fonts.json`, ~36 МБ) лежат в git; пересобрать: `build_tiles.py`.

**Одноразовая настройка (делает владелец):** netlify.com → Sign up with GitHub → Add new project → Import an existing
project → GitHub → репозиторий finish_projects → Branch: `pet-sitting-app-plan` → Deploy. Затем Project configuration →
Change project name → `pupilobok` (адрес pupilobok.netlify.app). Позже: Domain management → Add domain → pupilobok.pl.

**Правило для Claude:** после изменений прототипа — push (сайт обновится сам) + опубликовать артефакт (предпросмотр).
Проверка: открыть сайт; если сборка упала — владелец смотрит Deploys → лог и присылает ошибку.
