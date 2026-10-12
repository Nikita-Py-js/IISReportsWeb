# Параметры установки

[← Установка](INSTALL.md)

Один файл `.psd1` содержит параметры окружения. `Install.ps1` загружает его через `Import-PowerShellDataFile`, а не выполняет как скрипт. Не храните в нём SQL-пароли. Все логические значения — `$true` / `$false`, без кавычек.

| Ключ | Назначение |
|---|---|
| `ConfigDirectory` | Закрытая подготовительная папка. Шаг Config создаёт здесь Web.config и agent-local.config. Не папка сайта |
| `WebRoot` | Физическая папка опубликованного веб-приложения. При чистой установке должна быть пустой |
| `AgentRoot` | Папка службы вне wwwroot |
| `SiteName` | Имя объекта SITE в IIS; не имя каталога |
| `AppPoolName` | Имя отдельного пула приложения |
| `SqlServer` | SQL-экземпляр: `localhost`, `SERVER\INSTANCE`, `tcp:SERVER,PORT`. Не URL и не строка подключения целиком |
| `Database` | Отдельная база, например IISReports. Системные базы запрещены |
| `SqlAuthentication` | `WindowsLocal` для локального SQL; `SqlLogins` для раздельных SQL-логинов |
| `Editor` | Один реальный Windows-аккаунт или группа с правом менять настройки |
| `Readers` | Необязательный список Windows-аккаунтов/групп через `;` для чтения |
| `PublicUrl` | Публичный адрес браузера с протоколом и портом. Корневое приложение `/` |
| `BindingMode` | `Https`, `LocalHttp`, `ReverseProxy` |
| `BindingUrl` | Внутренняя IIS-привязка. Для Https/LocalHttp пустое значение означает PublicUrl |
| `CertificateThumbprint` | Только для HTTPS на IIS: отпечаток сертификата LocalMachine\My с закрытым ключом |
| `TrustSqlCertificate` | `$false` проверяет сертификат SQL. `$true` обходит его проверку, но не выключает Encrypt |
| `AllowCreateDatabase` | Разрешает создать отсутствующую базу. Не означает удаление существующей |

## Как найти SQL-экземпляр

На машине SQL:

```powershell
Get-Service | Where-Object {
    $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*'
} | Select-Object Name, Status
```

`MSSQLSERVER` — обычно `localhost` на этой же машине. `MSSQL$SQLEXPRESS` — `localhost\SQLEXPRESS`. Для удалённого SQL вместо localhost нужно имя SQL-машины. Если подключаетесь к удалённому серверу, список локальных служб его не показывает.

`localhost` означает компьютер, где выполняется команда/служба, не компьютер браузера. Проверить фактическое соединение:

```powershell
.\tools\Test-SqlConnection.ps1 -SqlServer 'localhost' -Database 'master'
```

Успех локального `Test-SqlConnectionBuilder.ps1` не означает доступность экземпляра: он не использует сеть.

## Сертификаты — два разных назначения

**SQL-сертификат** защищает соединение приложения с SQL. **HTTPS-сертификат IIS** защищает браузерное соединение. `TrustSqlCertificate` не заменяет `$certThumbprint` и не влияет на браузер.

Просмотр HTTPS-сертификатов:

```powershell
Get-ChildItem Cert:\LocalMachine\My |
    Select-Object Subject, Thumbprint, NotBefore, NotAfter, HasPrivateKey
```

Для Https необходимы закрытый ключ, срок действия и соответствие DNS-имени в SAN. Доверие браузера проверяйте отдельно.

## Три режима адресов

- `LocalHttp`: только `http://localhost:PORT/` или `http://127.0.0.1:PORT/`. Без сертификата, для локальной проверки.
- `Https`: браузер и IIS используют одинаковый HTTPS Origin.
- `ReverseProxy`: браузер использует HTTPS PublicUrl, прокси обращается к HTTP BindingUrl. Ограничьте backend firewall; не доверяйте произвольным Forwarded-заголовкам.

Если изменили `.psd1` после установки, рабочие конфиги **не обновляются автоматически**. Для Origin используйте `Set-IISReportsPublicOrigin.ps1`, затем согласуйте подготовленный Web.config и файл параметров. Не запускайте чистую установку поверх работающей.
