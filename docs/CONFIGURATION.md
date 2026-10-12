# Конфигурация

[← README](../README.md)

## Установочные параметры

Единый `.psd1`: [SETTINGS.md](SETTINGS.md). Его каждый раз читает `Install.ps1`.

Файл параметров не является Web.config и не содержит паролей. После его редактирования уже установленные рабочие файлы не изменяются автоматически.

## Подготовленные и рабочие конфиги

```text
ConfigDirectory\Web.config           -> WebRoot\Web.config
ConfigDirectory\agent-local.config   -> AgentRoot\IISReports.Agent.exe.config
```

Шаг Config создаёт закрытую папку и два файла. Web/Agent копируют их при чистой установке.

Оперативные изменения в рабочем конфиге не возвращаются автоматически в ConfigDirectory. Согласовывайте копии перед обновлениями. Рабочие параметры подключения нельзя заменять шаблонами.

## Основные ключи

- `ConnStr`: SqlClient, отдельно в web и agent. Для SQL-логинов нужны разные пользователи.
- `IISReportsAccessMode=windows`: способ допуска HTTP-запросов.
- `IISReportsEditors`, `IISReportsReaders`: Windows-аккаунты/группы через `;`.
- `IISReportsPublicOrigin`: внешний Origin.
- `IISReportsCheckHosts`, `IISReportsCheckPorts`, `IISReportsAllowHttpChecks`: разрешённые направления активных проверок.
- `IISReportsAutoDiscoveryEnabled`: автообнаружение в агенте.
- `IISReportsDiscoveryManifest`: защищённый снимок сайтов IIS.
- Остальные интервалы, пороги и ограничения находятся в `agent/IISReports.Agent.exe.config.example`.

Установка discovery добавляет рабочие параметры в конфиг службы. Не копируйте после неё старый agent-local.config поверх рабочего файла без проверки.

[Безопасность](SECURITY.md) · [Автообнаружение](AUTO-SOURCES.md)
