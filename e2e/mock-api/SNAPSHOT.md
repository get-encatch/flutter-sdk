# Snapshot

This folder is a copy of `examples/mock-api` from the React Native SDK repository, taken on 10 November 2026 from the uncommitted work on its `hotfix/1.4-request-storms` branch.

- **Why a copy:** the Flutter tests run their own mock on port **8797**, so they never touch the React Native mock on port 8787.
- **Unchanged from the source:** everything in `src/`, `test/` and `CONTRACT.md`. SHA-256 over those files, in sorted order: `3e6955f0f3e67d0e77b528a6d8cae8803118f7257982865c0b13335bbbbdfa76`.
- **Changed here:** `package.json` only. It adds a `test` script and the test dependencies (`vitest`, `@encatch/schema`, `zod`), which the React Native repo provides from its workspace root.
- **Re-syncing:** when the React Native mock changes, copy `src/`, `test/` and `CONTRACT.md` again and update the date and hash above. `test/fake_api_contract_test.dart` and `test/helpers/fake_api.dart` in this repo port the same rules to Dart and need the same update.

Run it:

```bash
pnpm install --ignore-workspace
pnpm test
pnpm dev -- --port 8797
```
