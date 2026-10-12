# Каталог результатов сборки

В исходной поставке нет готовых EXE/DLL. Этот каталог содержит только данную инструкцию.

На Windows выполните `Install.ps1 -SettingsFile <ваш .psd1> -Step Build`
либо `tools/Build-And-Test.ps1`. После успешных локальных тестов появятся:

- IISReports.Agent.exe
- IISReports.WebCore.dll
- IISReports.HandlerTest.dll
- UnitTests.exe
- SqlIntegrationTests.exe
- DiscoverySqlTests.exe
- BUILDINFO.json

Файлы `.dll` здесь служат для проверки компиляции, не копируйте их в `web/Bin`.
Установщику необходим полный результат успешной сборки, а не один вручную скопированный EXE.

Журналы — в `build/logs`, путь последнего журнала — `build/LAST-BUILD-LOG.txt`.
Ошибка сборки не должна обходиться запуском старого UnitTests.exe.

SQL-интеграционные EXE запускайте только на одноразовой тестовой базе по документации.
`Make-Windows-Release.ps1 -SkipBuild` упаковывает проверенные бинарные файлы после успешного Build.
