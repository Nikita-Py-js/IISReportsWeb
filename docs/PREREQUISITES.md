# Предварительные требования

[← README](../README.md) · [Далее: установка](INSTALL.md)

## Целевая конфигурация

| Компонент | Требование |
|---|---|
| ОС | Windows Server x64; для новой установки ориентируйтесь на Server 2022/2025 |
| IIS | ASP.NET 4.x, .NET Extensibility, ISAPI, Static Content, Default Document, Windows Authentication, средства управления |
| Среда выполнения | .NET Framework **4.8 или 4.8.1**, не .NET 8/9/10 вместо Framework |
| Shell установки | Windows PowerShell **5.1 x64**, повышенные права |
| SQL | Microsoft SQL Server локально или по сети; для новой установки — 2022/2025 подходящей редакции |
| Совместимость БД | SQL-скрипты требуют уровень не ниже 110; это нижняя граница синтаксиса, не рекомендация старых SQL |
| Браузер | Современный Edge/Chrome с разрешённой Windows-аутентификацией для адреса панели |
| TLS | Доверенный сертификат для внешнего адреса; доступ к private key для IIS |
| Данные | IIS W3C `.log`, доступные файловой системе сборщика |

Это целевые требования проекта, а не утверждение, что каждая комбинация ОС/SQL прошла тестирование. SSMS удобен, но **не обязателен**: скрипты SQL используют встроенный `System.Data.SqlClient`. Visual Studio, Node.js, Python и NuGet для работы сайта/службы не требуются.

## Если на сервере установлен только IIS

Сначала установите/проверьте компоненты IIS:

```powershell
$pkg = 'C:\Deploy\IISReports-3.0.2'
& "$pkg\tools\Install-Prerequisites.ps1" -InstallMissing
```

Скрипт устанавливает только недостающие Windows role services через `Install-WindowsFeature`. Он не удаляет существующие сайты, не открывает firewall, не скачивает SQL/.NET и не выполняет автоматическую перезагрузку.

Имена ролей содержат `45` (`Web-Asp-Net45`, `Web-Net-Ext45`), даже когда используется .NET Framework 4.8. Выбирать в пуле следует **CLR v4.0 / Integrated**, а не «No Managed Code». Это ASP.NET Framework, не ASP.NET Core.

[Установка IIS/ASP.NET — Microsoft](https://learn.microsoft.com/en-us/iis/application-frameworks/scenario-build-an-aspnet-website-on-iis/configuring-step-1-install-iis-and-asp-net-modules).

### Проверка Framework

```powershell
Get-ItemPropertyValue `
  'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' `
  -Name Release
```

Минимальный `Release` для 4.8 — `528040`. Если меньше — установите подходящий Framework с официального сайта Microsoft, выполните запрошенную перезагрузку и повторите проверку.

[Таблица Release](https://learn.microsoft.com/en-us/dotnet/framework/install/how-to-determine-which-versions-are-installed) · [Установка Framework](https://learn.microsoft.com/en-us/dotnet/framework/install/on-windows-and-server).

.NET 3.5 и классический ASP этому проекту не нужны. .NET Hosting Bundle для ASP.NET Core не заменяет требуемую регистрацию ASP.NET Framework.

## Установка SQL с нуля

Один из вариантов для небольшого стенда — отдельный экземпляр SQL Server Express. Для больших журналов оцените редакцию с достаточными ресурсами. По документации Microsoft лимит реляционной БД Express 2022 — 10 ГБ, Express 2025 — 50 ГБ; это ограничения конкретных версий, не рекомендация бесконечного хранения.

[Редакции SQL 2022](https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2022?view=sql-server-ver16) · [SQL 2025 Express](https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2025?view=sql-server-ver17).

В мастере SQL Setup:
1. Выберите **New standalone installation** и **Database Engine Services**.
2. Запишите имя экземпляра, например `SQLEXPRESS`; оно не обязательно такое на вашем сервере.
3. Для локальной схемы установки выберите Windows Authentication.
4. В **SQL Server administrators** добавьте аккаунт, из-под которого будете выполнять установочные SQL-скрипты.
5. Завершите установку и убедитесь, что служба SQL запущена.

Windows-администратор не становится SQL-администратором автоматически. [Официальная инструкция мастера SQL Setup](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-from-the-installation-wizard-setup).

Developer-редакцию не следует считать лицензией для рабочего production-сервера; сверяйте условия выбранной редакции. SQL Server Agent этому проекту не нужен: задачи выполняет собственная Windows-служба.

Не используйте LocalDB как замену постоянно работающему экземпляру SQL для службы. При использовании удалённой БД следуйте [DATABASE.md](DATABASE.md).

## Сертификаты SQL

По умолчанию создаётся строка `Encrypt=True;TrustServerCertificate=False`. SQL-сертификат должен быть доверенным, а имя сервера — соответствовать сертификату.

Для **изолированного локального стенда** возможен явный `-TrustServerCertificate` в командах настройки. Это оставляет шифрование, но отключает проверку подлинности SQL-сервера. На рабочей сети настройте доверенный сертификат и уберите этот флаг из конфигурации.

[Синтаксис подключения и параметры TLS](https://learn.microsoft.com/en-us/dotnet/framework/data/adonet/connection-string-syntax).

## Ресурсы и сеть

Универсальный минимальный размер диска в проекте не зашит: хранение включает исходные строки, разобранные запросы, индексы и историю мониторинга. Сделайте пробный импорт и измерьте рост базы. Автоматического retention в 3.0.2 нет.

Если SQL локален, не открывайте его порт наружу. Для удалённого SQL разрешите только соединения от нужных узлов. Входящий порт панели также ограничьте административной сетью/VPN. Исходящие соединения сборщика разрешайте только к согласованным проверяемым адресам и webhook.

[Настройка SQL firewall](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-a-windows-firewall-for-database-engine-access).
