# Конфигурация

[← README](../README.md)

## Где что хранится

| Файл/объект | Содержимое |
|---|---|
| `<WebRoot>\Web.config` | SQL веб-приложения, роли, PublicOrigin, список разрешённых проверок |
| `<AgentRoot>\IISReports.Agent.exe.config` | SQL службы, частота сканирования, проверки и секрет webhook |
| `<WebRoot>\sites.json` | Названия сайтов по IIS SiteId |
| `<WebRoot>\App_Data\geoip.csv` | Необязательная IPv4-база стран |
| `<WebRoot>\App_Data\asn.csv` | Необязательная IPv4-база ASN |
| `ir3.Sources` | Реальные каталоги журналов на машине агента |
| `ir3.Checks`, `ir3.AlertRules` | Проверки и правила из редактора интерфейса |

Шаблоны имеют суффикс `.example`: это не рабочие конфиги. В исходном комплекте нет настоящих паролей и адресов назначения.

## Web.config

| Ключ | Значение/смысл |
|---|---|
| `ConnStr` | `System.Data.SqlClient` connection string; читается из **appSettings**, не connectionStrings |
| `IISReportsAccessMode` | `windows` для установки; `local` только для отдельного локального эксперимента |
| `IISReportsEditors` | Точные аккаунты/группы операторов, разделитель `;` |
| `IISReportsReaders` | Точные аккаунты/группы читателей, разделитель `;` |
| `IISReportsPublicOrigin` | Один канонический `scheme://host:port`, без пути, query и fragment |
| `IISReportsCheckHosts` | Разрешённые имена/IP HTTP-проверок, через `,` или `;`, без wildcard |
| `IISReportsCheckPorts` | Разрешённые порты через запятую |
| `IISReportsAllowHttpChecks` | `false` по умолчанию; `true` явно разрешает HTTP-проверки |

Пустые role-lists не предоставляют доступ всем вошедшим. Членство в Windows Administrators само по себе не заменяет роль IIS Reports.

PublicOrigin — не настройка DNS или привязки IIS. Он должен соответствовать URL браузера даже при ином внутреннем адресе прокси.

```powershell
& "$pkg\tools\Set-IISReportsPublicOrigin.ps1" `
    -WebConfig "$webRoot\Web.config" `
    -PublicUrl 'https://reports.example.test:8443/'
```

Скрипт сохраняет ConnStr, делает закрытый backup вне сайта, меняет только Origin. После изменения получите новый токен перезагрузкой страницы.

## Конфигурация службы

Дополнительные ключи:

| Ключ | По умолчанию |
|---|---|
| `IISReportsScanSeconds` | `30`; в коде допустимо 5–3600 |
| `IISReportsWebhookUrl` | Пусто — внешней отправки нет |
| `IISReportsWebhookHosts` | Пусто — назначения не разрешены |
| `IISReportsWebhookPorts` | `443` |

Перезапускайте службу после изменения её `.exe.config`; веб-конфиг и конфиг службы — отдельные файлы. Изменение подготовленного файла в `C:\Deploy` не меняет уже установленную копию.

Для проверки `https://api.example.test/health` в **обоих** конфигах разрешите `api.example.test` и `443`. Затем создайте проверку во вкладке «Проверки сайтов». Проверки не пересылают пользовательские Windows-credentials, не следуют редиректам и читают ограниченный объём ответа.

Пустой список хостов означает запрет, а не «любой хост». Настройку allowlist должен контролировать администратор сервера; оператор интерфейса выбирает только из разрешённых направлений.

## Уведомления

Пример конфигурации **только в закрытом конфиге службы**:

```xml
<add key="IISReportsWebhookUrl" value="https://notify.example.test/iis" />
<add key="IISReportsWebhookHosts" value="notify.example.test" />
<add key="IISReportsWebhookPorts" value="443" />
```

Это generic JSON-webhook, не готовый Telegram `sendMessage` и не SMTP. Для таких интеграций нужен собственный принимающий адаптер.

Очередь сохраняется в SQL. Получатель должен учитывать устойчивый `eventId`, поскольку возможна повторная доставка при потере подтверждения. После изменения URL адресат может получить уже накопленные ожидающие сообщения — проверьте очередь перед включением.

## Названия сайтов

`Name` источника в SQL используется для управления источником. Названия в аналитике/селекторе задаются через `sites.json`:

```powershell
& "$pkg\tools\Set-IISReportsSiteDisplayName.ps1" `
    -WebRoot $webRoot -SiteId 2 -DisplayName 'Customer API'
```

```json
{
  "1": "Main website",
  "2": "Customer API"
}
```

Это не создаёт привязки домена и не изменяет SiteId. Не меняйте номер, чтобы переименовать сайт.

## GeoIP / ASN

Копируйте реальные базы в `App_Data`, а не в корень сайта. Поля примеров:

```text
geoip.csv: startIpInt,endIpInt,countryCode,countryName
asn.csv:   startIpInt,endIpInt,asn,organization
```

Сверяйте формат с приложенными `.example` и кодом загрузчика: это простой диапазонный CSV, не MMDB и не универсальный импорт произвольного файла MaxMind. Используйте отсортированные корректные IPv4-диапазоны без перекрытий и имен с неподдерживаемым экранированием. IPv6 GeoIP/ASN здесь не реализован.

Файлы не скачиваются автоматически. Проверьте лицензию используемого набора данных. Код страны регистрации диапазона нельзя безоговорочно считать текущим физическим местоположением клиента.

## Заголовки безопасности

В шаблоне есть запрет iframe, nosniff и Referrer-Policy. Не заменяйте ошибочные Origin разрешением `*`. Конфигурации не должны содержать пароль администратора Windows. Для SQL-логинов пароли вводятся через `Get-Credential` и сохраняются в ACL-защищённых runtime-конфигах.
