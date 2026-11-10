# Encatch Flutter SDK: end-to-end test app

A small app that drives the SDK for the end-to-end flows. It is not published and not an example for customers; see `example/` for that.

- **App id:** `com.encatch.fluttere2e`.
- **Environments,** chosen on the first screen:
  - **Mock:** this repo's mock API on port 8797 (`http://10.0.2.2:8797` from the Android emulator, `http://localhost:8797` from the iOS simulator). The Burst tab only works here.
  - **DEV:** `https://api.dev.encatch.com`, with a key from the test project.
- **Plain HTTP** is allowed for the local mock only (`network_security_config.xml` on Android, local networking on iOS).
- **Reporting:** the app posts what the SDK did (events from `Encatch.on`, the form id from `onBeforeShowForm`) to the local mock's `/__mock/hooks`, which only collects them. The runner reads them back.

Defaults can be set at build time, so a flow doesn't have to type them:

```bash
flutter build apk --release \
  --dart-define=E2E_ENV=dev \
  --dart-define=E2E_API_KEY=<key> \
  --dart-define=E2E_FORM_ID=<form id>
```

Never commit a key. Keys live in `e2e/.results/dev-project.json`, which git ignores.
