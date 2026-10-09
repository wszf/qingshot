# Localization

The UI ships in English (`en`) and Simplified Chinese (`zh-Hans`). `LanguageStore` stores the user's choice; system mode selects Chinese for a Chinese preferred language and English otherwise. App-owned menus, alerts, editor controls and settings use `L(key, arguments...)`. Native system dialogs continue to use the macOS language.

String tables are in `Sources/QingShot/Resources/<language>.lproj/Localizable.strings`. The current source keys are Chinese phrases. Keep keys identical across languages and preserve numbered placeholders such as `{0}`. The formatter substitutes once, so braces in user filenames are not interpreted again. Translate full phrases rather than reordering fragments when adding new messages.

To add a language:

1. Add an `.lproj` resource table with every existing key.
2. Extend `AppLanguage`, `Localization.languageCode` and the language list used by `Localization.tables`.
3. Add localized `assets/<language>.lproj/InfoPlist.strings` and include the language in the packaging script.
4. Update the language-table tests, then run `./scripts/check.sh` and inspect window layout and accessibility labels.

`LocalizationTests` checks key parity, placeholder parity, fallback behavior and filename interpolation. Resource bundles are copied into the app's `Contents/Resources`, and the lookup explicitly prefers packaged resources over SwiftPM's development path. Runtime language changes update app-owned UI; existing images and user content stay intact.
