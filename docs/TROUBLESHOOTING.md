# Устранение ошибок

[← Установка](INSTALL.md)

Не запускайте следующий шаг после ошибки. Не удаляйте таблицы, Web.config или историю для обхода проверки.

| Симптом | Причина / действие |
|---|---|
| `\tools\Install-Web.ps1` не найден | Раньше терялась `$pkg`. Теперь используйте полный путь к Install.ps1 и `-SettingsFile` |
| Не найден `...\IISReports-config\Web.config` | Не завершён **Config**. Он создаёт папку и оба файла; пустая папка не заменяет конфиг |
| Конфиги уже существуют | Config проверит совпадающие файлы; при несовпадении остановится без перезаписи |
| `Keyword not supported: DataSource` | Старый Setup.Common.ps1. В комплекте 3.1.1 используется ключ `Data Source` |
| `SQL Network Interfaces, error 25` | Проверьте реальный экземпляр, не URL/двойные обратные слеши. Запустите Test-SqlConnection |
| «Цепочка сертификатов … не имеющим доверия» | SQL найден, но сертификат SQL не проходит проверку. Настройте доверие; для теста разрешите TrustSqlCertificate явно |
| `UnitTests.exe` отсутствует | Сборка не завершилась. Читайте build\LAST-BUILD-LOG.txt, не подставляйте EXE старой версии |
| «Неверно задано имя папки» при icacls | Использовался старый установщик. Рабочие ACL-операции текущей версии не вызывают icacls |
| `ERROR: expected 18 tables` | Старый проверочный SQL. В схеме 310 есть 18 базовых таблиц и DiscoveryState; удалять 19-ю таблицу нельзя |
| SITE не найден | SiteName — объект IIS, не имя папки. Проверьте `appcmd list site` |
| HTTP 403.14 | В IIS опубликован весь архив вместо web/ либо не найден Default Document index.html |
| `authentication_required` | В IIS не передан Windows-пользователь: Windows Authentication включена, Anonymous выключена |
| `reader_role_required` / `editor_role_required` | Вход успешен, но роль приложения не назначена. Проверяйте пользователя запроса в whoami |
| `csrf_origin` | PublicOrigin не совпадает с адресом браузера: протокол, хост, порт |
| `csrf_missing` / `csrf_invalid` | Перезагрузите страницу для новой пары cookie+token; повторите изолированный HTTP-тест |
| Неверный CSRF возвращает 2xx | Проверка НЕ пройдена. Не отключайте проверку и не запускайте агент; проверьте установленный код |
| `agentOnline=false`, heartbeat отсутствует | Служба не запущена/не подключилась к SQL. Посмотрите Get-Service и agent logs |
| `discovery error` / старый снимок | Проверьте задачу IISReports-DiscoverSites и %ProgramData%\IISReports\Discovery |
| Источник `waiting_directory` | IIS ещё не создал каталог. Проверьте Logging и реальные запросы |
| Служба Running, записей 0 | Процесс работает, но это не подтверждает импорт: смотрите источники, SQL-доступ, формат и ошибки |

## Самостоятельная проверка конфигов

```powershell
& 'C:\Deploy\IISReports-3.1.1\tools\Test-InstallConfig.ps1' `
    -ConfigDirectory 'C:\Deploy\IISReports-config'
```

Пароли и полный ConnStr не выводятся.

## Журнал сборки

```powershell
$path = (Get-Content 'C:\Deploy\IISReports-3.1.1\build\LAST-BUILD-LOG.txt' -Raw).Trim()
Get-Content -LiteralPath $path -Tail 100
```

## Служба и задача

```powershell
Get-Service IISReportsAgentV3
Get-ScheduledTask -TaskName IISReports-DiscoverSites
Get-ScheduledTaskInfo -TaskName IISReports-DiscoverSites
Get-ChildItem 'C:\Services\IISReportsAgentV3\logs'
```

Если пути изменены в `.psd1`, используйте их.

## Частично неудачная установка

Чистый установщик не выполняет автоматический глобальный откат IIS/SQL. Если уже создан сайт или служба, сначала проверьте реальные пути, конфигурации и журнал. Не удаляйте объект с совпавшим именем наугад: он может принадлежать рабочей установке. `Check-Deployment.ps1` — чтение состояния, не восстановление.

Для возврата используйте сохранённые резервные копии и [UPGRADING.md](UPGRADING.md). Не копируйте `.cs`-резервные копии в App_Code: они тоже компилируются.

## Что присылать для диагностики

Первую ошибку, имя шага, версию из VERSION и последние строки журнала. Не публикуйте SQL-пароли, полный ConnStr, CSRF-токены, cookie, private key или реальные строки журналов с чувствительными параметрами.
