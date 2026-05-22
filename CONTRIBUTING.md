# Contributing

Thank you for your interest in improving the Encatch Flutter SDK.

This repository is maintained by the Encatch team. We do not accept direct public code contributions, unsolicited pull requests, or third-party changes to the SDK source at this time.

## Reporting Issues

If you find a bug or have a feature request, please open a GitHub issue with:

- The SDK version you are using
- Your Flutter and Dart versions
- The target platform, such as Android, iOS, macOS, or Windows
- A minimal reproduction or clear steps to reproduce the issue
- Relevant logs, screenshots, or error messages

Please do not include API keys, secrets, user data, or other sensitive information in public issues.

## Feature Requests

Feature requests are welcome through GitHub issues. The Encatch team reviews requests and prioritizes them based on product direction, customer impact, and SDK compatibility.

## Pull Requests

Public pull requests may be closed without review because SDK changes are handled internally by the Encatch team. If an issue requires a code change, we will track and release the fix through our normal release process.

## Development Standards

Changes made by the Encatch team are expected to pass:

- `dart format --set-exit-if-changed .`
- `flutter analyze`
- `flutter test`
- `dart pub publish --dry-run`

Public releases are documented in `CHANGELOG.md`.
