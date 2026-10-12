# Microsoft SQL Server

[← Установка](INSTALL.md) · [Параметры](SETTINGS.md)

IIS Reports требует отдельную доступную базу SQL Server. Наличие IIS, SSMS или .NET не означает, что установлен SQL Database Engine.

## Локальный SQL: WindowsLocal

В `.psd1`:

```powershell
SqlServer = 'localhost'   # Для стандартного экземпляра на той же машине
Database = 'IISReports'
SqlAuthentication = 'WindowsLocal'
TrustSqlCertificate = $false
AllowCreateDatabase = $true
```

Строки выполняются как элементы файла данных внутри `@{ ... }`, не как самостоятельный скрипт.

`Install.ps1 -Step Database` использует Windows-аккаунт PowerShell для установки. Ему нужны права на создание базы/схемы. Роль Windows-администратора не гарантирует SQL sysadmin.

После создания пула и службы шаг Permissions создаёт соответствующие логины/пользователей и назначает:
- `IIS APPPOOL\<AppPoolName>` → `ir3_web`;
- `NT SERVICE\IISReportsAgentV3` → `ir3_agent`.

## Удалённый SQL: SqlLogins

В файле параметров установите `SqlAuthentication='SqlLogins'` и реальный `SqlServer`, например `tcp:sql.internal.example,1433`. Порт не обязательно 1433.

Для этапов Config и Permissions установщик запросит через `Get-Credential` два **разных** SQL-логина. Это не Windows-пароль оператора и не `sa`. Пароли сохраняются только в защищённых конфигурациях приложения, не в `.psd1` или консольном журнале.

Пример отдельного SQL-администратора:

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' `
    -Step Database -AdminCredential (Get-Credential)
```

Тот же `-AdminCredential` можно передать Permissions, Start и Verify. При Windows-доступе текущего администратора к удалённому SQL он не нужен.

В SQL Server должен быть разрешён выбранный метод аутентификации; TCP/порт и firewall настраиваются администратором. Не открывайте SQL всему интернету. Локальная виртуальная учётная запись пула не переносится на другую машину. Доменный/gMSA-сценарий требует отдельного управления служебными аккаунтами и не автоматизирован этими шаблонами.

## Шифрование

Всегда создаётся `Encrypt=True`.

`TrustSqlCertificate=$false`: проверяется сертификат SQL, его цепочка и соответствие имени. Используйте сертификат доверенного CA и имя SQL-сервера из сертификата.

`$true`: проверка сертификата SQL обходится, шифрование остаётся. Используйте только как осознанное исключение тестового окружения, не автоматическое исправление любой сетевой ошибки.

Сертификат IIS HTTPS — другой сертификат.

## Схема и данные

- 18 основных таблиц плюс DiscoveryState; версия схемы **310**.
- Базовая проверка ищет обязательные объекты по именам. Дополнительные таблицы не мешают.
- Проверка discovery требует свои поля, таблицу и запись версии 310.
- Проверка DEFAULT завершается ошибкой, если значения отличаются.
- Установочные миграции не удаляют таблицы dbo, контрольные точки и историю.
- Старые записи dbo не объединяются автоматически с `ir3.CurrentRequests`.
- Изменение поколения файла переключает текущее представление на новое поколение; старые строки сохраняются в базе.
- Одна база рассчитана на один сервер/один агент.

Перезапуск инкрементального импорта не требует TRUNCATE/DELETE. Не исправляйте ошибки отсутствующих объектов удалением схемы.

## Проверка без установки

```powershell
.\tools\Test-SqlConnection.ps1 -SqlServer 'localhost' -Database 'master'
.\tools\Initialize-Database.ps1 -SqlServer 'localhost' -Database 'IISReports' -VerifyOnly
```

SSMS/sqlcmd для этих команд не нужны. `Test-SqlConnectionBuilder.ps1` проверяет только построитель строк, без сети.
