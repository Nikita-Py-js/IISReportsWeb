# VERIFY-FIX1 — проверка структуры SQL для IIS Reports 3.1.0

[← README](../README.md) · [Установка](INSTALL.md) · [SQL Server](DATABASE.md)

## Причина

`001-v3-schema.sql` создаёт **18 базовых таблиц** в схеме `ir3`. Миграция
`005-auto-sources.sql` добавляет `ir3.DiscoveryState`, поэтому после установки
версии 3.1.0 общее число таблиц становится **19**. Ранее файл
`003-v3-verify.sql` содержал ошибочное условие: `COUNT(*) <> 18`.
На правильно установленной версии 3.1.0 это давало
`ERROR: expected 18 tables` даже при наличии всех объектов.

## Что исправлено

Файл `sql/003-v3-verify.sql` теперь проверяет **все 18 обязательных
базовых таблиц по именам**, а не точное общее количество. При этом он
проверяет представление `ir3.CurrentRequests` и роли `ir3_web` / `ir3_agent`.
Следующий скрипт `sql/006-auto-sources-verify.sql` по-прежнему требует
`ir3.DiscoveryState`, поля `Revision` и `DiscoveryKey`, а также версию 310.
Дополнительные таблицы больше не дают ложных ошибок, а отсутствующие
обязательные объекты по-прежнему обнаруживаются.

## Исправление существующей распаковки

1. Скопируйте полный файл `sql/003-v3-verify.sql` из данного патча в
   `C:\Deploy\IISReports-3.1.0\sql\003-v3-verify.sql` с заменой.
2. Не меняйте ни данные, ни `SchemaVersions`, ни рабочие `Web.config`.
3. Запустите Windows PowerShell 5.1 от администратора, укажите правильный SQL Server:

```powershell
$pkg = 'C:\Deploy\IISReports-3.1.0'
$sqlServer = 'localhost' # замените фактическим именем сервера / экземпляра SQL
$db = 'IISReports'
$trustSqlCertificate = $true # только если сознательно доверяете локальному SQL
$dbArgs = @{
    SqlServer = $sqlServer
    Database = $db
    TrustServerCertificate = $trustSqlCertificate
}
& "$pkg\tools\Initialize-Database.ps1" @dbArgs -VerifyOnly
```

Ожидаемое количество таблиц: **19**; отсутствие обязательных объектов —
**0**. Последний этап должен вывести версию `310`, а затем сообщение
`Schema verification completed.`. Если `004-v3-defaults-audit.sql` показывает
состояние `REVIEW`/`UNEXPECTED VALUE`, проверьте ограничения отдельно;
этот аудит не выполняет исправлений.

### Проверка отдельно в SSMS (только чтение)

В правильной БД `IISReports` выполните:

```sql
SELECT COUNT(*) AS TablesInIr3
FROM sys.tables
WHERE schema_id = SCHEMA_ID(N'ir3');

SELECT MAX(Version) AS SchemaVersion FROM ir3.SchemaVersions;

SELECT OBJECT_ID(N'ir3.DiscoveryState',N'U') AS DiscoveryStateObjectId;
```

Если значение `TablesInIr3` больше 19 из-за собственных таблиц, это не
является ошибкой само по себе. Не удаляйте таблицы, чтобы получить точное число.

## Безопасность и совместимость

Исправленный проверочный SQL использует `INSERT` **только для локальной табличной переменной** со списком ожидаемых имён. Он не содержит `CREATE`, `ALTER`, `DROP`, `UPDATE`, `DELETE` или `TRUNCATE` и не изменяет объекты/строки базы.
Он не требует перезапуска сайта IIS или Windows-службы.
Исполняемый код сайта и агента не изменён.

Это статически проверенный патч; реальное выполнение SSMS/SQL Server
должно быть подтверждено на целевой машине.
