# Технические источники

[← README](../README.md)

Поведение конкретного IIS Reports описано по приложенному коду. Внешние требования и механизмы сверялись с документацией поставщиков при подготовке выпуска 11.10.2026. Эти ссылки не означают, что Microsoft/OWASP проверяли или одобряли данный проект.

| Тема | Первичный источник |
|---|---|
| IIS / ASP.NET role services | [Microsoft](https://learn.microsoft.com/en-us/iis/application-frameworks/scenario-build-an-aspnet-website-on-iis/configuring-step-1-install-iis-and-asp-net-modules) |
| Windows Authentication | [Microsoft](https://learn.microsoft.com/en-us/iis/configuration/system.webServer/security/authentication/windowsAuthentication/) |
| Учётные записи пула | [Microsoft](https://learn.microsoft.com/en-us/iis/manage/configuring-security/application-pool-identities) |
| Framework Release registry key | [Microsoft](https://learn.microsoft.com/en-us/dotnet/framework/install/how-to-determine-which-versions-are-installed) |
| Установка Framework | [Microsoft](https://learn.microsoft.com/en-us/dotnet/framework/install/on-windows-and-server) |
| SQL Setup | [Microsoft](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-from-the-installation-wizard-setup) |
| SQL 2022 редакции | [Microsoft](https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2022?view=sql-server-ver16) |
| SQL 2025 изменения | [Microsoft](https://learn.microsoft.com/en-us/sql/sql-server/what-s-new-in-sql-server-2025?view=sql-server-ver17) |
| SQL firewall | [Microsoft](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-a-windows-firewall-for-database-engine-access) |
| Connection string / TLS | [Microsoft](https://learn.microsoft.com/en-us/dotnet/framework/data/adonet/connection-string-syntax) |
| CSRF Origin и proxy | [OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html) |
| Защита исходящих запросов | [OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html) |

Перед установкой проверяйте актуальную поддержку и лицензию конкретной версии ОС, SQL и используемой базы GeoIP/ASN. Не загружайте установщики из случайных ссылок в issue.

## Автоматические источники 3.1.0

- [IIS: per-site logFile, форматы, каталоги и File/ETW](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/sites/site/logfile/).
- [Microsoft.Web.Administration.SiteLogFile](https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.administration.sitelogfile?view=iis-dotnet).
- [IIS: централизованное журналирование](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/log/).
- [New-ScheduledTaskTrigger](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasktrigger?view=windowsserver2025-ps).
- [GRANT прав на отдельные столбцы SQL](https://learn.microsoft.com/en-us/sql/t-sql/statements/grant-object-permissions-transact-sql?view=sql-server-ver17).

Документация Microsoft описывает платформу. Конкретные интервалы, поведение флажков, snapshot и SQL Revision — реализация этого проекта, проверяемая его тестами.
