# Начните здесь

**Новая установка на сервере с IIS:** [docs/INSTALL.md](docs/INSTALL.md).

**Уже работающая v3:** [docs/UPGRADING.md](docs/UPGRADING.md).

Не публикуйте всю папку проекта в IIS. Для сайта нужен только `web/`; чистый установщик копирует его автоматически.

Требуются ASP.NET Framework 4.8, Windows Authentication и SQL Server. EXE собирается на Windows командой `tools/Build-And-Test.ps1`.
