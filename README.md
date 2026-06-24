# code-ranker-ci

Reusable GitHub Actions workflow для **code-ranker Reports**. Подключается одним
тонким файлом, генерирует HTML-отчёт `code-ranker` на вашем CI и публикует ссылку
на него прямо в Pull Request — без секретов, через keyless OIDC.

Это часть продукта [code-ranker](https://github.com/ffedoroff/code-ranker) Reports.

## Что это

При каждом Pull Request (и при push в `main`) workflow:

1. устанавливает `code-ranker` (прекомпилированный бинарь, секунды),
2. строит самодостаточный HTML-отчёт по вашему коду,
3. keyless-загружает его в backend по OIDC,
4. оставляет sticky-комментарий в PR со ссылкой на отчёт (обновляется на месте,
   не плодит новые комментарии на каждый push).

Режим **рекомендательный** (`continue-on-error`): workflow никогда не роняет ваш CI.

## Как подключить

Скопируйте стаб в свой репозиторий как `.github/workflows/code-ranker.yml`:

```yaml
name: code-ranker
on:
  pull_request:
  push:
    branches: [main]
jobs:
  report:
    uses: ffedoroff/code-ranker-ci/.github/workflows/report.yml@v1
    permissions:
      id-token: write        # OIDC, keyless — секрет не нужен
      contents: read         # checkout кода для анализа
      pull-requests: write   # sticky-комментарий со ссылкой
```

Если репозиторий устанавливался через GitHub App, этот файл уже добавлен
онбординг-PR — копировать вручную не нужно.

Если ваша default-ветка не `main`, поправьте список веток в `push`.

### Keyless OIDC — почему нет секретов

Идентичность запуска доказывается короткоживущим OIDC-токеном GitHub Actions
(audience `code-ranker-reports`), а не хранимым API-ключом. Поэтому:

- ничего не нужно добавлять в **Settings → Secrets**;
- права `id-token: write` объявляются в стабе (это право *запросить выпуск*
  подписанного токена, а не право писать в репозиторий);
- токен живёт минуты и принимается только нашим сервисом.

## Версионирование `@v1`

Стаб пинит плавающий мажорный тег `@v1`. Вы автоматически получаете совместимые
улучшения (новые флаги анализа, ускорение установки, фиксы) без правок в своём
репозитории — мы перемещаем тег `v1` на новый релиз.

- Обратно совместимые изменения → новый патч/минор, теги `v1`/`v1.x` переезжают.
- Ломающие изменения → новый мажор `v2`; **`v1` никогда не ломается на месте**.

Командам, которым нужна полная воспроизводимость, доступен opt-in SHA-пиннинг:
`uses: ffedoroff/code-ranker-ci/.github/workflows/report.yml@<sha>` плюс
Dependabot для контролируемых обновлений.

## Pull Request из форков

Форк-PR не получает OIDC-токен от GitHub, поэтому прямая загрузка для него
невозможна. Поддержка форков строится отдельным привилегированным путём через
триггер `workflow_run` (фаза A собирает HTML обычным артефактом без секретов;
фаза B в контексте base-репозитория делает привилегированную загрузку и
комментарий). **`pull_request_target` не используется никогда.**

Большинству репозиториев это не нужно. Если нужно — см. комментарии в
`caller-stub.yml`: добавляется upload-artifact шаг и второй тонкий файл
`.github/workflows/code-ranker-fork.yml`, делегирующий в
`ffedoroff/code-ranker-ci/.github/workflows/fork-report.yml@v1`.

## Файлы этого репозитория

| Файл | Роль |
|---|---|
| `.github/workflows/report.yml` | reusable workflow — основной same-repo путь |
| `.github/workflows/fork-report.yml` | reusable workflow — привилегированный fork-PR обработчик (фаза B) |
| `caller-stub.yml` | тонкий стаб, который вы кладёте в свой репозиторий |
