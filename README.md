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

### Camera and microphone

The SDK never asks for camera or microphone access by itself. The prompt appears only when a form question needs it, such as a video or audio answer.

Declare the permissions only if your forms use those question types:

- **Android:** `CAMERA` and `RECORD_AUDIO` in `AndroidManifest.xml`.
- **iOS:** `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` in `Info.plist`.

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

Call `identifyUser` once, after sign-in. Calling it again with the same user, traits, locale, country and signature sends nothing.

Tracking calls made straight after `identifyUser`, without awaiting it, are queued behind it and sent as that user. For a user the device hasn't seen before, anything else sent before the identify reply arrives (a ping, say) goes out as a visitor.

#### Secure mode

For an API key that has a secret, your backend signs the user name and the app passes the signature along:

```dart
await Encatch.identifyUser(
  'user@example.com',
  options: IdentifyOptions(
    secure: SecureOptions(
      signature: signatureFromYourBackend,
      // Only for keys with a session time:
      generatedDateTimeinUTC: timeFromYourBackend,
    ),
  ),
);
```

- **Signature:** hex HMAC-SHA256, computed with the key's secret, of the user name. For a key with a session time, of the user name followed by the time.
- **Time:** epoch milliseconds, as a string. Pass exactly the value your backend signed.
- **Never put the secret in the app.** Sign on your server.
- After a successful identify the SDK sends the signature with every request for that user, and keeps it across app restarts.
- **Keys with a session time:** identify with a fresh signature on every app launch. When a signature expires the SDK logs one warning and stops tracking until the app identifies again; a survey being submitted at that moment is sent after that identify.

### 3. Track events

```dart
await Encatch.trackEvent('button_clicked');
```

Call `trackEvent` from handlers, not from `build`. As a safety net, the same event name tracked again within one second is sent once.

If the server answers 429 (rate limited), the SDK pauses tracking for the time the server asks, and skips tracking calls made during the pause. A survey submit is never dropped: it waits and is retried.

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

The observer tracks named routes, and only when the route name changes, so closing a dialog doesn't track the screen underneath again.

The root route, `/`, is not tracked by default. To track it, for example to show a survey on your home screen:

```dart
navigatorObservers: [EncatchNavigatorObserver(trackRootRoute: true)],
```

The default is planned to change to `true` in a later minor release.

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

When a user closes a survey with its X before the final submit, the SDK records a dismissal and your listener receives `EventType.formDismissed`. This applies to identified users and visitors alike. Closing on the thank-you screen, "remind me later" and call-to-action buttons are not dismissals.

### 7. Pre-fill responses

```dart
Encatch.addToResponse('question_id', 'pre-filled value');
await Encatch.showForm('your-form-slug');
```

### 8. Stop and start the session

```dart
await Encatch.stopSession();   // for example, when the user opts out
await Encatch.startSession();  // turn it back on
```

`stopSession()`:

- stops the background ping and `EncatchNavigatorObserver`'s automatic screen tracking
- closes the open survey and cancels one that is waiting to show
- is saved, so it survives app restarts

While stopped, calls your app makes itself still go out (`trackScreen`, `trackEvent`, `identifyUser`, `showForm` and submits), and a survey the server chooses in their replies is still shown.

`startSession()` or a successful `identifyUser()` turns it back on. `resetUser()` clears a saved stop.

`pauseSession()` and `resumeSession()` stop and restart the ping only, and are not saved.

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

### Debug hooks

Two optional hooks let you see what the SDK sends, for diagnostics:

```dart
EncatchConfig(
  onRequest: (info) => debugPrint('-> ${info.endpoint} #${info.attempt}'),
  onResponse: (info) => debugPrint(
    '<- ${info.endpoint} ${info.outcome} ${info.status ?? info.reason}',
  ),
)
```

- `outcome` is `ok`, `error`, `network-error` or `skipped`.
- For a `skipped` call, `reason` says why the SDK didn't send it: `rate-limited`, `collapsed`, `duplicate`, `signature-expired`, `visitor` or `survey-open`.
- The hooks never receive your API key, headers, the secure signature or request and response bodies.
- An error thrown inside a hook is ignored.
- File uploads and the Q&A stream are not reported.

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
