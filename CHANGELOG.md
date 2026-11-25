## 1.2.0

This release changes how much the SDK sends, how it identifies users and when it shows surveys. No existing method, parameter or type has changed; everything new is optional.

**New, all optional**
- `EncatchConfig.onRequest` and `onResponse`: debug hooks that report each request, and each call the SDK decides not to send, with the reason. They never carry the API key, headers, the secure signature or bodies.
- `EncatchNavigatorObserver(trackRootRoute: true)`: track the `/` route. Off by default; planned to become the default in a later minor release.
- `EncatchProvider(autoStartVisitorSession: false)`: visitors get no background ping and no automatic screen tracking. The session starts when `identifyUser` succeeds (the current screen is then sent once) or when the app calls `startSession()`, and stops again on `resetUser()`. A user restored at launch starts as usual, and calls the app makes itself are always sent. On by default, as before. With it off, surveys set to show immediately, after a delay or on a page visit cannot reach visitors.
- `Encatch.isIdentified`: true when the SDK has a confirmed identity, which means the user was restored at launch or their `identifyUser` succeeded. During a switch to another user it stays true until the new user's identify succeeds.
- `EncatchConfig.persistUserAcrossRestarts`: set it to false to keep the user in memory for the current app run only. Nothing about the user is saved on the device, user data an earlier version saved is deleted at init, and the app identifies on every launch. On by default, as before.

**Behaviour changes to be aware of**
- Closing a survey with its X before the final submit is now a dismissal, for identified users and visitors alike. The SDK records it and `Encatch.on` listeners receive `EventType.formDismissed`.
- Survey events reach `Encatch.on` with the form's id. They used to carry an empty id.
- `resetUser()` no longer stops the background ping. The session carries on as a visitor, ping and automatic screen tracking alike, with no extra ping at the reset. Logged-out visitors can therefore get surveys set to show immediately or after a delay. Set `autoStartVisitorSession` to false for the opposite: no visitor traffic after a sign-out.
- `stopSession()` now survives an app restart, as documented. An app that relied on the next launch resuming by itself must call `startSession()` or identify a user.
- Identical calls are sent once: an `identifyUser` identical to the last one, and the same event or screen tracked again within one second.
- `EncatchNavigatorObserver` tracks a route only when its name changes, so closing a dialog no longer tracks the screen underneath again. Going back to the first screen (`/`) counts as a change even though `/` is not tracked, so going home, to A, home and to A again tracks A twice.
- Visitors no longer send survey events (the server rejected them).
- The SDK no longer prints to the console. Its messages go through its logger and appear only with `debugMode: true`.

**Fixes: request load**
- A call made while another was in flight stayed in the queue until the next SDK call or app resume. It is now sent straight away.
- A request that never answered blocked the queue for the life of the app. Requests now time out after 30 seconds.
- After a 429 the SDK pauses for the time in `Retry-After` instead of sending more. A survey submit is never dropped for a 429: it waits and is retried.
- A screen that carried a survey, tracked many times, sent a show-form request each time. One survey is shown at a time, and a repeated `showForm` for the open survey no longer discards the answers in progress.

**Fixes: surveys**
- Surveys with immediate, delayed and tracked-event triggers were never shown. They are now.
- A survey's own "remind me later" is sent for identified users only.
- Q&A with AI answers now arrive piece by piece instead of all at once.

**Fixes: identity**
- A new user whose first identify failed sent a user name without an id and got 401 on every request. Requests now carry both identity headers or neither.
- Switching users no longer sends the new name with the previous user's id.
- `resetUser()` followed straight away by `identifyUser()`, neither awaited, now ends as that user.
- An event or screen tracked right after `identifyUser()`, not awaited, is sent after it as that user.
- The server's "user could not be created" reply now resets the user, as intended.

**Fixes: secure mode**
- Identify sends the signature in the headers the gateway reads, including the session time. Keys with a session time rejected every signed identify before.
- After a successful secure identify the signature is sent with every request for that user and kept across restarts.
- When a signature expires the SDK stops tracking until the app identifies again, instead of sending requests that all fail.
- The debug log masks the signature.

**Fixes: session**
- A reply from the server no longer restarts the ping after `stopSession()` or `pauseSession()`.
- The first screen, tracked before `init` finished, is no longer lost.

**Maintenance**
- The SDK no longer imports Flutter's Material library, which Flutter 3.50 deprecated. It uses the widgets library only, so it works the same in apps that still use `package:flutter/material.dart` and in apps that have moved to `material_ui`. The minimum Flutter version is unchanged, and surveys look the same.

## 1.1.2
- Align submit-contract types with `@encatch/schema` 1.5.2: add `QuestionResponse.error`, `timeSpentMs`, `isPathTraversed`, explicit null answers, and `FormDetailsResponse`.
- Change `PaymentsUpiAnswer.amount` to a decimal string (schema wire format) with `PaymentsUpiAnswer.fromNumericAmount` helper.
- Add `QuestionAnswer.others` legacy field, completion CTA types, logic jump rule, and form configuration response types.
- Mark deprecated `annotation` and `payments_upi` question types in public API docs.

## 1.1.1
- Add `projectI18nFileUrl` to `ShowFormResponse` for multi-language form i18n packs.

## 1.1.0
- Align in-app modal appearance and animations with React Native parity.
- Apply form corner presets, in-app size/position layout, dark overlay, frosted backdrop, and drop shadow styling.
- Start modal entrance and backdrop fade on showForm for smoother loading UX.

## 1.0.1
- Update default API host to `https://api.encatch.com`.
- Update default form WebView host to `https://form.encatch.com`.

## 1.0.0
- Stable release of the Encatch Flutter SDK.
- Includes all features and fixes from the beta releases.
- Ready for production use.

## 1.0.0-beta.3

- **New:** Call to Action for thank you and exit screens now take you to in app browser / external browsers / in app navigation
- **New:** Inline forms in addition to modal based forms
- **Fix:** Bug fixes

## 1.0.0-beta.2

- Add native form answer support for newer field types, including rating matrix, CSAT, opinion scale, ranking, picture choice, signature, file upload, phone number, address, video/audio, scheduler, Q&A with AI, and UPI payments
- Bug fixes

## 1.0.0-beta.1

- **Beta release** — First public beta of the Encatch Flutter SDK
- Full feature parity 
- `EncatchProvider` widget for app-level initialization
- `EncatchWebView` overlay widget using `flutter_inappwebview`
- Static `Encatch` singleton with all public methods
- Offline-resilient retry queue with exponential backoff
- `EncatchNavigatorObserver` for optional automatic screen tracking
- Form display with entrance/exit animations (fade, scale, slide)
- Full postMessage bridge via `flutter_inappwebview` JS handlers
- `buildSubmitRequest` helper for custom native forms
