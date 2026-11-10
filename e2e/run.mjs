#!/usr/bin/env node
// End-to-end runner for the Encatch Flutter SDK.
//
//   node e2e/run.mjs --platform android --device emulator-5580
//   node e2e/run.mjs --platform ios --device <simulator udid> --only M1,D1
//
// It drives the e2e app with Maestro (the same flows on Android and iOS) and
// checks what the SDK did:
//   - M flows run against this repo's mock API on port 8797, where every
//     request can be read. Bursts and forced failures only ever run here.
//   - D flows run against the DEV API, project 1781. The server's request log
//     isn't visible there, so the app reports its own SDK events and debug
//     hooks to the local mock, which only collects them.
//
// Needs: the mock running (cd e2e/mock-api && pnpm dev -- --port 8797), the e2e
// app installed on the device, and for D flows e2e/.results/dev-project.json.
// Always pass --device: another Maestro run may be using a different device.
// Never point this at port 8787 (the React Native SDK's mock).

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const arg = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
};
const platform = arg('platform');
const device = arg('device');
const only = arg('only')?.split(',');
if (!['android', 'ios'].includes(platform) || !device) {
  console.error('usage: node e2e/run.mjs --platform android|ios --device <id> [--only M1,D2]');
  process.exit(2);
}

const MOCK = 'http://127.0.0.1:8797';
const devFile = join(here, '.results', 'dev-project.json');
const dev = existsSync(devFile) ? JSON.parse(readFileSync(devFile, 'utf8')) : null;
const MOCK_FORM = '0190f1d2-0000-7000-8000-00000000f001';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mock = async (path, method = 'GET', body) => {
  const res = await fetch(MOCK + path, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : method === 'POST' ? '{}' : undefined,
  });
  return res.json().catch(() => null);
};
const requests = async (endpoint) =>
  (await mock('/__mock/requests?limit=5000')).filter((r) => r.endpoint && (!endpoint || r.endpoint === endpoint));
const count = async (endpoint, status) =>
  (await requests(endpoint)).filter((r) => status == null || r.status === status).length;
const header = (r, name) => Object.entries(r.headers).find(([k]) => k.toLowerCase() === name)?.[1];
const reports = async () => await mock('/__mock/hooks');
const appEvents = async () =>
  (await reports()).filter((h) => h.kind === 'event').map((h) => ({ type: h.type, formId: h.formId }));
const shown = async () =>
  (await reports()).filter((h) => h.kind === 'beforeShowForm').map((h) => h.formId);
const hookCalls = async () => (await reports()).filter((h) => h.kind === 'hook');

/** Runs one Maestro flow on this run's device. Throws when it fails. */
function flow(name, env = {}) {
  const args = ['--device', device, 'test', join(here, 'flows', `${name}.yaml`)];
  for (const [k, v] of Object.entries(env)) args.push('-e', `${k}=${v}`);
  const res = spawnSync('maestro', args, {
    encoding: 'utf8',
    env: { ...process.env, MAESTRO_CLI_NO_ANALYTICS: '1' },
  });
  if (res.status !== 0) {
    const tail = (res.stdout + res.stderr).trim().split('\n').slice(-6).join('\n');
    // Keys and secrets are passed to flows; never print them.
    const shown = Object.fromEntries(
      Object.entries(env).map(([k, v]) => [k, ['API_KEY', 'SECRET'].includes(k) && v ? '***' : v]),
    );
    throw new Error(`flow ${name} ${JSON.stringify(shown)} failed:\n${tail}`);
  }
}
const tap = (id) => flow('tap', { ID: id });
const tapText = (text) => flow('tap-text', { TEXT: text });

class Checks {
  failures = [];
  eq(what, actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      this.failures.push(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
  }
  ok(what, condition, detail = '') {
    if (!condition) this.failures.push(`${what}${detail ? `: ${detail}` : ''}`);
  }
}

/** Every variable open.yaml reads; a flow file can't hold defaults (see there). */
const open = (env) =>
  flow('open', {
    ENV: 'mock',
    IDENTITY: 'login',
    API_KEY: '-',
    FORM_ID: '-',
    SECRET: '',
    SESSION: 'no',
    SIGNATURE: 'none',
    ...env,
  });
const openMock = (identity = 'login') => open({ ENV: 'mock', IDENTITY: identity });
const openDev = (identity, formId, extra = {}) =>
  open({ ENV: 'dev', IDENTITY: identity, API_KEY: dev.sdkKey, FORM_ID: formId, ...extra });

// ---------------------------------------------------------------------------
// Mock flows: bursts, rate limits and anything that must not reach DEV
// ---------------------------------------------------------------------------

const flows = {};

flows.M1 = {
  title: 'Login and bursts: one request per distinct call',
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openMock();
    await sleep(4000);
    c.eq('identify requests at login', await count('identify-user'), 1);
    c.eq('401s at login', await count(undefined, 401), 0);
    const later = (await requests()).filter((r) => r.endpoint !== 'identify-user');
    c.ok(
      'both identity headers, or neither, on every request',
      later.every((r) => !!header(r, 'x-user-name') === !!header(r, 'x-user-id')),
    );

    tap('tab-burst');
    for (const [button, endpoint, expected] of [
      ['burst-identify', 'identify-user', 0],
      ['burst-event-same', 'track-event', 1],
      ['burst-event-different', 'track-event', 20],
      ['burst-screen-same', 'track-screen', 1],
    ]) {
      await mock('/__mock/reset?keepScenario=1', 'POST');
      tap(button);
      await sleep(7000);
      c.eq(`${button}: ${endpoint} requests`, await count(endpoint), expected);
    }
    c.eq('401s during bursts', await count(undefined, 401), 0);
  },
};

flows.M2 = {
  title: 'Survey screen tracked 18 times, then closed with its X',
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openMock();
    await sleep(3000);
    await mock('/__mock/scenario', 'POST', { triggers: { screens: { '/checkout': { formId: MOCK_FORM } } } });
    tap('tab-burst');
    await mock('/__mock/reset?keepScenario=1', 'POST');
    tap('burst-survey-screen');
    tapText('Close');
    await sleep(4000);
    c.eq('track-screen requests', await count('track-screen'), 1);
    c.eq('show-form requests', await count('show-form'), 1);
    c.eq('show-form 404s', await count('show-form', 404), 0);
    const dismiss = await requests('dismiss-form');
    c.eq('dismiss-form requests', dismiss.length, 1);
    c.eq('dismiss-form status', dismiss[0]?.status, 200);
    c.eq('dismiss-form form id', dismiss[0]?.body?.formConfigurationId, MOCK_FORM);
    const surveyEvents = (await requests('track-event')).map((r) => r.body?.eventName);
    c.ok('form:dismissed sent once', surveyEvents.filter((e) => e === 'form:dismissed').length === 1, surveyEvents.join(','));
    const events = await appEvents();
    c.ok('the app got form:dismissed with the form id', events.some((e) => e.type === 'formDismissed' && e.formId === MOCK_FORM));
    c.ok('no app event has an empty form id', events.every((e) => e.formId), JSON.stringify(events));
  },
};

flows.M3 = {
  title: 'A 429 pauses tracking; queued calls go out once afterwards',
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openMock();
    await sleep(3000);
    tap('tab-burst');
    await mock('/__mock/reset?keepScenario=1', 'POST');
    await mock('/__mock/scenario', 'POST', {
      faults: [{ endpoint: 'track-event', count: 1, status: 429, retryAfterSeconds: 12 }],
    });
    tap('burst-event-different');
    await sleep(5000);
    c.eq('requests during the pause', await count('track-event'), 1);
    c.eq('the one request is the 429', await count('track-event', 429), 1);
    await sleep(14000);
    const all = await requests('track-event');
    c.eq('requests after the pause', all.length, 20);
    c.eq('429s in all', all.filter((r) => r.status === 429).length, 1);
    const names = all.map((r) => r.body?.eventName);
    c.eq('no event sent twice', new Set(names).size, names.length);
    c.eq('pings during the run that got 429', await count('ping', 429), 0);
  },
};

flows.M4 = {
  title: 'resetUser() then identifyUser(), not awaited',
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openMock();
    await sleep(3000);
    tap('tab-burst');
    await mock('/__mock/reset?keepScenario=1', 'POST');
    tap('burst-reset-identify');
    await sleep(5000);
    tap('tab-events');
    tap('track-custom-event');
    await sleep(4000);
    const identifies = await requests('identify-user');
    c.eq('identify requests', identifies.length, 1);
    c.ok('identify carries the user name', !!header(identifies[0] ?? { headers: {} }, 'x-user-name'));
    c.ok('identify carries no user id', !header(identifies[0] ?? { headers: {} }, 'x-user-id'));
    const event = (await requests('track-event')).at(-1);
    c.eq('the event after it', [event?.status, !!header(event, 'x-user-name'), !!header(event, 'x-user-id')], [200, true, true]);
    c.eq('401s', await count(undefined, 401), 0);
  },
};

flows.M5 = {
  title: 'Visitor: a survey shown and closed sends no survey events',
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openMock('visitor');
    await sleep(2000);
    tap('tab-events');
    await mock('/__mock/reset?keepScenario=1', 'POST');
    tap('show-form');
    tapText('Close');
    await sleep(4000);
    c.eq('show-form requests', await count('show-form'), 1);
    c.eq('track-event requests', await count('track-event'), 0);
    c.eq('dismiss-form requests', await count('dismiss-form'), 0);
    c.eq('403s', await count(undefined, 403), 0);
    const events = await appEvents();
    c.ok('the app got form:close', events.some((e) => e.type === 'formClose'));
    c.ok('the app got no form:dismissed', !events.some((e) => e.type === 'formDismissed'));
  },
};

flows.M6 = {
  title: 'A stopped session stays stopped after the app is reopened',
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openMock();
    await sleep(3000);
    tap('tab-events');
    tap('stop-session');
    await sleep(2000);
    flow('relaunch');
    await mock('/__mock/reset?keepScenario=1', 'POST');
    await sleep(40000); // longer than the 30 s ping interval
    c.eq('requests in 40 s after reopening', (await requests()).length, 0);
    tap('tab-events');
    tap('start-session');
    await sleep(5000);
    c.eq('pings after startSession()', await count('ping'), 1);
    c.eq('track-screen after startSession()', await count('track-screen'), 1);
  },
};

flows.M7 = {
  title: 'Debug hooks match what the mock received',
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openMock();
    await sleep(3000);
    tap('tab-burst');
    await mock('/__mock/reset?keepScenario=1', 'POST');
    tap('burst-event-same');
    await sleep(6000);
    const hooks = (await hookCalls()).filter((h) => h.endpoint === 'track-event');
    c.eq('sent, per the hooks', hooks.filter((h) => h.outcome === 'ok').length, await count('track-event'));
    c.eq('skipped as collapsed, per the hooks', hooks.filter((h) => h.reason === 'collapsed').length, 19);
    const text = JSON.stringify(await hookCalls());
    c.ok('no key in the hook data', !text.includes('mock-api-key'));
  },
};

// ---------------------------------------------------------------------------
// DEV flows: real triggers, real forms, real gateway. No bursts.
// ---------------------------------------------------------------------------

/** One trigger type: the right form shows once, and the X is a dismissal. */
function triggerFlow(title, form, action, waitMs, identity = 'login') {
  return {
    title,
    dev: true,
    async run(c) {
      await mock('/__mock/reset', 'POST');
      openDev(identity, dev.forms.manual.id);
      await sleep(3000);
      for (const id of action) tap(id);
      await sleep(waitMs);
      tapText('Close');
      await sleep(4000);
      c.eq('forms shown', await shown(), [dev.forms[form].id]);
      const events = await appEvents();
      c.ok('form:show with this form id', events.some((e) => e.type === 'formShow' && e.formId === dev.forms[form].id), JSON.stringify(events));
      c.ok('no app event has an empty form id', events.every((e) => e.formId));
      const dismissed = events.some((e) => e.type === 'formDismissed');
      if (identity === 'login') c.ok('the X is a dismissal', dismissed);
      else c.ok('a visitor closing is not a dismissal', !dismissed);
      const failed = (await hookCalls()).filter((h) => h.outcome === 'error' && !(h.endpoint === 'show-form' && h.status === 404));
      c.eq('failed requests, per the hooks', failed.map((h) => `${h.endpoint} ${h.status}`), []);
    },
  };
}

flows.D1 = triggerFlow('Manual showForm, identified', 'manual', ['tab-events', 'show-form'], 2000);
flows.D2 = triggerFlow('Page visit ("dev-page"), identified', 'pageVisit', ['open-dev-page'], 2000);
flows.D3 = triggerFlow('Tracked event (dev_event), identified', 'trackedEvent', ['tab-events', 'track-dev-event'], 2000);
flows.D4 = triggerFlow('Immediate trigger ("dev-immediate"), identified', 'immediate', ['open-dev-immediate'], 3000);
flows.D5 = triggerFlow('Delayed 20 s trigger ("dev-delayed"), identified', 'delayed', ['open-dev-delayed'], 22000);
flows.D6 = triggerFlow('Manual showForm, visitor', 'manual', ['tab-events', 'show-form'], 2000, 'visitor');
flows.D7 = triggerFlow('Page visit, visitor', 'pageVisit', ['open-dev-page'], 2000, 'visitor');

/** Secure identify against the real gateway. */
function secureFlow(title, keyName, signature, identified) {
  return {
    title,
    dev: true,
    async run() {
      const key = dev[keyName];
      openDev('login', dev.forms.manual.id, {
        API_KEY: key.sdkKey,
        SECRET: key.secret,
        SESSION: key.sessionTimeMinutes > 0 ? 'yes' : 'no',
        SIGNATURE: signature,
      });
      await sleep(5000);
      flow('expect-status', { IDENTIFIED: identified ? 'yes' : 'no' });
    },
  };
}

flows.D8 = secureFlow('Secure key, valid signature', 'secureKey', 'valid', true);
flows.D9 = secureFlow('Secure key, wrong signature', 'secureKey', 'wrong', false);
flows.D10 = secureFlow('Session-time key, valid signature', 'secureSessionKey', 'valid', true);
flows.D11 = secureFlow('Session-time key, no signature', 'secureSessionKey', 'none', false);

// ---------------------------------------------------------------------------

const selected = Object.entries(flows).filter(([id]) => !only || only.includes(id));
const results = [];
for (const [id, def] of selected) {
  if (def.dev && !dev) {
    results.push([id, def.title, 'SKIPPED', ['no e2e/.results/dev-project.json']]);
    continue;
  }
  const checks = new Checks();
  const started = Date.now();
  try {
    await def.run(checks);
  } catch (e) {
    checks.failures.push(String(e.message ?? e));
  }
  const seconds = Math.round((Date.now() - started) / 1000);
  results.push([id, def.title, checks.failures.length ? 'FAIL' : 'pass', checks.failures, seconds]);
  console.log(`${checks.failures.length ? 'FAIL' : 'pass'}  ${id}  ${def.title}  (${seconds} s)`);
  for (const f of checks.failures) console.log(`        ${f}`);
}
const failed = results.filter((r) => r[2] === 'FAIL').length;
console.log(`\n${platform}: ${results.length - failed} of ${results.length} passed`);
process.exit(failed ? 1 : 0);
