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

The provider starts a session at every launch, for visitors too: a background ping, and automatic screen tracking if you use `EncatchNavigatorObserver`. To keep visitors quiet until they sign in, turn that off:

```dart
EncatchProvider(
  apiKey: 'your-api-key',
  autoStartVisitorSession: false,
  child: MyApp(),
)
```

With `autoStartVisitorSession: false`:

- A visitor gets no ping and no automatic screen tracking.
- The session starts when `identifyUser` succeeds, and the current screen is then sent once. It also starts when your app calls `Encatch.startSession()`.
- `resetUser()` (sign-out) stops it again.
- A user restored from the device at launch starts as usual.
- Calls your app makes itself are always sent: `trackScreen`, `trackEvent`, `showForm` and submits.
- Surveys set to show immediately, after a delay or on a page visit cannot reach visitors, because they arrive in ping and screen replies. A manual `showForm` and surveys triggered by `trackEvent` still work.

### 2. Identify users

```dart
await Encatch.identifyUser(
  'user@example.com',
  traits: UserTraits(
    set: {'name': 'Jane Doe', 'plan': 'pro'},
  ),
);
```

Call `identifyUser` after sign-in. After the first identify of each app run, a repeat for the same user with the same traits, or none, sends nothing, so calling it on every launch or screen is safe. It is sent again when the signature changes, or when you pass a locale or country that differs from what the last identify carried.

#### Update user properties

To update the signed-in user's properties, for example a counter, use `setUserProperties`. Unlike `identifyUser`, every call is sent:

```dart
await Encatch.setUserProperties(
  'user@example.com',
  const UserTraits(set: {'plan': 'team'}, increment: {'reports_created': 1}),
);
```

- The user name must be the current user's, and their identify must have succeeded (or they were restored at launch). Otherwise the call is ignored, so it can never update the wrong person.
- It waits for that user's identify if it is still in flight, and for an open survey to close. Updates are sent one at a time, in the order you call it.
- It uses the identify-user endpoint, so it counts against the same rate limit (about 5 per minute per user). A 429 there pauses all tracking for a while.
- An update with `increment` or `decrement` is not retried after a network or server error, so it can't be applied twice.
- Don't `await` it inside `onBeforeShowForm`: the survey being shown counts as open, so the update would wait for it while the survey waits for your callback. Call it without `await` there.

Tracking calls made straight after `identifyUser`, without awaiting it, are queued behind it and sent as that user. For a user the device hasn't seen before, anything else sent before the identify reply arrives (a ping, say) goes out as a visitor.

`Encatch.isIdentified` tells you whether the SDK has a confirmed identity:

- **true:** the user was restored from the device at launch, or their `identifyUser` succeeded.
- **false:** before init has finished, for a visitor, while a new user's first identify is pending or after it failed, and after `resetUser()` or `clearAll()`.
- **During a switch to another user:** it stays true, for the previous user, until the new user's identify succeeds.

By default the user is saved on the device and restored at the next launch. To keep the user in memory only, see `persistUserAcrossRestarts` under [Configuration](#configuration).

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
- After a successful identify the SDK sends the signature with every request for that user, and keeps it across app restarts (unless `persistUserAcrossRestarts` is false).
- **Keys with a session time:** a signature is valid for the key's session time. Sign the time on your server as epoch milliseconds (13 digits), with a clock within 5 minutes of real time.
- **When the signature expires**, the SDK calls `onSignatureExpired`. Get a fresh signature and identify again:

```dart
EncatchConfig(
  onSignatureExpired: (info) async {
    final secure = await myBackend.encatchSignature(info.userName);
    // Signed out or switched user meanwhile.
    if (currentUser?.id != info.userName) return;
    await Encatch.identifyUser(
      info.userName,
      options: IdentifyOptions(secure: secure),
    );
  },
)
```

  - It is called once per user until an identify for them succeeds, so a signature that keeps being rejected does not loop. It is not called for visitors, and errors in it are ignored.
  - The SDK learns of the expiry only when the server checks the signature, today on `identifyUser` and `setUserProperties`. It can't warn at launch; to stay ahead, refresh the signature at launch.
  - If the saved signature expired, the SDK logs one warning and skips events, screens, the ping and automatic surveys until the app identifies again. Survey submits made meanwhile are held in memory (up to 10) and sent after that identify; `resetUser()`, `clearAll()` or identifying another user drop them and end that state.
  - If the signature you just passed to `identifyUser` has already expired, that identify fails like any rejected identify. The saved signature, if any, and tracking are kept.

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

`resetUser()` (sign-out) does not stop the session. It carries on as a visitor under a new session id: the ping keeps its regular interval and automatic screen tracking continues. With `autoStartVisitorSession: false` the SDK goes quiet instead, until the next sign-in.

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
    persistUserAcrossRestarts: true,
    onSignatureExpired: (info) { /* see Secure mode */ },
  ),
  child: MyApp(),
)
```

`persistUserAcrossRestarts` (default `true`) decides whether the identified user is kept across app restarts:

| | `true` (default) | `false` |
|---|---|---|
| User name, user id, secure signature | Saved on the device, restored at launch | Kept in memory for this app run only |
| At the next launch | Restored as that user | A visitor until the app identifies |
| `Encatch.isIdentified` at launch | `true` | `false` until an identify succeeds |
| Call `identifyUser` on every launch | Not needed | Needed |

With `false`, user data an earlier version of your app saved is deleted at init. The device id, a saved `stopSession()` and the locale and country preferences are saved either way.

Together with `autoStartVisitorSession: false`, nothing is sent at launch until the app identifies the user.

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
- For a `skipped` call, `reason` says why the SDK didn't send it: `rate-limited`, `collapsed`, `duplicate`, `signature-expired`, `visitor`, `survey-open`, `not-identified` or `wrong-user`.
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
