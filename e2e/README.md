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
| M5 | Mock | A visitor's survey sends no survey events and no dismissal |
| M6 | Mock | A stopped session stays stopped after the app is reopened |
| M7 | Mock | The debug hooks match what the mock received |
| D1–D5 | DEV | Manual, page-visit, tracked-event, immediate and delayed triggers: the right form shows, events carry its id, the X is a dismissal |
| D6–D7 | DEV | The same for a visitor (manual, page visit): no dismissal |
| D8–D11 | DEV | Secure identify: valid and wrong signature, with and without a session time |

## Rules

- **Bursts and forced failures run against the mock only.** The app's Burst tab is disabled outside the Mock environment.
- **Always pass `--device`.** Other Maestro runs may be using other devices on the same machine.
- **Port 8797 only.** Port 8787 belongs to the React Native SDK's mock.
- **DEV project 1781 is shared** with the React Native tests. Don't change their forms or key; name anything new with an `FL` prefix.
- Keys and secrets live in `.results/dev-project.json` and are never printed or committed.
