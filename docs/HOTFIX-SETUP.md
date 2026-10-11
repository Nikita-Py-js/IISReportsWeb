# SETUP-FIX1: подключение к SQL и создание закрытой папки конфигурации

[← README](../README.md) · [Чистая установка](INSTALL.md)

## Две независимые ошибки

**SQL Network Interfaces, error: 25** возникла при `SqlConnection.Open()`.
Присланный вывод не содержит фактического значения SQL-сервера в неудачном вызове,
поэтому точная причина не установлена. Сначала проверьте экземпляр и значение
`$dbArgs.SqlServer`, а не только переменную `$sqlServer`.

`Test-SqlConnectionBuilder.ps1` использует синтетические данные и **не подключается к SQL**.
Его PASS не подтверждает доступность вашего сервера. Старое исправление ключа
`Data Source` сохранено; новая ошибка сама по себе не означает возврат той ошибки.

**«Сбой выполнения программы icacls.exe: Неверно задано имя папки»** в данном отчёте
возник при запуске внешней программы. Это не подтверждённый ответ icacls «Отказано в доступе».
Возможна проблема рабочего каталога запуска; по одному сообщению это не доказано.
Текущая папка PowerShell и `[Environment]::CurrentDirectory` могут различаться.

## Что изменено

- В `New-RestrictedDirectory` запуск `icacls.exe` заменён API .NET Framework.
- Принимается абсолютный локальный путь. Корень диска, URI, относительные пути,
  недопустимые символы и reparse-point в пути отклоняются.
- Проверяется результирующий DACL: наследование отключено, Administrators
  (`S-1-5-32-544`) и SYSTEM (`S-1-5-18`) имеют наследуемый FullControl.
- Заполненная папка с другими правами не изменяется. Выберите новую выделенную папку.
- `New-InstallConfig.ps1` проверяет шаблоны и параметры до настройки прав.
- `Test-SetupPaths.ps1` проверяет временную папку, права и сохранение XML на Windows.
- `Test-SqlConnection.ps1` открывает **один выбранный экземпляр**, выполняет только
  SELECT и показывает сервер, экземпляр, базу и логин. Ничего не создаёт.
- Существующие конфиги не перезаписываются. SQL, C# и веб-интерфейс не изменены.
- Исправления BUILD-FIX1 и SQLCONN-FIX1 сохранены. Версия приложения — 3.1.0, схемы — 310.

Другие установщики используют собственные внешние команды. Это исправление не объявляет
устранёнными все возможные проблемы запуска EXE на сервере.

## Установка исправления

Используйте **Windows PowerShell 5.1 x64 от администратора**, не PowerShell 7.

Сохраните резервную копию распакованного проекта вне его каталога.
Распакуйте `IISReports-3.1.0-SETUP-FIX1-patch.zip` поверх
`C:\Deploy\IISReports-3.1.0`. ZIP содержит полные файлы, включая BUILD-FIX1;
отдельно склеивать фрагменты не нужно. В каталог работающего сайта ничего не копируйте.

```powershell
$ErrorActionPreference = 'Stop'
$pkg = 'C:\Deploy\IISReports-3.1.0'

if (-not (Test-Path -LiteralPath $pkg -PathType Container)) {
    throw 'Не найден каталог проекта.'
}
Set-Location -LiteralPath $pkg
[Environment]::CurrentDirectory = (Get-Location).ProviderPath

& "$pkg\tools\Verify-Package.ps1"
& "$pkg\tools\Test-PowerShellSyntax.ps1"
& "$pkg\tools\Test-SetupPaths.ps1"
& "$pkg\tools\Test-SqlConnectionBuilder.ps1"
```

`Test-SetupPaths.ps1` создаёт и удаляет только собственную папку с GUID внутри
`C:\Deploy\IISReports-setup-tests`. Сайт, служба, SQL и рабочие конфиги не меняются.

## Найдите правильный экземпляр SQL

```powershell
Get-Service |
    Where-Object { $_.Name -match '^(MSSQLSERVER|MSSQL\$.*)$' } |
    Select-Object Name, DisplayName, Status
```

| Служба на локальном сервере | Обычное значение `$sqlServer` |
|---|---|
| `MSSQLSERVER` | `'localhost'` |
| `MSSQL$SQLEXPRESS` | `'localhost\SQLEXPRESS'` |
| `MSSQL$NAME` | `'localhost\NAME'` |

Используйте экземпляр с нужной базой, а не любой доступный. Если есть SQL-алиас,
фактический сервер проверьте по результату запроса ниже.

В PowerShell достаточно **одной** обратной косой черты. Не переносите двойное
экранирование из JSON. Значение не должно быть HTTP-адресом или полной строкой
`Server=...;Database=...`. Для явного TCP-порта используют `tcp:sql-host,1433`
с фактическим портом сервера.

### Переменные и hashtable

```powershell
$sqlServer = 'previous-endpoint'
$dbArgs = @{ SqlServer = $sqlServer }

$sqlServer = 'localhost'
# $dbArgs.SqlServer всё ещё содержит previous-endpoint!
$dbArgs.SqlServer = $sqlServer
```

После изменения `$sqlServer` пересоздайте **и `$dbArgs`, и `$newConfig`**.
Не публикуйте полную строку подключения или пароли для диагностики.

## Реальная проверка соединения

Пример для локального экземпляра по умолчанию:

```powershell
$sqlServer = 'localhost'
$db = 'IISReports'
$trustSqlCertificate = $false

$probe = @{
    SqlServer = $sqlServer
    Database = 'master'
    TrustServerCertificate = $trustSqlCertificate
}
& "$pkg\tools\Test-SqlConnection.ps1" @probe
```

Ожидается PASS и значения `ServerName`, `InstanceName`, `DatabaseName`, `LoginName`.
Тест проверяет установочную учётную запись, а не будущий аккаунт службы.

Проверка сертификата включена по умолчанию. Сохраните ранее осознанно выбранную
политику для своего стенда; **не отключайте проверку сертификата как решение error 25
или ошибки прав на каталог**. Для SQL-аутентификации добавьте
`AdminCredential = (Get-Credential)` и сохраните его в дальнейших аргументах установки.

После успешного подключения:

```powershell
$dbArgs = @{
    SqlServer = $sqlServer
    Database = $db
    TrustServerCertificate = $trustSqlCertificate
}
# При SQL-аутентификации здесь также нужен AdminCredential.
& "$pkg\tools\Initialize-Database.ps1" @dbArgs -VerifyOnly
```

Если выделенная база/схема ещё не инициализирована, намеренно используйте
`-CreateDatabase` вместо `-VerifyOnly`. Не указывайте эти ключи вместе.
Существующие данные не очищаются.

## Повторное создание конфигов

Укажите свою Windows-учётную запись и фактический публичный адрес браузера:

```powershell
$configDir = 'C:\Deploy\IISReports-config'
$editor = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$publicUrl = 'https://reports.example.test:8443/' # замените своим адресом

$newConfig = @{
    ConfigDirectory = $configDir
    SqlServer = $sqlServer
    Database = $db
    Editor = $editor
    PublicUrl = $publicUrl
    TrustServerCertificate = $trustSqlCertificate
}
& "$pkg\tools\New-InstallConfig.ps1" @newConfig

Test-Path -LiteralPath (Join-Path $configDir 'Web.config')
Test-Path -LiteralPath (Join-Path $configDir 'agent-local.config')
```

При SQL-аутентификации дополнительно задайте **разные**
`WebSqlCredential` и `AgentSqlCredential` согласно [DATABASE.md](DATABASE.md).
Не используйте установочный административный логин для сайта и службы.

Если файлы уже существуют, скрипт не перезапишет их. Сохраните их и выберите новую
пустую выделенную папку либо проверьте конфигурацию локально.
Не применяйте ограничение ACL ко всему диску, `C:\Windows` или `C:\Deploy`.

## Проверки и ограничения

Переносимые проверки согласованности исходников не заменяют компилятор PowerShell
и не подтверждают работу NTFS. В среде подготовки не выполнялись новые PowerShell-
скрипты на Windows, реальные ACL-операции и подключение к SQL. Для приёмки запустите
включённые тесты на сервере.

При повторном сбое нужны первое сообщение об ошибке и следующие не секретные значения:

```powershell
Get-Location
[Environment]::CurrentDirectory
$dbArgs.SqlServer
$newConfig.ConfigDirectory
```

Не присылайте пароли, полные строки подключения, cookie или CSRF-токены.

## Официальные источники

- [PowerShell: Get-Location и Environment.CurrentDirectory](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-location)
- [.NET Framework: Directory.SetAccessControl](https://learn.microsoft.com/en-us/dotnet/api/system.io.directory.setaccesscontrol?view=netframework-4.8.1)
- [Защита наследования ACL](https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.objectsecurity.setaccessruleprotection)
- [Синтаксис подключения к SQL](https://learn.microsoft.com/en-us/dotnet/framework/data/adonet/connection-string-syntax)
