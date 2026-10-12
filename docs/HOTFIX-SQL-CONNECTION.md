# История исправления строки SQL-подключения

[← README](../README.md) · [Чистая установка](INSTALL.md) · [Устранение ошибок](TROUBLESHOOTING.md)

> Это историческое описание исправления. В версии 3.1.1 оно уже включено. Не накладывайте старые ZIP-патчи поверх этого выпуска.

В PowerShell SqlConnectionStringBuilder заполняется через канонические ключи: Data Source, Initial Catalog, Integrated Security, User ID и Password. Проверка Test-SqlConnectionBuilder.ps1 не подключается к SQL; Test-SqlConnection.ps1 выполняет настоящее подключение и запрос чтения.

Data Source — имя SQL-экземпляра, не URL IIS. После изменения файла .psd1 следующий запуск установщика заново прочитает значение. SQL TLS и HTTPS сайта — разные настройки.

Для установки используйте единый `Install.ps1` и файл `.psd1`, а не команды из предыдущих сообщений. Для работающего сайта используйте [UPGRADING.md](UPGRADING.md). Проверка на целевом Windows/IIS/SQL обязательна; статический анализ не заменяет выполнение.
