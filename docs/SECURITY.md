# Безопасность, Windows Authentication, HTTPS и CSRF

[← README](../README.md) · [Диагностика](TROUBLESHOOTING.md)

## Три разные учётные записи

1. **Пользователь HTTP-запроса** — оператор/читатель, прошедший Windows Authentication.
2. **ApplicationPoolIdentity** — процесс IIS, читающий web-файлы и выполняющий SQL веб-приложения.
3. **Windows-служба агента** — импортёр, которому отдельно нужны SQL-права и чтение `.log`.

Проект использует `impersonate=false`. Ввод Windows-пароля в браузере не даёт процессу пула ваши SQL-права. В Windows-режиме права приложения назначаются списками Readers/Editors, а не автоматически всем администраторам.

Для IIS необходимо установить компонент Windows Authentication, включить его на нужном сайте и отключить Anonymous Authentication. [Документация Microsoft](https://learn.microsoft.com/en-us/iis/configuration/system.webServer/security/authentication/windowsAuthentication/).

## Проверка установленной аутентификации

```text
https://<ваш-домен>:<порт>/Reports.ashx?action=whoami
```

Для оператора:

```json
{
  "mode": "windows",
  "isAuthenticated": true,
  "canRead": true,
  "canEdit": true,
  "denialCode": null
}
```

`identity` — вошедший пользователь, `processIdentity` — пул. `Negotiate` не является самостоятельным доказательством успешного Kerberos во всех сценариях: проверяйте инфраструктуру и SPN отдельно.

Для уже существующего сайта:

```powershell
& "$pkg\tools\Enable-WindowsAuth.ps1" `
    -IisPath 'ACTUAL_IIS_SITE_NAME' `
    -WebRoot $webRoot -Editor $editor
```

Скрипт проверяет настоящее имя сайта/приложения и совпадение физического пути. При ошибке читайте исходный AppCmd-ответ; отсутствие SITE не означает отсутствие модуля Windows Authentication.

## Модель CSRF

Изменения разрешаются только оператору через POST. Проверяются:
- Origin, либо Referer при отсутствии Origin;
- заголовок `X-IISReports-CSRF`;
- браузерная cookie приложения;
- защищённый через `MachineKey.Protect` токен, связанный с пользователем, nonce cookie, путём приложения, Origin и сроком действия.

Cookie — HttpOnly и SameSite=Strict; Secure при HTTPS или HTTPS PublicOrigin. Токен выдаётся через `action=csrf` и не предназначен для публикации в логах/issue.

Текущая реализация — приложение ASP.NET Framework, а не заявление о независимом аудите безопасности. [OWASP: CSRF Prevention](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html).

## PublicOrigin и reverse proxy

Задайте точный внешний адрес **без пути**:

```xml
<add key="IISReportsPublicOrigin" value="https://reports.example.test:8443" />
```

`http://localhost:801`, `https://reports.example.test:8443` и тот же домен на порту 443 — разные Origin. Не чередуйте их для работы с изменяющими действиями. Приложение ожидает один канонический адрес.

За прокси нужно использовать внешний HTTPS Origin, а не внутренний HTTP. Клиентский `X-Forwarded-Host` нельзя считать доверенным без контроля сети; приложение не использует произвольные forwarded-заголовки как разрешение Origin. Прокси должен сохранять корректные Origin/Referer и не выдавать себя за пользователя через неподдерживаемый заголовок.

Windows Authentication через reverse proxy требует подходящей NTLM/Kerberos-конфигурации. Наличие HTTPS-прокси само по себе не настраивает делегирование. Не отключайте loopback check/UAC глобально, чтобы устранить 401: диагностируйте привязку, имя и схему входа.

[Microsoft: IIS Windows Authentication](https://learn.microsoft.com/en-us/iis/configuration/system.webServer/security/authentication/windowsAuthentication/).

## Обязательная HTTP-проверка

```powershell
& "$pkg\tools\Test-Http.ps1" -ApplicationUrl $publicUrl
```

Каждый запрос использует новый HttpWebRequest. Между запросами общие только cookie — CSRF-заголовок предыдущего запроса не может попасть в следующий отрицательный тест.

Требуются:
- Windows identity и выдача токена/cookie;
- GET изменения → 405;
- неверный Origin → `403 csrf_origin`;
- отсутствие заголовка → `403 csrf_missing`;
- неверный токен → `403 csrf_invalid`;
- отсутствие cookie → `403 csrf_missing`.

Положительный POST выполняется только с `-QueueScan`, он создаёт задание. Если отрицательная проверка вернула 202, **это не успех**: проверьте опубликованный обработчик и заголовки. Не «чините» ситуацию снижением требований теста.

## Безопасные файловые права

Пул имеет read/execute web-файлов, но не write. Рабочие конфиги и их backup находятся в ограниченных ACL. Служба имеет read/execute своего EXE/config и modify только собственного каталога `logs`, а также read/execute источников.

Установщик даёт Authenticated Users чтение статической оболочки. Доступ к данным всё равно проверяет API. `Web.config` имеет более строгие NTFS-права; ASP.NET/IIS не должен отдавать его по HTTP.

Не оставляйте в web-каталоге:
```text
tools/, sql/, tests/, agent/, build/
agent-local.config, *.bak, архивы, дампы, рабочие пароли
```

Особенно удалите из web-root старые `Web.config.bak.*` после переноса в закрытое хранилище: переименованный конфиг не следует считать автоматически защищённым как настоящий `Web.config`. `Set-IISReportsPublicOrigin.ps1` в этой поставке делает backup вне сайта.

## SQL и исходящие запросы

Используйте разные runtime-роли SQL, доверенное шифрованное подключение и ограниченную сеть. `TrustServerCertificate=True` — явное тестовое исключение, не настройка по умолчанию.

Для проверок/webhook применяется allowlist конкретных хостов/портов. Не разрешайте неизвестные хосты, metadata-адреса облака, wildcard или домены, которыми управляет недоверенная сторона. Выделенный firewall/egress-контроль остаётся важным: прикладной allowlist не является полноценной сетевой песочницей.

## Перед доступом из рабочей сети

- [ ] HTTPS с доверенным сертификатом; доступ только из разрешённой сети/VPN.
- [ ] Отдельная операторская группа вместо общего Windows Administrator.
- [ ] Anonymous отключён, роли заданы, все CSRF-тесты прошли.
- [ ] Ни SQL-паролей, ни webhook-секретов в исходниках, URL панели и screenshots.
- [ ] Проверено восстановление SQL/config из backup.
- [ ] Не используется неизвестный/широкий allowlist проверок.

## Автообнаружение: граница привилегий

Агент остаётся `NT SERVICE\IISReportsAgentV3`, веб-пул — `ApplicationPoolIdentity`. Им не выдаются локальные права администратора и не предоставляется чтение полного `applicationHost.config`.

Для чтения конфигурации IIS используется отдельная задача `IISReports-DiscoverSites` под SYSTEM. Её установку выполняет администратор. Задача не подключается к SQL и не принимает пути/команды из веб-запросов; публикует только имена, SiteId, каталоги и статусы. Она не меняет конфигурацию IIS и не включает Logging.

`%ProgramData%\IISReports\Discovery` и его выделенный родитель защищаются от записи обычными пользователями; полный доступ у Administrators/SYSTEM, у агента только чтение. Установщик проверяет отсутствие reparse-point предков и не перезаписывает постороннюю задачу с тем же именем. Код SYSTEM-задачи нужно обновлять только из проверенного дистрибутива.

По умолчанию задаче разрешено добавить агенту наследуемое RX на локальные каталоги W3C выбранных IIS-сайтов. Флажок в панели **не отбирает ACL**, а ограничивает импорт в агенте; при паузе журналирование IIS продолжается. Если автоматическое изменение ACL запрещено политикой, `Install-AutoDiscovery.ps1 -NoGrantLogRead` отключает его, но тогда права чтения обеспечивает администратор отдельно.

UNC, junction/symlink и неподдерживаемые форматы не получают автоматических разрешений. Защищённые дочерние файлы с выключенным наследованием могут требовать отдельной настройки.

`sources-save` использует существующие Windows-роль редактора + CSRF + Origin. Не допускаются GET-изменения, запись paths/ACL из UI, изменение схемы из браузера. Автообнаружение не сбрасывает сохранённое выключение.
