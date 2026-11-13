**Install:** download `MXCtl-*.dmg`, open it and drag MXCtl to Applications. MXCtl is not
notarized (no Apple Developer account), so macOS blocks the first launch: open it once, then
System Settings → Privacy & Security → "Open Anyway". Or in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/MXCtl.app
```

macOS 15+, Apple Silicon and Intel. MXCtl needs Input Monitoring and Accessibility (it asks on
first launch). Updates are signed with the same certificate, so these permissions are kept. Once
installed, MXCtl offers newer versions itself ("Update available" in the panel: Update, Later or
Skip; Settings → General → Updates turns the checks or automatic installs on and off).

**Установка:** скачайте `MXCtl-*.dmg`, откройте и перетащите MXCtl в «Программы». Приложение не
нотаризовано, поэтому при первом запуске macOS его заблокирует: откройте его один раз, затем
«Системные настройки → Конфиденциальность и безопасность → Всё равно открыть» (или команда выше).
Дальше MXCtl сам предлагает новые версии: «Обновить», «Позже» или «Пропустить»; в «Общие →
Обновления» можно выключить проверку или включить автоматическую установку.
