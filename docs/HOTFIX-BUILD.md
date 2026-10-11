# BUILD-FIX1: не найден `build\UnitTests.exe`

[← README](../README.md)

Исправление скрипта сборки IIS Reports 3.1.0. Версия приложения и схема MSSQL не меняются.
Обновляются только инструменты сборки, документация и контрольные суммы.

## Что показывает ошибка

Сообщение `UnitTests.exe не распознано ...` означает, что к моменту запуска тестового
EXE файл не был найден по ожидаемому пути. Само сообщение **не устанавливает причину**.

В прежнем `Build-And-Test.ps1` проверялся `$LASTEXITCODE` после вызова компилятора,
но не проверялось наличие каждого результата. Вывод компилятора не сохранялся
в отдельные журналы. По одному этому выводу нельзя доказать ни ошибку C#,
ни блокировку защитным ПО, ни проблему передачи аргументов.

Проверка SHA256 подтверждает совпадение файлов с манифестом, а проверка синтаксиса
PowerShell — разбор текста скриптов. Ни одна из них не заменяет компиляцию C#.

## Что меняется

- Компилятор запускается по полному пути через `System.Diagnostics.Process`.
- Для каждой сборки создаётся файл аргументов `.rsp`: пути исходников и результата
  заключены в кавычки, в том числе для каталогов с пробелами.
- Скрипт явно ждёт завершения процесса и проверяет его собственный `ExitCode`.
  Состояние `$LASTEXITCODE` из внешней сессии не используется.
- Стандартный вывод и ошибки считываются параллельно и сохраняются отдельно.
- После каждой компиляции проверяются существование, ненулевой размер и читаемые
  метаданные .NET-сборки. Нулевого кода возврата недостаточно.
- Сначала компилируется и запускается маленький `CompilerProbe.exe`, затем проект.
- Все результаты создаются в новой папке `build\.work\<идентификатор запуска>`.
  Старый тестовый EXE не может быть принят за результат новой компиляции.
- Тесты не пропускаются. Файлы публикуются в `build` и создаётся `BUILDINFO.json`
  только после успешной сборки всех компонентов и прохождения локальных тестов.
- При неудаче маркер успешной сборки удаляется. SQL, сайт, служба и история не меняются.

Формат `BUILDINFO.json` совместим с существующим `Make-Windows-Release.ps1`.
Файлы в `.work` сохраняются для диагностики; устанавливать их вместо успешной
сборки нельзя. Новые зависимости или пакеты для сборки не добавлены.

## Установка исправления

Скачайте `IISReports-3.1.0-BUILD-FIX1-patch.zip` в `C:\Deploy`.
Это дополнение **только к полному комплекту 3.1.0**, не к 3.0.2.

В Windows PowerShell:

```powershell
$ErrorActionPreference = 'Stop'
$pkg = 'C:\Deploy\IISReports-3.1.0'
$patch = 'C:\Deploy\IISReports-3.1.0-BUILD-FIX1-patch.zip'

if (-not (Test-Path -LiteralPath "$pkg\VERSION")) {
    throw 'Project VERSION file not found.'
}
if ((Get-Content -LiteralPath "$pkg\VERSION" -Raw).Trim() -ne '3.1.0') {
    throw 'This patch requires IIS Reports 3.1.0.'
}

# Резервная копия скрипта вне дерева исходников.
$backup = 'C:\Deploy\IISReports-build-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $backup | Out-Null
Copy-Item -LiteralPath "$pkg\tools\Build-And-Test.ps1" -Destination $backup

# В ZIP находятся целые заменяемые файлы и новые манифесты.
Expand-Archive -LiteralPath $patch -DestinationPath $pkg -Force
& "$pkg\tools\Verify-Package.ps1"

# Отдельная сессия исключает влияние пользовательского профиля.
& "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile -File "$pkg\tools\Build-And-Test.ps1"

if ($LASTEXITCODE -ne 0) {
    throw 'Build failed. Inspect the current build logs before continuing.'
}
```

Полный архив `IISReports-3.1.0-BUILD-FIX1-complete.zip` содержит те же исправления.
Внутри него по-прежнему папка `IISReports-3.1.0`. Полный архив удобнее распаковать
в новую папку подготовки; рабочие конфиги сайта и агента в него не входят.

## Результат успешной сборки

В консоли должны последовательно появиться `PASS compiler probe`,
сообщения `PASS artifact`, реальные результаты тестов `PASS ...`, `PASS TOTAL ...`
и итог:

```text
SUCCESS: 6 artifacts verified; ... local unit tests passed.
```

В `build` должны находиться:

```text
IISReports.Agent.exe
IISReports.WebCore.dll
IISReports.HandlerTest.dll
UnitTests.exe
SqlIntegrationTests.exe
DiscoverySqlTests.exe
BUILDINFO.json
```

Три EXE с тестами не нужны для службы. Тестовые DLL не копируются в `web\Bin`.
SQL-интеграция и HTTP/CSRF тестируются отдельно по [TESTING.md](TESTING.md).
Не используйте `-SkipBuild`, пока текущая сборка не завершилась успешно.

## Где искать первичную причину

Каждый запуск создаёт отдельную папку:

```text
build\logs\<идентификатор запуска>\
    build.log
    00-CompilerProbe.rsp
    00-CompilerProbe.stdout.log
    00-CompilerProbe.stderr.log
    00-CompilerProbe-run.stdout.log
    00-CompilerProbe-run.stderr.log
    01-WebCore.rsp
    ...
    04-UnitTests.rsp
    04-UnitTests.stdout.log
    04-UnitTests.stderr.log
    07-UnitTests-run.stdout.log
    07-UnitTests-run.stderr.log
```

Файлы последующих стадий появляются только после прохождения предыдущих.
Указатель на общий журнал последнего запуска: `build\LAST-BUILD-LOG.txt`.

```powershell
$pkg = 'C:\Deploy\IISReports-3.1.0'
$log = (Get-Content -LiteralPath "$pkg\build\LAST-BUILD-LOG.txt" -Raw).Trim()
Get-Content -LiteralPath $log -Tail 100
```

- `00-CompilerProbe` не создал EXE: сначала разбирается работа компилятора и среды,
  а не код сайта.
- В журнале есть `error CS...`: исправляется указанная ошибка компиляции.
- Код выхода нулевой, но файл исчез: проверьте путь в `.rsp` и события локального
  защитного ПО; сам по себе этот результат ещё не доказывает карантин.
- EXE есть, но не запускается: сохраните точное сообщение запуска и проверьте
  ограничения запуска программ в этой среде.
- Тест вывел `FAIL`: сборка останавливается; пропускать тест нельзя.

Не отключайте Defender/AppLocker и не добавляйте широких исключений ради сборки.
Не создавайте пустой `UnitTests.exe` и не копируйте тестовый EXE из старого выпуска.

## Что проверено при подготовке

Проверены изменения по исходному тексту, согласованность проекта, ссылки Markdown
и контрольные суммы архива. Отдельный отчёт по защитным проверкам скрипта:
`tests/build-driver-static-results.json`.

**Это не выполнение PowerShell или C#**. В среде подготовки нет Windows PowerShell
5.1 и .NET Framework. Новый драйвер сборки необходимо выполнить на Windows;
ошибка, специфичная для сервера, может потребовать дополнительного исправления
после получения журнала.

## Документация Microsoft

- [Файлы аргументов C# и NoConfig](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-options/miscellaneous)
- [Параметр выходного файла C#](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-options/output)
- [Process.WaitForExit](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.waitforexit?view=netframework-4.8.1)
- [LASTEXITCODE](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables?view=powershell-5.1#lastexitcode)
