# Contributing

Small, focused pull requests are welcome. Explain the user-visible change and how you verified it. Run `./scripts/check.sh` on macOS before submitting. For UI changes, inspect both English and Simplified Chinese at the minimum window size.

Keep screenshots and OCR local. Never add real captures, signing identities, credentials or personal paths to fixtures or documentation. Use the generated demo image for examples. Keep the existing bundle identifier and signing approach stable so local permission grants survive updates.

New user-facing strings must use `L(...)` and appear in both localization tables. See `docs/LOCALIZATION.md`.

The repository is MIT-licensed; contributions are provided under the same license.
