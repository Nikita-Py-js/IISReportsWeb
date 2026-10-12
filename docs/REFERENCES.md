# Технические основания

[← README](../README.md)

Официальная документация Microsoft:

- [Динамическая компиляция ASP.NET, App_Code и ashx](https://learn.microsoft.com/en-us/previous-versions/aspnet/ms366723(v=vs.100)) — предварительная сборка отдельного EXE для Web Site не нужна.
- [Модель процесса пула IIS](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/applicationpools/add/processmodel) — жизненный цикл рабочего процесса не гарантирует непрерывный таймер приложения.
- [sp_getapplock](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-getapplock-transact-sql) — сериализация импортёров одной базы; блокировка освобождается при завершении SQL-сессии.

Конкретное поведение Simple описано в исходниках, а не подразумевается общими возможностями IIS.

- [CORS и нестандартные заголовки](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS) — зачем сохраняется минимальный обязательный заголовок POST без токенов и PublicOrigin.
