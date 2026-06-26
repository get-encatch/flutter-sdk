# encatch_flutter

Official Flutter SDK for [Encatch](https://encatch.com) — in-app feedback.

## Features

- Initialize the SDK with your API key
- Identify users with traits and secure HMAC verification
- Track custom events and screens
- Display feedback forms as a native WebView modal overlay with animations
- Render forms **inline** in your layout with `EncatchInlineForm`
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
    apiBaseUrl: 'https://api.encatch.com',
    webHost: 'https://form.encatch.com',
  ),
  child: MyApp(),
)
```

## Inline forms

`EncatchInlineForm` renders a form directly inside your widget tree instead of as a full-screen modal overlay. Place it anywhere — in a `Column`, `SingleChildScrollView`, `Card`, etc.

### Quick start

```dart
// In your screen's widget tree:
SingleChildScrollView(
  child: Column(
    children: [
      // ... content above ...
      EncatchInlineForm(
        formId: 'your-form-slug', // exact match; omit for wildcard
        enabled: ModalRoute.of(context)?.isCurrent ?? true,
      ),
      // ... content below ...
    ],
  ),
)
```

Then trigger the form from anywhere:

```dart
await Encatch.showForm('your-form-slug');
```

### Routing rules

When `showForm` is called, the SDK resolves the presenter in this order:

1. **Exact match** — first registered `EncatchInlineForm` whose `formId` matches the payload wins.
2. **Wildcard** — first registered `EncatchInlineForm` with no `formId` catches anything not exact-matched.
3. **Modal fallback** — `EncatchWebView` shows the form as the default overlay when no inline slot is registered or none match.

### Tab / navigation focus

A background tab with `EncatchInlineForm` mounted will intercept `showForm` calls even when it is not visible. To prevent this:

**Option A — pass `enabled` from `ModalRoute`:**

```dart
EncatchInlineForm(
  formId: 'your-form-slug',
  enabled: ModalRoute.of(context)?.isCurrent ?? true,
)
```

**Option B — only mount `EncatchInlineForm` on the active route** (e.g. using `IndexedStack` with conditional rendering).

When `enabled: false` the slot is unregistered, so `showForm` falls through to the modal or another active slot.

### ScrollView embedding

The WebView's internal scroll is disabled. The host `SingleChildScrollView` (or `CustomScrollView`) provides scrolling. The widget height grows automatically via `form:resize` messages from the web form.

```dart
SingleChildScrollView(
  child: Column(
    children: [
      EncatchInlineForm(formId: 'my-form'),
    ],
  ),
)
```

### Keyboard handling

The host app controls keyboard avoidance. Wrap the scroll view in `MediaQuery` inset handling or use `Scaffold`'s `resizeToAvoidBottomInset` to slide content above the keyboard.

### Props

| Prop | Type | Default | Description |
|---|---|---|---|
| `formId` | `String?` | `null` | Exact form slug/id to match. `null` = wildcard. |
| `enabled` | `bool` | `true` | When `false`, unregisters the slot — use for tab/route focus. |
| `minHeight` | `double` | `0` | Minimum height floor applied after form:resize. |
| `decoration` | `BoxDecoration?` | `null` | Outer container decoration. |
| `onOverlayOpenChange` | `ValueChanged<bool>?` | `null` | Called when a QnA/Scheduler overlay opens or closes. |

---

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
