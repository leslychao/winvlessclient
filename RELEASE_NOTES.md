# Release notes

## 1.1.0 - 2026-05-14

Релиз подготавливает клиент к полноценному VPN-режиму и делает запуск более предсказуемым.

### Добавлено

- Полный VPN-режим `Route all traffic through VPN`: весь публичный интернет-трафик идет через VLESS, а private/LAN-адреса остаются direct.
- Переключение режима маршрутизации в UI с сохранением выбора в runtime-настройках и автоматическим reconnect при активном соединении.
- Поддержка VLESS transport: `tcp`, `ws`, `grpc`, `http`, `httpupgrade`, `quic`.
- Проверка сгенерированного `sing-box` config через `sing-box check` перед стартом соединения.
- Single-instance guard для предотвращения нескольких одновременно запущенных экземпляров клиента.
- Ротация клиентского и `sing-box` логов.
- Набор regression tests для нормализации доменов, генерации config, routing modes, runtime settings и миграции legacy profile.

### Изменено

- `settings.json` в корне теперь является tracked seed/default domain list, а пользовательские настройки сохраняются в `runtime/settings.json`.
- Секретный VLESS URL хранится отдельно в `runtime/connection.private.json`.
- Доменный список нормализуется перед маршрутизацией: URL, wildcard `*.` и дубликаты приводятся к одному canonical domain.
- `start.cmd` использует pinned `sing-box` 1.13.6 и заменяет runtime binary, если версия не совпадает.
- Runtime config, profile/settings ownership и маршрутизация сведены к одному authoritative workflow в `lib/core.ps1`.

### Удалено

- Старый runtime profile path `runtime/profile.json` больше не остается активным: данные мигрируются в новые runtime-файлы, legacy file удаляется.
- Убрано изменение tracked root `settings.json` из пользовательского workflow.
