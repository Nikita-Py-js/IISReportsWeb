# Результаты Windows-сборки

В исходной поставке эта папка не содержит готового EXE.

Из корня проекта на Windows:

```powershell
.\tools\Build-And-Test.ps1
```

Будут созданы EXE службы, тестовые EXE/DLL и BUILDINFO.json. Только `IISReports.Agent.exe` нужен для установки службы; конфигурация создаётся отдельно.

Не публикуйте тестовые DLL в `web/Bin`: App_Code уже компилирует те же классы. Для полного Windows-дистрибутива с EXE:

```powershell
.\tools\Make-Windows-Release.ps1 -SkipBuild
```
