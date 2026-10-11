# Исправление установки: `Keyword not supported: DataSource`

[← README](../README.md) · [Чистая установка](INSTALL.md) · [База данных](DATABASE.md)

## Симптом

При выполнении:

```powershell
& "$pkg\tools\Initialize-Database.ps1" @dbArgs -CreateDatabase
```

PowerShell сообщает `Ключевое слово не поддерживается: "DataSource"` (или `Keyword not supported: 'DataSource'`).

**Это ошибка скрипта IIS Reports 3.0.2**, а не повреждение SQL-базы. Сообщение формируется при построении строки подключения, до начала SQL-команд. Удалять базу и переустанавливать IIS не требуется.

## Причина

`System.Data.SqlClient.SqlConnectionStringBuilder` реализует `IDictionary`. Windows PowerShell может трактовать выражение `$b.DataSource = $SqlServer` как запись словарного ключа `DataSource`, а не как установку свойства `DataSource`. Для строки подключения SQL Server требуется `Data Source` (с пробелом). Аналогично для других свойств нужно использовать ключи SqlClient, например `Initial Catalog`, `Integrated Security`, `User ID`.

## Исправление

Данный комплект включает полный исправленный файл `tools/Setup.Common.ps1`. Используется обращение через индексатор с именами допустимых ключей. Это также устраняет тот же дефект в `New-InstallConfig.ps1`, `Grant-DatabaseAccess.ps1` и `Register-LogSource.ps1`, которые используют общий helper.

Варианты:

1. **Предпочтительно:** распакуйте полный архив `IISReports-3.0.2-SQLCONN-FIX1-complete.zip` в новый каталог `C:\Deploy\IISReports-3.0.2-SQLCONN-FIX1`, перенесите ваши значения установочных переменных и продолжите по `docs/INSTALL.md`.
2. Если требуется исправить уже распакованный исходный комплект, сохраните резервную копию прежнего `tools/Setup.Common.ps1`, затем замените его **целиком** файлом из данного выпуска. Учтите, что прежний `SHA256SUMS.txt` при этом станет неактуальным. Для проверки целостности используйте целиком обновлённый архив.

## Проверка исправления без SQL Server

```powershell
$pkg = 'C:\Deploy\IISReports-3.0.2-SQLCONN-FIX1'
& "$pkg\tools\Verify-Package.ps1"
& "$pkg\tools\Test-SqlConnectionBuilder.ps1"
```

Ожидается:

```text
PASS SQL connection string (Windows authentication; trusted TLS)
PASS SQL connection string (SQL authentication; explicit test certificate trust)
PASS TOTAL 2. No network or database commands were executed.
```

Это проверки **формирования строки подключения**, а не доступности SQL-сервера.

## Продолжение чистой установки

```powershell
$pkg = 'C:\Deploy\IISReports-3.0.2-SQLCONN-FIX1'
$dbArgs = @{
    SqlServer = $sqlServer
    Database = $db
    TrustServerCertificate = $trustSqlCertificate
}
& "$pkg\tools\Initialize-Database.ps1" @dbArgs -CreateDatabase
```

Если `$sqlServer`, `$db` или `$trustSqlCertificate` пусты (вы открыли новое окно PowerShell), задайте их заново по `docs/INSTALL.md`. В стандартном варианте SQL Express: `$sqlServer = 'localhost\SQLEXPRESS'`, `$db = 'IISReports'`. Уточните реальное имя экземпляра SQL.

Если SQL Server не установлен, появится другая ошибка подключения. **Одного IIS для работы этого проекта недостаточно**: нужна доступная локальная или удалённая инстанция SQL Server. Для рабочего сервера используйте доверенный SQL TLS-сертификат; `TrustServerCertificate=True` оставляйте только для осознанного тестового исключения.

## Проверка результата

```powershell
& "$pkg\tools\Initialize-Database.ps1" @dbArgs -VerifyOnly
```

Скрипт запускает полную верификацию SQL-схемы `ir3` и значений DEFAULT. Уже созданную базу не удаляет.
