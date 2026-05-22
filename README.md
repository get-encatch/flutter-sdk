# encatch_flutter

Official Flutter SDK for [Encatch](https://encatch.com) — in-app feedback.

## Features

- Initialize the SDK with your API key
- Identify users with traits and secure HMAC verification
- Track custom events and screens
- Display feedback forms in a native WebView overlay with animations
- Offline-resilient retry queue with exponential backoff
- 30-second session ping to maintain engagement sessions
- Pre-fill form responses programmatically
- AI-powered text refinement for long-text questions
- Listen to form lifecycle events
- Full feature parity with the Encatch React Native SDK

## Installation

Install `encatch_flutter`:

```bash
flutter pub add encatch_flutter
```

### Android Setup

Add internet permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

### iOS Setup

No additional setup required. The SDK uses `flutter_inappwebview` which works out of the box.

## Usage

For detailed usage, see the [Flutter SDK reference](https://encatch.com/docs/sdk-reference/mobile-sdk/flutter).

### 1. Wrap your app with `EncatchProvider`

```dart
import 'package:encatch_flutter/encatch_flutter.dart';

void main() {
  runApp(
    EncatchProvider(
      apiKey: 'your-api-key',
      child: MyApp(),
    ),
  );
}
```

### 2. Identify users

```dart
await Encatch.identifyUser(
  'user@example.com',
  traits: UserTraits(
    set: {'name': 'Jane Doe', 'plan': 'pro'},
  ),
);
```

### 3. Track events

```dart
await Encatch.trackEvent('button_clicked');
```

### 4. Track screens

```dart
await Encatch.trackScreen('HomeScreen');
```

Add `EncatchNavigatorObserver` for automatic tracking:

```dart
MaterialApp(
  navigatorObservers: [EncatchNavigatorObserver()],
  // ...
)
```

### 5. Show a form manually

```dart
await Encatch.showForm('your-form-slug');
```

### 6. Listen to form events

```dart
final unsubscribe = Encatch.on((eventType, payload) {
  print('Event: $eventType, payload: ${payload.data}');
});

// Later, to stop listening:
unsubscribe();
```

### 7. Pre-fill responses

```dart
Encatch.addToResponse('question_id', 'pre-filled value');
await Encatch.showForm('your-form-slug');
```

## Configuration

```dart
EncatchProvider(
  apiKey: 'your-api-key',
  config: EncatchConfig(
    theme: EncatchTheme.system,
    debugMode: true,
    isFullScreen: false,
    apiBaseUrl: 'https://app.encatch.com', // override for self-hosted
  ),
  child: MyApp(),
)
```

## Custom Native Forms

Use `buildSubmitRequest` to submit responses from your own native UI:

```dart
final request = buildSubmitRequest(
  options: BuildSubmitRequestOptions(
    formConfigurationId: 'config-id',
    triggerType: TriggerType.manual,
  ),
  responses: [
    NativeFormResponse(questionId: 'q1', type: 'rating', value: '5'),
    NativeFormResponse(questionId: 'q2', type: 'short_answer', value: 'Great!'),
  ],
);
await Encatch.submitForm(request);
```

## License

MIT License. See [LICENSE](LICENSE) for details.
