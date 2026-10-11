# Чистая установка IIS Reports 3.1.0

[← README](../README.md) · [Требования](PREREQUISITES.md)

Этот сценарий **не использует старый IIS Reports или прежний Web.config**. Базовая ветка: SQL и IIS на одной Windows-машине, отдельный сайт, отдельный пул, Windows Authentication. Для удалённого SQL изменяются только SQL-учётные данные и выдача ролей: [отдельная инструкция](DATABASE.md).

> Выполняйте шаги последовательно. При ошибке остановитесь на этом шаге: не запускайте все команды скопом и не стирайте существующие файлы, чтобы обойти проверку. Скрипты намеренно не перезаписывают работающие конфигурации и сайты.

## 0. Выберите имена и пути

Распакуйте архив так, чтобы существовал `C:\Deploy\IISReports-3.1.0\tools`.

```text
C:\Deploy\IISReports-3.1.0\           исходники / установка
C:\Deploy\IISReports-config\         подготовленные закрытые конфиги
C:\inetpub\wwwroot\IISReportsV3\     только сайт
C:\Services\IISReportsAgentV3\       EXE + конфиг службы + её logs
```

Ниже переменные задаются **в одном окне Windows PowerShell 5.1 x64 от администратора**. В новом окне задайте их снова.

```powershell
$ErrorActionPreference = 'Stop'
$pkg = 'C:\Deploy\IISReports-3.1.0'
$configDir = 'C:\Deploy\IISReports-config'
$webRoot = 'C:\inetpub\wwwroot\IISReportsV3'
$agentRoot = 'C:\Services\IISReportsAgentV3'
$siteName = 'IISReportsV3'
$poolName = 'IISReportsV3'
$sqlServer = 'localhost\SQLEXPRESS'
$db = 'IISReports'

# Аккаунт оператора в браузере. Замените, если он отличается от текущего PowerShell.
$editor = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# Полный публичный адрес. DNS/сертификат подготовьте для своего имени.
$publicUrl = 'https://reports.example.test:8443/'
$certThumbprint = 'REPLACE_WITH_CERTIFICATE_THUMBPRINT'

# False для доверенного SQL-сертификата.
# True допустим только как осознанное исключение для локального стенда.
$trustSqlCertificate = $false

# Источники не перечисляются вручную. Все локальные сайты IIS обнаруживаются автоматически.
```

Узнать реальные IIS-сайты:

```powershell
& "$env:windir\System32\inetsrv\appcmd.exe" list site
```

ID `7` обычно соответствует `W3SVC7`, а не `W3SVC1`. Сверьте настройки Logging конкретного сайта. Произвольное имя папки не определяет имя объекта IIS.

## Проверка комплекта

После проверки происхождения скачанного ZIP можно проверить контрольные суммы его файлов:

```powershell
& "$pkg\tools\Verify-Package.ps1"
```

Хеши выявляют повреждение/изменение файлов, но не заменяют доверие к каналу получения. Не запускайте установочные скрипты из непроверенного источника.

## 1. Подготовьте Windows и SQL

Следуйте [PREREQUISITES.md](PREREQUISITES.md). В частности, SQL Server должен уже быть установлен и запущен, а текущий аккаунт должен иметь права SQL DBA для установки.

```powershell
& "$pkg\tools\Install-Prerequisites.ps1" -InstallMissing
```

Перезагрузку, если потребуется, выполните вручную в согласованное время. После неё вернитесь к шагу 0 и повторите проверку.

При блокировке скачанных файлов сначала проверьте происхождение ZIP и SHA256. После этого можно снять Mark-of-the-Web с **проверенного** комплекта через `Unblock-File`. Не отключайте глобально Execution Policy и не обходите доменные политики.

## 2. Соберите сайт и службу

```powershell
& "$pkg\tools\Build-And-Test.ps1"
```

Скрипт сначала проверяет синтаксис PowerShell-файлов, затем компилирует C# 5, проверяет `Reports.ashx`, собирает агент и локальные тесты.

Ожидается финальное сообщение о пройденных локальных unit-тестах. Должны появиться:

```text
build\IISReports.Agent.exe
build\IISReports.WebCore.dll
build\IISReports.HandlerTest.dll
build\UnitTests.exe
build\SqlIntegrationTests.exe
build\DiscoverySqlTests.exe
build\BUILDINFO.json
```

**Не копируйте тестовые DLL в `web\Bin`.** ASP.NET компилирует те же классы из `App_Code`; двойная публикация приведёт к конфликтам типов.

## 3. Создайте базу и схему

Если при работе со старым дистрибутивом появлялась ошибка `Keyword not supported: DataSource`, используйте этот выпуск и [инструкцию исправления](HOTFIX-SQL-CONNECTION.md).

SSMS/sqlcmd на сервере не требуются:

```powershell
$dbArgs = @{
    SqlServer = $sqlServer
    Database = $db
    TrustServerCertificate = $trustSqlCertificate
}
& "$pkg\tools\Test-SqlConnectionBuilder.ps1"
& "$pkg\tools\Initialize-Database.ps1" @dbArgs -CreateDatabase
```

`-CreateDatabase` разрешает создание новой базы; существующая база не удаляется. SQL-схема создаётся транзакционно; таблицы `dbo` не трогаются. В конце должны присутствовать 19 таблиц `ir3`, `ir3.CurrentRequests`, роли `ir3_web`/`ir3_agent`; четыре строки аудита DEFAULT должны иметь `OK`.

Новая установка **не создаёт фиктивные источники W3SVC1–3**. После запуска агент зарегистрирует реальный список сайтов из снимка IIS. Скрипт применяет `001-v3-schema.sql` и затем `005-auto-sources.sql`; ожидаемая версия схемы — **310**.

Для уже созданной базы только проверить:

```powershell
& "$pkg\tools\Initialize-Database.ps1" @dbArgs -VerifyOnly
```

## 4. Создайте два независимых конфигурационных файла

```powershell
$newConfig = @{
    ConfigDirectory = $configDir
    SqlServer = $sqlServer
    Database = $db
    Editor = $editor
    PublicUrl = $publicUrl
    TrustServerCertificate = $trustSqlCertificate
}
& "$pkg\tools\New-InstallConfig.ps1" @newConfig
```

Получатся `Web.config` и `agent-local.config`. Родительская папка создаётся автоматически и ограничивается Administrators/SYSTEM. Пароли SQL не выводятся.

Для локальной Windows-аутентификации SQL веб-процесс будет входить от `IIS APPPOOL\IISReportsV3`, а служба — от `NT SERVICE\IISReportsAgentV3`. Это не Windows-пользователь браузера. Учётные записи получат разные роли на шаге 6.

Если файл существует, **не удаляйте его вслепую**: настройте существующий файл или выберите новую папку конфигов. Чистый установщик не является обновлятором.

## 5. Создайте IIS-сайт

### Основной вариант: HTTPS непосредственно в IIS

До запуска: DNS-имя должно разрешаться на нужный сервер; сертификат с private key должен быть в `LocalMachine\My`, действующим и подходящим домену. Просмотр сертификатов:

```powershell
Get-ChildItem Cert:\LocalMachine\My |
    Select-Object Subject, Thumbprint, NotAfter, HasPrivateKey
```

Укажите реальный thumbprint в `$certThumbprint`, затем:

```powershell
$webInstall = @{
    SiteName = $siteName
    AppPoolName = $poolName
    WebRoot = $webRoot
    ConfigFile = "$configDir\Web.config"
    CertificateThumbprint = $certThumbprint
}
& "$pkg\tools\Install-Web.ps1" @webInstall
```

Установщик создаёт **новые** сайт/пул, публикует только `web`, включает Windows Authentication, отключает Anonymous, задаёт Default Document и NTFS-права. Имена существующих сайтов/пулов и занятые IIS-порты он не переиспользует. DNS, firewall и сертификаты он не создаёт.

Если свободный выбранный порт нужен извне, откройте его только для административной сети. Например, после замены подсети:

```powershell
New-NetFirewallRule -DisplayName 'IIS Reports HTTPS admin network' `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8443 `
    -RemoteAddress '192.0.2.0/24'
```

`192.0.2.0/24` — документальный пример, не готовая ваша сеть.

### Альтернатива: только локальное тестирование по HTTP

Ещё на шаге 0 задайте `$publicUrl = 'http://localhost:801/'`, не выдавайте внешний доступ. Затем на шаге 5:

```powershell
& "$pkg\tools\Install-Web.ps1" `
    -SiteName $siteName -AppPoolName $poolName -WebRoot $webRoot `
    -ConfigFile "$configDir\Web.config" -AllowHttp
```

Такой вариант привязывается к `127.0.0.1`, а не ко всем внешним интерфейсам. Не используйте его как публичную рабочую конфигурацию.

### Альтернатива: HTTPS на reverse proxy

Публичный URL остаётся HTTPS. Внутреннюю привязку укажите отдельно:

```powershell
& "$pkg\tools\Install-Web.ps1" `
    -SiteName $siteName -AppPoolName $poolName -WebRoot $webRoot `
    -ConfigFile "$configDir\Web.config" `
    -BindingUrl 'http://127.0.0.1:801/' -AllowHttp -ReverseProxy
```

Это пример прокси **на той же машине**. Для отдельного прокси используйте адрес внутреннего интерфейса и ограничьте сеть. Прокси должен поддерживать вашу Windows Authentication; простого `X-Remote-User` недостаточно. См. [SECURITY.md](SECURITY.md).

## 6. Установите службу и выдайте роли SQL

Агент устанавливается отдельно от сайта и **пока не запускается**:

```powershell
$agentInstall = @{
    BuildDirectory = "$pkg\build"
    ConfigFile = "$configDir\agent-local.config"
    Destination = $agentRoot
}
& "$pkg\tools\Install-Agent.ps1" @agentInstall

Get-Service IISReportsAgentV3
```

Установщик также создаёт задачу **`IISReports-DiscoverSites`**: при старте Windows и раз в минуту она читает конфигурацию IIS, публикует защищённый список сайтов и выдаёт службе чтение найденных W3C-каталогов. Скрипт задания хранится вне сайта, в `%ProgramData%\IISReports\Discovery`, и недоступен агенту на запись. Задание не подключается к SQL и не меняет настройки журналирования IIS.

Каталоги, которых ещё нет, не создаются: когда IIS создаст их сам, следующий проход обнаружит их и настроит чтение. Папки с junction/symlink и UNC не получают автоматических прав.

Ожидается `Stopped`. Если служба уже существует — используйте [обновление](UPGRADING.md), не переустанавливайте её для обхода ошибки.

Теперь обе локальные Windows-учётные записи существуют, можно создать логины SQL:

```powershell
& "$pkg\tools\Grant-DatabaseAccess.ps1" @dbArgs `
    -LocalWindows -AppPoolName $poolName -ServiceName 'IISReportsAgentV3'
```

Этот шаг подходит только для SQL на той же машине. Он не выдаёт `db_owner` и `sysadmin`. Для удалённого SQL — [DATABASE.md](DATABASE.md).

## 7. Проверьте автоматическое обнаружение

Не запускайте `Register-LogSource.ps1` или `Register-All-IISSites.ps1` для обычной установки. Переменные `$sourceSiteId`, `$sourceName`, `$logRoot` не нужны.

```powershell
Get-ScheduledTask -TaskName 'IISReports-DiscoverSites'
Get-ScheduledTaskInfo -TaskName 'IISReports-DiscoverSites'

$inventoryFile = Join-Path $env:ProgramData 'IISReports\Discovery\sites.json'
$inventory = Get-Content -LiteralPath $inventoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
$inventory | Select-Object success, machineName, generatedUtc, error
$inventory.sites | Format-Table siteId, name, available, status, rootPath -AutoSize
```

Ожидается `success=True`. Статус `waiting_directory` допустим для нового сайта без файла журнала. `available=False` не удаляет сайт из списка и не стирает историю. При `path_or_acl_error`, `format_unsupported`, `central_unsupported` сначала проверьте причину в `message`.

Первый снимок создаётся во время установки. После запуска Windows-служба читает его, регистрирует источники в MSSQL и начинает импорт. Новые сайты по умолчанию включены, в том числе сайт самой панели. Исключить панель можно флажком во вкладке «Источники».

Если установка задачи была прервана, после исправления причины повторите **при остановленной службе**:

```powershell
& "$pkg\tools\Install-AutoDiscovery.ps1" -AgentDirectory $agentRoot
```

Это не переустанавливает службу и не пересоздаёт базу. Настройка по умолчанию — одна задача обнаружения и один агент на один IIS-сервер/БД.

## 8. Проверьте пользователя, токен и SQL

Откройте **тот же публичный адрес**, который задали в конфигурации:

```text
<publicUrl>Reports.ashx?action=whoami
<publicUrl>Reports.ashx?action=health
```

Для оператора нужны `mode=windows`, `isAuthenticated=true`, `canRead=true`, `canEdit=true`. У базы — `dbConnected=true`, `schemaInitialized=true`.

Затем запустите изолированный тест:

```powershell
& "$pkg\tools\Test-Http.ps1" -ApplicationUrl $publicUrl
```

Обязательны успешные отрицательные проверки: GET-изменение → 405; неверный Origin, отсутствие CSRF-заголовка, неверный токен, отсутствие cookie → 403 с ожидаемыми JSON-кодами. Полные токены и cookie не отправляйте в issue/логи.

Если POST без токена возвращает 202, установка **не прошла приёмку**. Проверяйте именно опубликованные файлы и точный URL, не ослабляйте тест и не отключайте CSRF.

До старта службы `agentOnline=false`, пустая история и `status=stale` ожидаемы.

## 9. Запустите сборщик

```powershell
Start-Service IISReportsAgentV3
Get-Service IISReportsAgentV3
```

Агент сам выполняет сканирование; открытый браузер не требуется. После первого прохода проверьте:
- `agentOnline=true`, появился heartbeat;
- источники показывают дату сканирования без `LastError`;
- `dbEntries` растёт, если есть валидные записи;
- очередь заданий обрабатывается.

`healthy=true` само по себе не доказывает полноту импорта. Сверьте счётчики источников, карантин и выборку реальных строк. На больших журналах первый проход займёт время — не ставьте десятки одинаковых Scan-заданий.

Фактический корректный POST можно отдельно проверить:

```powershell
& "$pkg\tools\Test-Http.ps1" -ApplicationUrl $publicUrl -QueueScan
```

Этот ключ **создаёт одно задание импорта**. Обычный отрицательный smoke-тест не должен создавать заданий при корректной защите.

## 10. Завершите эксплуатационную настройку

Настройте допустимые адреса проверок и webhook, правила, GeoIP/ASN по [CONFIGURATION.md](CONFIGURATION.md). Организуйте SQL-backup и ограничение сети по [OPERATIONS.md](OPERATIONS.md).

### Контрольный список

- [ ] Папки `agent`, `tools`, `sql`, `build` отсутствуют в web-каталоге.
- [ ] ConnStr и конфиг агента защищены ACL; в репозитории нет паролей.
- [ ] Windows Authentication включена, Anonymous отключена.
- [ ] PublicOrigin совпадает с браузерным протоколом, именем и портом.
- [ ] SQL-роли разделены между пулом и службой.
- [ ] Реальные W3C-источники зарегистрированы; служба читает их.
- [ ] Все отрицательные CSRF-тесты прошли.
- [ ] Агент работает; реальные записи импортированы; ошибки разобраны.
- [ ] HTTPS, firewall/VPN и резервное копирование настроены.

## 11. Выберите сайты в браузере

Откройте «Источники» → «Какие сайты мониторить».

1. По умолчанию все впервые обнаруженные сайты включены.
2. Снимите флажки у ненужных сайтов.
3. Нажмите **«Сохранить выбор»**. До нажатия кнопки изменение только локальное.
4. Для массового изменения используйте поиск и «Включить видимые» / «Отключить видимые», затем сохраните.

Отключение — **пауза импорта**, а не удаление SQL-строк и не отключение Logging в IIS. Сохранённая история остаётся в аналитике. После включения агент дочитает накопившиеся доступные строки, а не только строки после момента включения.

Новый сайт, добавленный в IIS позднее, тоже включается по умолчанию. Массовая кнопка действует только на уже показанный список; это не запрет на будущие сайты.

Подробная семантика, ограничения и проверка: [AUTO-SOURCES.md](AUTO-SOURCES.md).
