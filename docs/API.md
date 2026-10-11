# API 3.1.0

[README](../README.md)

Базовый адрес: `Reports.ashx?action=...`. GET только для чтения; операционные POST требуют Windows-роли редактора, CSRF-cookie/заголовка и Origin. Ответы JSON, время UTC. SQL-даты операционных API — ISO 8601. Старые аналитические API сохраняют формат дат, поддерживаемый интерфейсом.

## Новые GET

| action | Роль | Назначение |
|---|---|---|
| whoami | собственный Windows-вход | Идентичность и решения доступа, без SQL |
| csrf | читатель | Токен и cookie, без SQL |
| health | читатель | БД, схема, heartbeat, ошибки источников; проверять `healthy` |
| diag | оператор | Расширенное состояние и ошибка БД |
| agent | читатель | Строка AgentState |
| sources | оператор | Все источники с выбором/Revision, состояние обнаружения и максимум 2000 файлов |
| generations&fileId=N | оператор | Все версии файла |
| jobs | оператор | Последние 100 заданий |
| checks | читатель | Проверки сайтов |
| check-results&id=GUID | читатель | Последние 200 результатов проверки |
| rules | читатель | Правила и последние значения |
| incidents | читатель | Последние 200 инцидентов, активные первыми |
| incident-events&id=GUID | читатель | Последние 500 событий инцидента |
| notifications | оператор | Последние 200 доставок, без webhook URL и payload |
| raw-event&id=N | оператор | Исходная строка, метаданные и версия |
| parse-errors | оператор | Последние 200 ошибок разбора |
| audit | оператор | Последние 200 изменений |

## POST

- `sources-save`: пакет изменений `Enabled` по источникам с проверкой `revision`; HTTP 200 или 409, весь пакет атомарный. Подробности ниже.

- `refresh`: тело `{}`; создаёт задание scan; HTTP 202.
- `job-create`: `{"kind":"verify","fileId":1}`; kind: scan, verify, replay, new-generation. Для scan fileId не нужен. HTTP 202.
- `check-save`: поля редактора, `id` отсутствует для нового объекта, `revision` обязателен при обновлении. HTTP 409 при конфликте версии.
- `rule-save`: аналогично, метрики указаны в README.
- `incident-action`: `{"id":"GUID","action":"ack"}`; действия ack, close (после восстановления), cancel (ручное закрытие без подтверждённого восстановления).
- `notification-test`: `{}`; только ставит тестовое событие в очередь.
- `notification-retry`: `{"id":"GUID"}`; повтор failed-сообщения.

Размер JSON ограничен 64 КиБ UTF-8. Параметры SQL передаются через SqlParameter. Значения произвольных SQL-команд от клиента не принимаются.

## Сохранённые аналитические API

overview, timeline, clients, users, targets, status-codes, methods, user-agents, referers, response-times, sites, slow-requests, slow-urls, security, errors-5xx-by-url, logs, export, error-diagnostics, performance, comparison, bots, asn-info.

Данные берутся из `ir3.CurrentRequests`. Архивные версии файлов и старые `dbo` не смешиваются с текущими отчётами.

## Соглашения

Ошибка приложения: `{"error":"...","code":"..."}`. IIS/proxy может отклонить запрос раньше и вернуть HTML: это нужно различать с JSON-отказом приложения.

Инцидент не равен уведомлению: он сохраняется даже без настроенного webhook. Уведомление `sent` означает успешный HTTP-ответ получателя, а не прочтение человеком.

`LastSuccessfulScanUtc` отражает успешный проход источников; это не обязательно время появления последнего запроса и не гарантия отсутствия оставшихся порций большого файла. Контрольные точки и очередь показываются отдельно.

## Автоматическое обнаружение и флажки

`GET sources` возвращает объект `{sources, files, discovery, total, shown, integrityScope}`.

У источника поля `Id`, `Name`, `SiteId`, `RootPath`, `Enabled`, `Revision`, `AutoDiscovered`, `Available`, `IisName`, `DiscoveryStatus`, `DiscoveryMessage`, `LastDiscoveredUtc`, `LastScanUtc`, `LastError`.

- `Enabled` — сохранённый выбор оператора.
- `Available` — текущая пригодность источника из снимка IIS, **не** выбор.
- Для автоматически найденного источника импорт идёт только при `Enabled && Available`.
- `discovery` — массив с одной записью состояния задачи/чтения снимка (либо пустой до первого запуска).
- `files` содержит `sourceId` и `monitoring`; исторические файлы не исчезают после паузы.
- `Name` сохраняет существующее пользовательское имя; актуальное название IIS находится в `IisName`.

```http
POST Reports.ashx?action=sources-save
Content-Type: application/json
Origin: https://reports.example.test:8443
X-IISReports-CSRF: <token>
Cookie: <matching csrf cookie>
```

```json
{"changes":[{"id":1,"revision":1,"enabled":false},{"id":2,"revision":4,"enabled":true}]}
```

Ответ: `{"ok":true,"changed":2,"message":"..."}`.

Передаются **только изменённые** источники; `id` здесь — `ir3.Sources.Id`, не IIS SiteId. От 1 до 1000 уникальных id, до 64 КиБ JSON. Булев `enabled` обязателен, отсутствующее поле не считается `false`.

Ошибки: 400 `invalid_sources`/`invalid_json`, 409 `revision_conflict`, обычные 401/403 проверки роли и CSRF. Неверная revision хотя бы одной строки откатывает весь пакет. В API нельзя задавать произвольные пути журналов или ACL.

`job-create` с replay/new-generation для отключённого/недоступного источника возвращает 409 `source_disabled`. Verify по ранее зарегистрированному файлу остаётся доступен, но может отказать из-за отсутствия файла. Агент повторно проверяет разрешение перед коммитом порции импорта.

`health` дополнен `discoveryHealthy`; общая исправность обнаружения не гарантирует доступность каждого неподдерживаемого источника — смотрите строковые статусы в `sources`.
