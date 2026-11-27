# End-to-end tests

Everything here is for testing the SDK on real devices. None of it is published with the package.

| Folder | What it is |
|---|---|
| `app/` | The test app (`com.encatch.fluttere2e`): set-up, login, tabs for events, bursts and an inline form |
| `mock-api/` | A local copy of the mock API, run on port **8797** (see its `SNAPSHOT.md`) |
| `flows/` | Maestro flows, the same files for Android and iOS |
| `run.mjs` | The runner: drives the flows and checks what the SDK did |
| `tools/` | Python scripts that drive the Android app over `adb`, for when Maestro can't be used |
| `.results/` | Local only, git-ignored: the DEV keys and form ids |

## Run

```bash
cd e2e/mock-api && pnpm install --ignore-workspace && pnpm dev -- --port 8797
```

```bash
node e2e/run.mjs --platform android --device emulator-5580
```

```bash
node e2e/run.mjs --platform ios --device <simulator udid> --only M1,D1
```

Build and install the app first (`flutter build apk --release` in `e2e/app`, or `flutter build ios --simulator --debug` for a simulator, which only supports debug builds).

## Flows

| # | Runs against | Checks |
|---|---|---|
| M1 | Mock | Login, then each burst button: one request per distinct call, no 401 |
| M2 | Mock | A survey screen tracked 18 times: one show-form, no 404; the X is a dismissal |
| M3 | Mock | A 429 pauses tracking; calls already queued go out once afterwards |
| M4 | Mock | `resetUser()` then `identifyUser()`, not awaited: one identify, no 401 |
| M5 | Mock | A visitor's survey sends no survey events; the X sends dismiss-form only |
| M6 | Mock | A stopped session stays stopped after the app is reopened |
| M7 | Mock | The debug hooks match what the mock received |
| M8 | Mock | The inline form shows in its slot; the X is a dismissal; it shows again |
| M9 | Mock | `trackRootRoute`: a route named `/` is tracked only when the option is on |
| M10 | Mock | Log out, then log in as another user: every later request carries the new user's name and id |
| M11 | Mock | `autoStartVisitorSession` off: no ping and no automatic screen as a visitor, before sign-in and after sign-out; the current screen is sent at sign-in |
| M12 | Mock | After a sign-out the session carries on as a visitor: the login screen is tracked and the ping comes on its interval, not at the sign-out |
| M13 | Mock | The app is closed and reopened: the identified user is restored (the default) |
| M14 | Mock | The same with `persistUserAcrossRestarts` off: a visitor again, nothing carries a user name or id |
| M15 | Mock | `identifyUser` repeats are not sent; `setUserProperties` always is, with the user's id; after a restart the first identify of the run is sent |
| D1–D5 | DEV | Manual, page-visit, tracked-event, immediate and delayed triggers: the right form shows, events carry its id, the X is a dismissal |
| D6–D7 | DEV | The same for a visitor (manual, page visit): the X sends dismiss-form and no survey event |
| D8–D11 | DEV | Secure identify: valid and wrong signature, with and without a session time |
| D12 | DEV | The form is submitted; the X on the thank-you screen is not a dismissal |
| D13 | DEV | Log out, then log in as another user: two different ids from the server, no failed request |
| D14 | DEV | "Remind me later": the app event and the survey event, not a dismissal |
| D15 | DEV | A real signature expiry on the session-time key. Slow (about 18 minutes): runs only with `--only D15` |
| D16 | DEV | Q&A with AI: the answer arrives in pieces, and the form submits |

## Rules

- **Bursts and forced failures run against the mock only.** The app's Burst tab is disabled outside the Mock environment.
- **Always pass `--device`.** Other Maestro runs may be using other devices on the same machine.
- **Port 8797 only.** Port 8787 belongs to the React Native SDK's mock.
- **DEV project 1781 is shared** with the React Native tests. Don't change their forms or key; name anything new with an `FL` prefix.
- **One run at a time per collector.** Every app reports to the collector on port 8797, so a second device used by hand while a suite runs gives false failures.
- **Automatic DEV forms use `fl_` names only** (the remind-me-later form is triggered by the event `fl_remind_event`), so no other run on the project can trigger them.
- Keys and secrets live in `.results/dev-project.json` and are never printed or committed.
