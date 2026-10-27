# Публикация сайта (GitHub Pages, автообновление)

**Адрес:** https://uladshu.github.io/Finish_projects/ (репозиторий публичный → Pages бесплатно).
**Схема:** Claude (облако) правит `pet-sitting-app/prototype/` → push в `pet-sitting-app-plan` (ветка по умолчанию) →
GitHub Actions `.github/workflows/pages.yml` собирает `build_site.py` → `prototype/dist` и публикует (~1–2 мин).
Данные карты (`wro0..3.txt`, `fonts.json`, ~36 МБ) лежат в git; пересобрать: `build_tiles.py`.

**Одноразовая настройка (владелец):** github.com/Uladshu/Finish_projects → Settings → Pages →
Build and deployment → Source: **GitHub Actions**. Затем Actions → «Publish site (GitHub Pages)» → Run workflow (или любой push).
**Проверка:** вкладка Actions — зелёная галочка; красный крестик → открыть, прислать лог Claude.
**Запасной вариант:** Netlify (`netlify.toml` в корне уже настроен).
**Правило для Claude:** после изменений прототипа — push (сайт обновится сам) + опубликовать артефакт (предпросмотр).
