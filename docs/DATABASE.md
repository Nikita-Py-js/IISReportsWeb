# SQL Server: локальная и удалённая установка

[← README](../README.md) · [Чистая установка](INSTALL.md)

## Что создаёт проект

`sql/001-v3-schema.sql` создаёт 18 таблиц в схеме `ir3`, представление `CurrentRequests`, индексы и роли. Версия модели данных остаётся `300`; версия приложения `3.0.2` не означает обязательную новую схему.

Схема применяется в одной транзакции. DDL выполняется отдельными дочерними пакетами; при ошибке изменения транзакции откатываются. Создание самой базы `CREATE DATABASE` выполняется отдельно и при неудачной миграции база может остаться пустой — это не повод удалять другие базы.

Никакие старые `dbo`-таблицы не удаляются, но отчёты читают **только `ir3.CurrentRequests`**. Строки прежней версии не объединяются автоматически. Исходные журналы можно заново прочитать; миграция старых строк без исходных файлов не включена.

## Роли

| Роль | Назначение |
|---|---|
| `ir3_web` | Чтение отчётов, запись разрешённых настроек/заданий/аудита |
| `ir3_agent` | Импорт, состояние сборщика, мониторинг и очередь доставки |
| SQL DBA | Первоначальное создание БД/схемы/логинов и обновление структуры |

Веб-приложение не создаёт таблицы при каждом запросе. `sysadmin` и `db_owner` приложению не нужны. Установщик **не отзывает** широкие привилегии, выданные ранее; проверяйте их отдельно.

## SQL на одной машине с IIS

Выполните основную [инструкцию](INSTALL.md). После создания пула и службы:

```powershell
& "$pkg\tools\Grant-DatabaseAccess.ps1" @dbArgs `
    -LocalWindows -AppPoolName $poolName -ServiceName 'IISReportsAgentV3'
```

Создаются Windows-логины/пользователи:
- `IIS APPPOOL\<имя пула>` → `ir3_web`;
- `NT SERVICE\IISReportsAgentV3` → `ir3_agent`.

Вход администратора в браузере не выдаёт SQL-права службе. Веб-приложение использует `impersonate=false`.

## SQL на отдельном сервере: два SQL-логина

На SQL-сервере администратор должен заранее разрешить SQL-аутентификацию. Изменение режима аутентификации требует административной процедуры; проект не переключает его автоматически. Windows Authentication браузера при этом остаётся Windows Authentication — это отдельный слой.

Пример ниже заменяет SQL-часть основной установки. Введите пароли через `Get-Credential`, не пишите их в командной строке, репозитории или issue.

```powershell
$pkg = 'C:\Deploy\IISReports-3.0.2'
$sqlServer = 'tcp:sql.example.test,1433'
$db = 'IISReports'
$configDir = 'C:\Deploy\IISReports-config'
$editor = 'DOMAIN\ReportsOperators'
$publicUrl = 'https://reports.example.test:8443/'

# Административный SQL-логин только на время provisioning.
$adminSql = Get-Credential -Message 'SQL administrator for provisioning'

# Выделенные разные логины приложения.
$webSql = Get-Credential -UserName 'iisreports_web' -Message 'Web SQL login'
$agentSql = Get-Credential -UserName 'iisreports_agent' -Message 'Agent SQL login'

$dbArgs = @{
    SqlServer = $sqlServer
    Database = $db
    AdminCredential = $adminSql
}
& "$pkg\tools\Initialize-Database.ps1" @dbArgs -CreateDatabase
& "$pkg\tools\Grant-DatabaseAccess.ps1" @dbArgs `
    -WebCredential $webSql -AgentCredential $agentSql

& "$pkg\tools\New-InstallConfig.ps1" `
    -ConfigDirectory $configDir -SqlServer $sqlServer -Database $db `
    -Editor $editor -PublicUrl $publicUrl `
    -WebSqlCredential $webSql -AgentSqlCredential $agentSql
```

Скрипт создаёт SQL-логин только при его отсутствии, с `CHECK_POLICY=ON`; существующий пароль не сбрасывает. Если логин уже есть, переданные рабочим конфигам пароли должны соответствовать ему. Административная учётная запись не попадает в конфиги сайта/службы.

При Windows-входе DBA на удалённый SQL `AdminCredential` можно не передавать. Для runtime-доменных аккаунтов попросите администратора назначить роли отдельно. Не переносите механически `IIS APPPOOL\...` на другую машину: сетевой контекст виртуальных аккаунтов отличается. [Microsoft: Application Pool Identities](https://learn.microsoft.com/en-us/iis/manage/configuring-security/application-pool-identities).

## TLS и порты

`1433` — пример, а не универсальный порт. TCP должен быть включён на SQL, выбранный порт доступен с IIS/агента. При фиксированном `tcp:host,port` не нужно полагаться на обнаружение именованного экземпляра.

По умолчанию проверяется SQL-сертификат. Для локального стенда есть явный `-TrustServerCertificate`; для рабочего сервера настройте доверенную цепочку и имя. Не отключайте TLS и не публикуйте SQL-порт в интернет.

## Проверка без изменений

```powershell
& "$pkg\tools\Initialize-Database.ps1" @dbArgs -VerifyOnly
```

В SSMS альтернативно выполните `003-v3-verify.sql` и `004-v3-defaults-audit.sql`. Четыре DEFAULT-состояния — `new`, `queued`, `open`, `pending`. Если аудит показывает `REVIEW`/`UNEXPECTED VALUE`, не правьте историю массовым UPDATE: сначала проверьте определение DEFAULT и реальные значения.

## Добавление / отключение источников

`Register-LogSource.ps1` работает под SQL DBA, не требует расширения runtime-роли `ir3_web`. Он добавляет источник или изменяет его имя, если совпадают SiteId и RootPath. Источники с пересекающимися корнями отклоняются. Выполняйте регистрацию последовательно, пока агент остановлен.

Отключение источника через SSMS сохраняет историю:

```sql
-- Сначала найдите настоящий Id:
SELECT Id, Name, SiteId, RootPath, Enabled FROM ir3.Sources ORDER BY Id;

-- Затем укажите выбранный Id:
-- UPDATE ir3.Sources SET Enabled = 0 WHERE Id = 7;
```

Не меняйте существующий путь на другой каталог, не разобравшись с историей файлов. Для другого источника регистрируйте отдельный корень.

## Хранение и backup

Нет автоматического удаления старых данных. Хранятся RawEvents, Requests, контрольные суммы и мониторинговая история. Планируйте объём и SQL-backup; `.log` не заменяет backup правил, инцидентов и состояния импорта.

Не меняйте автоматически recovery model и не запускайте shrink по расписанию. Организуйте резервное копирование в соответствии с принятой DBA-политикой.
