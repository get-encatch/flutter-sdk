## 1.0.0-beta.2

- Add native form answer support for newer field types, including rating matrix, CSAT, opinion scale, ranking, picture choice, signature, file upload, phone number, address, video/audio, scheduler, Q&A with AI, and UPI payments
- Bug fixes

## 1.0.0-beta.1

- **Beta release** — First public beta of the Encatch Flutter SDK
- Full feature parity with the Encatch React Native SDK v2.0.0
- `EncatchProvider` widget for app-level initialization
- `EncatchWebView` overlay widget using `flutter_inappwebview`
- Static `Encatch` singleton with all public methods
- Offline-resilient retry queue with exponential backoff
- `EncatchNavigatorObserver` for optional automatic screen tracking
- Form display with entrance/exit animations (fade, scale, slide)
- Full postMessage bridge via `flutter_inappwebview` JS handlers
- `buildSubmitRequest` helper for custom native forms
