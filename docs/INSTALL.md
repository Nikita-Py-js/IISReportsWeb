# Чистая установка IIS Reports 3.1.1

[← README](../README.md) · [Настройки](SETTINGS.md) · [Ошибки](TROUBLESHOOTING.md)

Эта инструкция предназначена для **новой установки**. Для существующего сайта — [UPGRADING.md](UPGRADING.md).

## Перед началом

Выполняйте команды в **Windows PowerShell 5.1 x64 от администратора** (`powershell.exe`, не `pwsh`). SQL Server должен быть установлен отдельно и доступен. Для создания базы и логинов текущему Windows-аккаунту нужны административные права в SQL; локальный администратор Windows не обязательно является администратором SQL.

Скрипты не скачивают SQL Server/.NET, не создают DNS/сертификаты, не открывают firewall и не перезагружают Windows. Они не обходят доменные политики.

После любой ошибки остановитесь на этом шаге. Не копируйте все команды в один файл без обработки ошибок.

## 1. Распакуйте проект и выберите один файл параметров

Ожидаемое расположение:

```text
C:\Deploy\IISReports-3.1.1\Install.ps1
C:\Deploy\IISReports-3.1.1\setup\
C:\Deploy\IISReports-3.1.1\tools\
```

Не публикуйте всю эту папку в IIS. Установщик сам скопирует только `web/`.

Если Windows блокирует скачанные скрипты, сначала проверьте происхождение ZIP и его SHA256 (`Get-FileHash -Algorithm SHA256`). Затем для **проверенной распаковки** можно снять метку загрузки:

```powershell
Get-ChildItem -LiteralPath 'C:\Deploy\IISReports-3.1.1' -Recurse -File |
    Unblock-File
```

Не используйте глобальный `ExecutionPolicy Bypass`. При корпоративном `AllSigned` нужны подписи скриптов вашей организации; установщик и задача обнаружения не обходят эту политику.

```powershell
Set-Location -LiteralPath 'C:\Deploy\IISReports-3.1.1'
.\tools\Verify-Package.ps1
```

Хеши проверяют целостность, не подлинность издателя.

Выберите **один** из режимов:

| Режим | Шаблон | Сертификат IIS |
|---|---|---|
| Локальная проверка на сервере | `setup\LocalHttp.psd1` | Не нужен; доступ только к loopback HTTP |
| HTTPS непосредственно в IIS | `setup\Https.psd1` | Нужен действительный сертификат с закрытым ключом |
| HTTPS завершает уже настроенный reverse proxy | `setup\ReverseProxy.psd1` | В IIS не нужен; сертификат находится на прокси |

Пример для локальной проверки:

```powershell
if (Test-Path 'C:\Deploy\IISReports.setup.psd1') {
    throw 'Файл параметров уже существует. Откройте и проверьте его, не перезаписывайте.'
}
Copy-Item '.\setup\LocalHttp.psd1' 'C:\Deploy\IISReports.setup.psd1'
notepad 'C:\Deploy\IISReports.setup.psd1'
```

Для другого режима замените только имя шаблона в `Copy-Item`.

### Обязательно проверьте значения

- `Editor`: реальный аккаунт **браузерного оператора**, например `SERVER\Администратор`. `whoami` показывает аккаунт текущего PowerShell; он может отличаться.
- `SqlServer`: имя экземпляра SQL, не URL сайта. Для экземпляра по умолчанию — `localhost`, для именованного — `SERVER\INSTANCE` (одна обратная косая черта).
- `Database`: отдельная база IIS Reports.
- `TrustSqlCertificate`: `$false` по умолчанию. `$true` — только осознанное исключение для доверенного тестового SQL; шифрование остаётся включённым, проверка сертификата обходится.
- `PublicUrl`: **адрес браузера**, включая протокол и нестандартный порт. Например `https://reports.example.test:8443/`.
- `SiteName` и `AppPoolName`: новые свободные имена IIS; это не имена папок.
- `CertificateThumbprint`: для `Https` заполните настоящим отпечатком из `Cert:\LocalMachine\My`. В остальных режимах оставьте `''`.

Полное объяснение: [SETTINGS.md](SETTINGS.md).

**Больше не нужны** переменные `$sourceSiteId`, `$sourceName` и `$logRoot`: источники обнаруживаются автоматически.

## 2. Проверьте план

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step Check
```

Здесь нет установки. Проверьте выведенные имена, SQL и пути.

`WebConfigExists=False` / `AgentConfigExists=False` на этом этапе нормально. Папку конфигураций и оба файла создаст шаг **Config**, не шаг Web.

Все следующие команды используют этот же сохранённый файл. Их можно выполнять из нового окна PowerShell: переменные из предыдущего окна не нужны.

## 3. Установите недостающие компоненты Windows/IIS

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step Prerequisites
```

Ожидается `PASS IIS/.NET prerequisites`. При требовании перезагрузки выполните её вручную, затем повторите этот шаг.

Для .NET Framework ниже 4.8 сначала установите подходящий для вашей Windows пакет Microsoft. IIS ASP.NET/Windows Authentication проверяются отдельно от самого IIS.

## 4. Соберите и проверьте код

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step Build
```

Успех означает наличие проверенных EXE/DLL, прохождение локальных C#-тестов и появление `build\BUILDINFO.json`.

При ошибке не устанавливайте частичные результаты. Журнал:

```powershell
$log = (Get-Content 'C:\Deploy\IISReports-3.1.1\build\LAST-BUILD-LOG.txt' -Raw).Trim()
Get-Content -LiteralPath $log -Tail 100
```

Не копируйте `IISReports.WebCore.dll` или тестовые DLL в `web\Bin`: ASP.NET компилирует те же классы из `App_Code`.

## 5. Подключитесь к SQL и подготовьте схему

Для основного сценария `SqlAuthentication='WindowsLocal'` SQL должен находиться на той же машине.

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step Database
```

Шаг сначала **реально подключается** к `master`, затем применяет SQL-файлы и проверяет результат.

`AllowCreateDatabase=$true` разрешает создание отсутствующей базы. Существующие таблицы/записи не удаляются. Версия схемы остаётся **310**: 18 базовых таблиц плюс `DiscoveryState` (19 всего), представление `ir3.CurrentRequests`, роли `ir3_web`, `ir3_agent`. Дополнительные пользовательские таблицы не считаются ошибкой.

Ожидается `Schema verification completed`; все четыре DEFAULT должны иметь `OK`. Теперь неверный DEFAULT останавливает шаг, а не только выводится в таблице.

Ошибка доверия SQL-сертификату относится к **сертификату SQL**, не к сертификату сайта. Исправьте доверие или явно измените `TrustSqlCertificate` для тестовой среды. Настройка не меняется автоматически.

Удалённый SQL / SQL-логины: [DATABASE.md](DATABASE.md). Для административного входа по SQL у команды есть `-AdminCredential (Get-Credential)`; пароль в файл настроек не записывается.

## 6. Создайте папку конфигураций И ОБА файла

**Этот шаг нельзя пропускать. Одной пустой папки недостаточно.**

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step Config
```

По умолчанию результат:

```text
C:\Deploy\IISReports-config\         создаётся автоматически с закрытыми ACL
├── Web.config                     конфигурация сайта
└── agent-local.config             конфигурация агента
```

Шаг проверит наличие обоих файлов, SQL, шифрование, PublicOrigin и оператора. Ожидается `PASS configuration pair`.

Проверка вручную:

```powershell
Test-Path -LiteralPath 'C:\Deploy\IISReports-config\Web.config'
Test-Path -LiteralPath 'C:\Deploy\IISReports-config\agent-local.config'
```

**Оба результата — `True`.** Если путь в `.psd1` другой, проверяйте его.

Повторный запуск Config:
- Совпадающие существующие файлы проверяются и остаются нетронутыми.
- Отсутствующий второй файл создаётся только после проверки первого.
- Несовпадающие настройки вызывают ошибку. Не удаляйте конфиги; исправьте файл параметров либо выберите новую папку.
- Непустая папка с неподходящими ACL не «исправляется» автоматически.

## 7. Установите веб-приложение

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step Web
```

До изменения IIS проверяются конфиги и сборка. Затем создаются отдельный пул и сайт; публикуется только `web/`, включается Windows Authentication, отключается Anonymous, задаётся `index.html`.

`WebRoot` должен быть пустым. Существующий сайт с другим путём, привязкой или файлами не перезаписывается. Полностью совпадающая установка распознаётся без повторного создания. Не меняйте имена произвольно, чтобы обойти конфликт работающего сайта.

Откройте именно `PublicUrl`:
- `Reports.ashx?action=whoami` — ожидаются `isAuthenticated=true`, `canRead=true`, `canEdit=true`.
- `Reports.ashx?action=csrf` — выдача токена. Сам токен никуда не публикуйте.

Отсутствие агента на этом этапе нормально. Ещё не ожидается успешный импорт.

## 8. Установите службу и автоматическое обнаружение

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step Agent
```

По умолчанию:

```text
C:\Services\IISReportsAgentV3\
├── IISReports.Agent.exe
├── IISReports.Agent.exe.config
└── logs\
```

Создаются служба `IISReportsAgentV3` (Manual, **Stopped**) и задача `IISReports-DiscoverSites`. Последняя публикует снимок IIS в `%ProgramData%\IISReports\Discovery\sites.json` при старте Windows и далее раз в минуту.

Служба не запускается автоматически до этапа Start. Не регистрируйте сайты вручную и не создавайте фиктивные W3SVC1–3.

## 9. Выдайте SQL-права

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step Permissions
```

В локальном Windows-сценарии:
- `IIS APPPOOL\<AppPoolName>` получает роль `ir3_web`.
- `NT SERVICE\IISReportsAgentV3` получает роль `ir3_agent`.

Это не аккаунт Windows-оператора браузера. Приложению не выдаются `sysadmin`/`db_owner`. Уже существующие более широкие права не отзываются автоматически — проверьте их отдельно.

## 10. Проверьте защиту

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step SecurityTest
```

Проверяется фактический PublicUrl. Ожидаются отказы на GET-изменение, чужой Origin, отсутствующий/неверный токен и отсутствующую cookie. Корректный POST к `csrf-check` должен пройти **без задания в очереди**. Пустой набор изменения источников отклоняется.

Если HTTPS завершает прокси, он должен поддерживать выбранную Windows-аутентификацию. Не отключайте CSRF, не подменяйте PublicOrigin внутренним адресом и не обходите проверку TLS в HTTP-тесте.

## 11. Запустите агент

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step Start
```

Перед стартом снова проверяются SQL и HTTP/CSRF. После успеха службе задаётся delayed-auto и она запускается.

`Running` — состояние процесса, не доказательство успешного импорта. Перейдите к следующему шагу.

## 12. Проверьте результат

```powershell
& 'C:\Deploy\IISReports-3.1.1\Install.ps1' `
    -SettingsFile 'C:\Deploy\IISReports.setup.psd1' -Step Verify
```

В `Reports.ashx?action=health` ожидаются:
- `dbConnected=true`, `schemaInitialized=true`;
- `agentOnline=true` после первого heartbeat;
- успешное состояние discovery;
- рост `dbEntries` при наличии валидных W3C-строк.

В «Источниках» должны появиться реальные IIS-сайты. Флажки включены для впервые обнаруженных сайтов. **Снимите ненужные и нажмите «Сохранить выбор».**

Каталоги без файлов или с выключенным Logging могут оставаться пустыми. Отключённый источник сохраняет историю. Не используйте число запросов как единственную проверку работоспособности: смотрите ошибки и состояние каждого источника.

### Что означает успешный Verify

Шаг выполняет не только вывод таблицы файлов: он требует работающую службу, существующую задачу обнаружения и снимок IIS, затем обращается к настоящему `action=health`.

`HTTP 200` сам по себе недостаточен. `dbConnected`, `schemaInitialized`, `agentOnline`, `discoveryHealthy` и `healthy` должны быть `true`. Если служба только запущена, дождитесь первого прохода и повторите **Verify**, а не Database/Config/Web. Предупреждение источника нельзя исправить удалением базы: смотрите вкладку «Источники».

## После установки

Сохраните `.psd1`, подготовленные конфиги и резервную копию SQL. Они не должны попадать в публичный репозиторий. Ограничьте доступ к панели административной сетью; для сетевого доступа используйте HTTPS.

[Эксплуатация](OPERATIONS.md) · [Безопасность](SECURITY.md) · [Тестирование](TESTING.md)
