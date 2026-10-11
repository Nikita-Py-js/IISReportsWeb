# Устранение ошибок

[← README](../README.md)

## 403.14 / DirectoryListingModule

В каталоге сайта нет `index.html`, либо выключен Default Document. Типичная причина: весь архив опубликован как сайт, а HTML остался в подпапке `web`.

Проверка:
```powershell
Test-Path "$webRoot\index.html"
Test-Path "$webRoot\Reports.ashx"
& "$env:windir\System32\inetsrv\appcmd.exe" list site
```

Публикуйте только `web/`. В новом шаблоне Default Document явно включён и указывает на `index.html`. **Не включайте Directory Browsing.**

## «Не удалось найти SITE»

Имя папки/пула не совпадает с IIS SiteName. Найдите реальное имя:
```powershell
& "$env:windir\System32\inetsrv\appcmd.exe" list site
& "$env:windir\System32\inetsrv\appcmd.exe" list app
```

Новый `Install-Web.ps1` создаёт объект с явным именем. `Enable-WindowsAuth.ps1` для существующего сайта не должен угадывать его.

## Не найден родительский каталог при Save

Новые генераторы конфигураций создают отсутствующие папки. Убедитесь, что запускаете **скрипты этого архива**, а не одноимённый старый файл из web-root. Если папка существует, проверьте ACL и точный путь.

## Destination exists

Это защита от перезаписи. Для чистой установки выбирайте новую папку. Для изменения Origin/ролей используйте соответствующие скрипты или процедуру обновления. Не удаляйте работающий Web.config вместе с ConnStr.

## Незакрытая кавычка PowerShell

Используйте команды со splatting:
```powershell
$argsInstall = @{
    BuildDirectory = "$pkg\build"
    ConfigFile = "$configDir\agent-local.config"
    Destination = 'C:\Services\IISReportsAgentV3'
}
& "$pkg\tools\Install-Agent.ps1" @argsInstall
```

Строка `-Destination "C:\Services\IISReportsAgentV3` без закрывающей кавычки не выполнит установку. Не вставляйте в PowerShell markdown-обрамление и экранирование вроде `http\://`.

## 401 / 403 доступа

| Код | Проверить |
|---|---|
| `authentication_required` | Windows Auth установлен/включён? Anonymous выключен? |
| `local_only` | Остался `IISReportsAccessMode=local` |
| `reader_role_required` | Аккаунт из whoami добавлен в Readers/Editors? |
| `editor_role_required` | Пользователь только читатель |
| `csrf_origin` | Публичный протокол, хост и порт совпадают с браузером? |
| `csrf_missing` | Токен и cookie получены на том же адресе? |
| `csrf_invalid` / `csrf_expired` | Перезагрузить страницу и получить свежий токен |
| `post_required` / HTTP 405 | GET не выполняет изменения; это ожидаемый запрет |

Для `csrf_origin` выполните в консоли браузера `location.origin`, затем настройте PublicOrigin именно на это значение. После смены конфига — Ctrl+F5. Не отключайте CSRF.

## HTTP-тест показывает 202 без токена

Используйте только текущий `Test-Http.ps1` с изолированными запросами. Если 202 повторяется, остановите предоставление доступа и исследуйте фактически опубликованный `Security.cs`, `V3Api.cs`, `Reports.ashx`. Успешная выдача токена сама по себе не доказывает проверку POST.

## ConnStr не задан

Приложение читает `appSettings['ConnStr']`. Раздел `connectionStrings` не используется. Выполните `New-InstallConfig.ps1` для чистой установки; старый Web.config не требуется.

Пароли и полную строку подключения не публикуйте. Сообщите только тип аутентификации, сервер/базу при допустимости и текст SQL-ошибки без секретов.

## SQL: ir3 отсутствует / Ts не существует / каскад внешних ключей

Используйте полный `001-v3-schema.sql` из текущей поставки, выбранную пользовательскую базу и установочный аккаунт DBA. Скрипт останавливается и откатывает изменения при ошибке. Не выполняйте отдельные CREATE INDEX до таблиц и не очищайте dbo.

```powershell
& "$pkg\tools\Initialize-Database.ps1" @dbArgs -VerifyOnly
```

Нужна **первая** SQL-ошибка, а не десятки последствий. При неправильных DEFAULT сначала смотрите `004-v3-defaults-audit.sql`.

## Login failed / сертификат SQL

Windows-вход браузера и права службы различаются. Локальные аккаунты пула/службы требуют SQL-логинов после их создания. Удалённому SQL нужны отдельные credentials/доменные права.

При недоверенном сертификате настройте цепочку и имя SQL. Не включайте постоянный обход проверки сертификата для рабочей сети.

## Служба отсутствует / agentOnline=false

```powershell
Get-Service IISReportsAgentV3 -ErrorAction SilentlyContinue
Test-Path "$pkg\build\IISReports.Agent.exe"
Test-Path "$configDir\agent-local.config"
```

Есть EXE, но нет службы → выполнить Install-Agent. Нет конфигурации → New-InstallConfig. До старта агента `status=stale` ожидаем.

Если служба Running, но heartbeat нет:
```powershell
Get-Content "$agentRoot\logs\agent-*.log" -Tail 50
```

Проверьте SQL-права **службы**, её фактический конфиг, схему и второй агент с той же БД. Сам статус службы Running не доказывает успешный импорт.

## Ноль записей / failedSources

Проверьте зарегистрированные источники, реальные `.log`, `#Fields`, права чтения и карантин. Новый установщик не создаёт W3SVC1–3 автоматически.

Health не доказывает, что журналы включены в анализируемом IIS-сайте. Не все HTTP-ошибки гарантированно представлены W3C-логами; HTTPERR/FREB — отдельные пока не подключённые источники.

## Source changed / integrity mismatch

Не удаляйте контрольные точки, чтобы скрыть проблему. Используйте Verify, изучите размер, поколение и исходный файл. Для намеренно заменённого файла оператор может создать новую generation. Старое поколение сохраняется, но `CurrentRequests` показывает активное — итог текущих отчётов может измениться.

## Что приложить к issue

Версия, ОС/SQL, команда и первая ошибка, результат whoami/health без токенов, состояние службы, несколько обезличенных строк agent-log. Не прикладывайте рабочий Web.config, cookie, токены, SQL-пароли и webhook URL с секретом.
