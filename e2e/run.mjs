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

import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
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
/** Every element Maestro sees on screen, with its text and bounds. */
function elements() {
  const res = spawnSync('maestro', ['--device', device, 'hierarchy'], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, MAESTRO_CLI_NO_ANALYTICS: '1' },
  });
  const out = [];
  const walk = (node) => {
    const a = node.attributes ?? {};
    const m = /\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/.exec(a.bounds ?? '');
    if (m) {
      const [left, top, right, bottom] = m.slice(1).map(Number);
      out.push({ text: a.text || a.accessibilityText || '', left, top, right, bottom });
    }
    (node.children ?? []).forEach(walk);
  };
  walk(JSON.parse(res.stdout.slice(res.stdout.indexOf('{'))));
  return out;
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
    return !!condition;
  }
  /** Something worth printing whether or not the flow passes. */
  notes = [];
  note(text) {
    this.notes.push(text);
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
    TRACK_ROOT: 'no',
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
  title: 'Visitor: a survey shown and closed sends dismiss-form and no survey events',
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
    const dismissals = await requests('dismiss-form');
    c.eq('dismiss-form requests', dismissals.map((r) => r.status), [200]);
    c.ok('the dismissal carries the form id', Boolean(dismissals[0]?.body?.formConfigurationId), JSON.stringify(dismissals[0]?.body));
    c.ok('the dismissal has no user headers', !dismissals[0]?.headers?.['x-user-name'] && !dismissals[0]?.headers?.['x-user-id']);
    c.eq('403s', await count(undefined, 403), 0);
    const events = await appEvents();
    c.ok('the app got form:close', events.some((e) => e.type === 'formClose'));
    c.ok('the app got form:dismissed', events.some((e) => e.type === 'formDismissed'));
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

flows.M8 = {
  title: 'Inline form: shown in its slot, the X is a dismissal, then shown again',
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openMock();
    await sleep(3000);
    tap('tab-inline');
    await mock('/__mock/reset?keepScenario=1', 'POST');
    tap('inline-show');
    flow('expect', { TEXT: 'Submit', TIMEOUT: 25000 });
    // The tab bar is still there: the survey is in the page, not over it.
    flow('expect', { TEXT: 'Show the form inline', TIMEOUT: 5000 });
    tapText('Close');
    await sleep(4000);
    c.eq('show-form requests', await count('show-form', 200), 1);
    c.eq('dismiss-form requests', await count('dismiss-form', 200), 1);
    c.ok('the app got form:dismissed', (await appEvents()).some((e) => e.type === 'formDismissed'));
    // The guard is free again: the same form can be shown a second time.
    tap('inline-show');
    flow('expect', { TEXT: 'Submit', TIMEOUT: 25000 });
    c.eq('show-form requests after showing it again', await count('show-form', 200), 2);
  },
};

const screenNames = async () =>
  (await requests('track-screen')).map((r) => r.body?.$deviceInfo?.$urlOrScreenName);

flows.M9 = {
  title: 'trackRootRoute: "/" is tracked only when it is turned on',
  async run(c) {
    // Off, the default.
    await mock('/__mock/reset', 'POST');
    openMock();
    await sleep(3000);
    const before = await screenNames();
    tap('open-root');
    await sleep(3000);
    c.eq('off: screens tracked after opening "/"', await screenNames(), before);

    // On.
    await mock('/__mock/reset', 'POST');
    open({ TRACK_ROOT: 'yes' });
    await sleep(3000);
    tap('open-root');
    await sleep(3000);
    tap('go-back');
    await sleep(3000);
    const screens = await screenNames();
    c.eq('on: "/" tracked once', screens.filter((s) => s === '/').length, 1);
    c.eq('on: the last two screens', screens.slice(-2), ['/', '/home']);
    c.eq('failed requests', (await requests()).filter((r) => r.status >= 400).length, 0);
  },
};

flows.M10 = {
  title: 'Log out, then log in as another user: every later request is the new user',
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openMock();
    await sleep(3000);
    tap('tab-events');
    tap('track-custom-event');
    await sleep(2000);
    tap('tab-home');
    tap('logout');
    await sleep(2000);
    tap('login-button'); // the login screen offers a new user name each time
    await sleep(3000);
    tap('tab-events');
    tap('track-custom-event');
    tap('show-form');
    tapText('Close');
    await sleep(4000);

    const all = await requests();
    const at = all.flatMap((r, i) => (r.endpoint === 'identify-user' ? [i] : []));
    c.eq('identify requests', at.length, 2);
    if (at.length !== 2) return;
    const name = (r) => header(r, 'x-user-name');
    const id = (r) => header(r, 'x-user-id');
    const [first, second] = [all[at[0]], all[at[1]]];
    c.ok('the two logins are different users', name(first) && name(second) && name(first) !== name(second));
    c.ok('the second identify carries no user id', !id(second));
    const asFirst = all.slice(at[0] + 1, at[1]);
    const asSecond = all.slice(at[1] + 1);
    const firstIds = new Set(asFirst.map(id).filter(Boolean));
    c.eq('user names after the second login', [...new Set(asSecond.map(name))], [name(second)]);
    const secondIds = [...new Set(asSecond.map(id))];
    c.ok('one user id after the second login', secondIds.length === 1 && !!secondIds[0], JSON.stringify(secondIds));
    c.ok('it is not the first user\'s id', !firstIds.has(secondIds[0]));
    c.ok('nothing before the second login carries the second user', asFirst.every((r) => name(r) !== name(second)));
    c.ok(
      'both identity headers, or neither, on every other request',
      [...asFirst, ...asSecond].every((r) => !!name(r) === !!id(r)),
    );
    c.ok('the second user made requests', asSecond.length >= 3, `${asSecond.length}`);
    const dismiss = (await requests('dismiss-form')).at(-1);
    c.eq('the dismissal is the second user\'s', [dismiss?.status, name(dismiss ?? { headers: {} })], [200, name(second)]);
    c.eq('401s', await count(undefined, 401), 0);
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
      c.ok('the X is a dismissal', dismissed);
      const hooks = await hookCalls();
      const sent = (endpoint) => hooks.filter((h) => h.endpoint === endpoint && h.outcome !== 'skipped');
      c.eq('dismiss-form calls, per the hooks', sent('dismiss-form').map((h) => h.status), [200]);
      if (identity !== 'login') c.eq('a visitor sends no survey events', sent('track-event').length, 0);
      const failed = hooks.filter((h) => h.outcome === 'error' && !(h.endpoint === 'show-form' && h.status === 404));
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

flows.D12 = {
  title: 'Submit on DEV, then the X on the thank-you screen',
  dev: true,
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openDev('login', dev.forms.manual.id);
    await sleep(3000);
    tap('tab-events');
    tap('show-form');
    flow('submit-dev-form');
    await sleep(2000);
    tapText('Close');
    await sleep(4000);
    const events = await appEvents();
    const types = events.map((e) => e.type);
    c.ok('the app got form:submit', types.includes('formSubmit'), types.join(','));
    c.ok('the app got form:close', types.includes('formClose'), types.join(','));
    c.ok('closing after the submit is not a dismissal', !types.includes('formDismissed'), types.join(','));
    c.ok('every app event carries the form id', events.every((e) => e.formId === dev.forms.manual.id));
    const hooks = await hookCalls();
    const submits = hooks.filter((h) => h.endpoint === 'submit-form');
    c.ok('a submit-form request succeeded', submits.some((h) => h.outcome === 'ok'), JSON.stringify(submits));
    c.eq('dismiss-form requests, per the hooks', hooks.filter((h) => h.endpoint === 'dismiss-form').length, 0);
    const failed = hooks.filter((h) => h.outcome === 'error');
    c.eq('failed requests, per the hooks', failed.map((h) => `${h.endpoint} ${h.status}`), []);
  },
};

const identifies = async () => (await reports()).filter((h) => h.kind === 'identify');

/**
 * The user id the SDK holds, read from the Home tab once it has one.
 * identifyUser() returns before the server replies, so the id can take a
 * moment, longer when the device's network is slow.
 */
async function userIdNow() {
  for (let i = 0; i < 8; i++) {
    tap('refresh-status');
    await sleep(1500);
    const id = (await reports()).filter((h) => h.kind === 'status').at(-1)?.userId;
    if (id) return id;
    await sleep(3000);
  }
  return '';
}

flows.D13 = {
  title: 'Log out, then log in as another user, on DEV',
  dev: true,
  async run(c) {
    await mock('/__mock/reset', 'POST');
    openDev('login', dev.forms.manual.id);
    await sleep(3000);
    const firstId = await userIdNow();
    tap('tab-events');
    tap('track-custom-event');
    await sleep(2000);
    tap('tab-home');
    tap('logout');
    await sleep(2000);
    tap('login-button');
    await sleep(4000);
    const secondId = await userIdNow();
    tap('tab-events');
    tap('track-custom-event');
    tap('show-form');
    await sleep(2000);
    tapText('Close');
    await sleep(4000);

    const logins = await identifies();
    c.eq('logins', logins.length, 2);
    c.ok('two different user names', logins[0]?.userName !== logins[1]?.userName);
    c.ok('two different user ids from the server', !!firstId && !!secondId && firstId !== secondId, JSON.stringify([firstId, secondId]));
    const hooks = await hookCalls();
    c.eq('identify-user requests that succeeded', hooks.filter((h) => h.endpoint === 'identify-user' && h.outcome === 'ok').length, 2);
    c.eq('forms shown', await shown(), [dev.forms.manual.id]);
    c.ok('the second user\'s X is a dismissal', (await appEvents()).some((e) => e.type === 'formDismissed' && e.formId === dev.forms.manual.id));
    const sinceSecond = hooks.filter((h) => h.receivedAt > logins[1]?.receivedAt);
    c.ok('the second user sent requests', sinceSecond.filter((h) => h.outcome === 'ok').length >= 3, `${sinceSecond.length}`);
    const failed = hooks.filter((h) => h.outcome === 'error' && !(h.endpoint === 'show-form' && h.status === 404));
    c.eq('failed requests, per the hooks', failed.map((h) => `${h.endpoint} ${h.status}`), []);
  },
};

flows.D14 = {
  title: '"Remind me later" on DEV: an app event and a survey event, not a dismissal',
  dev: true,
  async run(c) {
    const form = dev.forms.remindMeLater?.id;
    if (!form) return c.ok('a remindMeLater form in dev-project.json', false);
    await mock('/__mock/reset', 'POST');
    openDev('login', dev.forms.manual.id);
    await sleep(3000);
    tap('tab-events');
    // The form is set up the way the admin asks for this button: an automatic
    // trigger with follow-up on, and a welcome screen, where the page draws it.
    tap('track-fl-remind');
    flow('expect', { TEXT: 'Get Started', TIMEOUT: 25000 });
    let labelled = true;
    try {
      flow('expect', { TEXT: 'Remind me later', TIMEOUT: 4000 });
    } catch {
      labelled = false;
    }
    c.note(labelled ? 'the button shows its label' : 'the survey page drew the button without its label');
    if (labelled) {
      tapText('Remind me later');
    } else {
      // A blank button: the one on the same row as "Get Started", to its left.
      const all = elements();
      const start = all.find((e) => e.text === 'Get Started');
      const row = (e) => Math.abs((e.top + e.bottom) / 2 - (start.top + start.bottom) / 2) < (start.bottom - start.top) / 4;
      const blank = all
        .filter((e) => !e.text && row(e) && e.right <= start.left && e.right - e.left > 20 && e.bottom - e.top > (start.bottom - start.top) / 2)
        .sort((a, b) => (a.right - a.left) - (b.right - b.left))[0];
      if (!c.ok('a blank button beside "Get Started"', !!blank)) return;
      flow('tap-point', { POINT: `${Math.round((blank.left + blank.right) / 2)},${Math.round((blank.top + blank.bottom) / 2)}` });
    }
    await sleep(5000);

    c.eq('forms shown', await shown(), [form]);
    const events = await appEvents();
    const types = events.map((e) => e.type);
    c.ok('the app got form:remindmelater with the form id', events.some((e) => e.type === 'formRemindMeLater' && e.formId === form), JSON.stringify(events));
    c.ok('it is not a dismissal', !types.includes('formDismissed'), types.join(','));
    c.ok('no app event has an empty form id', events.every((e) => e.formId), JSON.stringify(events));
    c.ok('the survey closed', !elements().some((e) => e.text === 'Get Started'));

    const hooks = await hookCalls();
    c.eq('dismiss-form requests, per the hooks', hooks.filter((h) => h.endpoint === 'dismiss-form').length, 0);
    // track-event calls, in order: the trigger, form:show, then form:remindmelater.
    // The server does not handle that last one yet, so its status is noted and
    // does not fail the flow.
    const tracked = hooks.filter((h) => h.endpoint === 'track-event' && h.outcome !== 'skipped');
    c.eq('track-event requests', tracked.length, 3);
    const last = tracked.at(-1);
    c.note(`form:remindmelater was answered with ${last?.status ?? last?.outcome}`);
    const failed = hooks.filter((h) => h.outcome === 'error' && h !== last && !(h.endpoint === 'show-form' && h.status === 404));
    c.eq('other failed requests, per the hooks', failed.map((h) => `${h.endpoint} ${h.status}`), []);
  },
};

/**
 * Takes screenshots of the device, one after the other, into [dir] until
 * stop() is called. It runs beside the Maestro flows, which take a few
 * seconds to start and to finish, so nothing on screen is missed.
 * stop() returns [seconds since the start, size in bytes] for each frame; a
 * PNG's size changes when the screen does.
 */
function watchScreen(dir) {
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const shot =
    platform === 'android'
      ? `adb -s ${device} exec-out screencap -p > "$f"`
      : `xcrun simctl io ${device} screenshot --type=png "$f" >/dev/null 2>&1`;
  const loop = `i=1000; while [ ! -e "${dir}/stop" ] && [ $i -lt 1900 ]; do f="${dir}/$i.png"; ${shot}; i=$((i+1)); done`;
  const started = Date.now();
  const child = spawn('sh', ['-c', loop], { stdio: 'ignore' });
  return {
    async stop() {
      writeFileSync(join(dir, 'stop'), '');
      await new Promise((done) => child.on('exit', done));
      return readdirSync(dir)
        .filter((f) => f.endsWith('.png'))
        .sort()
        .map((f) => {
          const st = statSync(join(dir, f));
          return [((st.mtimeMs - started) / 1000).toFixed(1), st.size];
        });
    },
  };
}

flows.D16 = {
  title: 'Q&A with AI: the answer arrives in pieces, and the form submits',
  dev: true,
  async run(c) {
    const form = dev.forms.qna?.id;
    if (!form) return c.ok('a qna form in dev-project.json', false);
    await mock('/__mock/reset', 'POST');
    openDev('login', form);
    await sleep(3000);
    tap('tab-events');
    tap('show-form');
    tapText('Ask a question.*'); // opens the chat
    flow('expect', { TEXT: 'Ask the AI a question to get started.', TIMEOUT: 15000 });
    // The chat's input is the wide field on the same row as its send button.
    const send = elements().find((e) => e.text === 'Ask AI');
    if (!c.ok('the chat has a send button', !!send)) return;
    flow('qna-ask', {
      POINT: `${Math.round(send.left / 2)},${Math.round((send.top + send.bottom) / 2)}`,
      // A long answer, so the stream lasts long enough to be seen in frames
      // taken a third of a second apart.
      QUESTION: 'Explain everything Encatch can do in detail in at least twelve sentences',
    });

    // Watch the screen from before the question is sent until the chat counts
    // it as answered. An answer that streams makes the screen grow in several
    // frames in a row; one that arrives whole changes it once.
    const watch = watchScreen(join(here, '.results', `qna-${platform}`));
    await sleep(1500);
    tapText('Ask AI');
    flow('expect', { TEXT: '19 of 20 questions remaining', TIMEOUT: 40000 });
    const frames = await watch.stop();
    // The longest run of frames that each grew over the one before.
    let run = [];
    let longest = [];
    frames.forEach(([at, n], i) => {
      run = i > 0 && n - frames[i - 1][1] > 400 ? [...run, at] : [];
      if (run.length > longest.length) longest = run;
    });
    c.note(`${frames.length} frames; the screen grew in ${longest.length} frames in a row, at ${longest.join(', ') || 'no point'} s (frames kept in e2e/.results/qna-${platform})`);
    c.ok('the answer grew over at least three frames in a row', longest.length >= 3, `${longest.length}`);

    // A conversation is only saved with the form's submit. The chat's own
    // close button is the last "Close" on screen; the form's is behind it.
    const close = elements().filter((e) => e.text === 'Close').at(-1);
    if (!c.ok('the chat has a close button', !!close)) return;
    flow('tap-point', { POINT: `${Math.round((close.left + close.right) / 2)},${Math.round((close.top + close.bottom) / 2)}` });
    tapText('Submit');
    await sleep(5000);
    const types = (await appEvents()).map((e) => e.type);
    c.ok('the app got form:submit', types.includes('formSubmit'), types.join(','));
    const hooks = await hookCalls();
    c.ok('a submit-form request succeeded', hooks.some((h) => h.endpoint === 'submit-form' && h.outcome === 'ok'));
    const failed = hooks.filter((h) => h.outcome === 'error');
    c.eq('failed requests, per the hooks', failed.map((h) => `${h.endpoint} ${h.status}`), []);
  },
};

flows.D15 = {
  title: 'A real signature expiry on the session-time key (takes about 18 minutes)',
  dev: true,
  slow: true,
  async run(c) {
    const key = dev.secureSessionKey;
    if (platform === 'android') {
      // The screen must stay on for the whole wait.
      spawnSync('adb', ['-s', device, 'shell', 'svc', 'power', 'stayon', 'true']);
    }
    await mock('/__mock/reset', 'POST');
    openDev('login', dev.forms.manual.id, {
      API_KEY: key.sdkKey,
      SECRET: key.secret,
      SESSION: 'yes',
      SIGNATURE: 'valid',
    });
    await sleep(5000);
    flow('expect-status', { IDENTIFIED: 'yes' });
    const login = (await identifies())[0];
    const minutes = (h) => ((h.receivedAt - login.receivedAt) / 60000).toFixed(1);
    const line = (h) => `${minutes(h)} min ${h.endpoint} ${h.status ?? h.reason ?? h.outcome}`;

    await sleep((key.sessionTimeMinutes + 1.5) * 60000);
    tap('tab-events');
    tap('track-custom-event');
    await sleep(5000);

    let hooks = await hookCalls();
    const notOk = hooks.filter((h) => h.outcome !== 'ok');
    c.note(`not sent or not accepted, first 12: ${notOk.slice(0, 12).map(line).join('; ') || 'none'}`);
    const rejected = hooks.find((h) => h.status === 401);
    c.ok('the server answered 401 once the session time had passed', !!rejected);
    if (rejected) {
      c.note(`first 401: ${line(rejected)}`);
      c.ok('not before the session time', Number(minutes(rejected)) >= key.sessionTimeMinutes - 0.5, line(rejected));
      const after = hooks.filter((h) => h.receivedAt > rejected.receivedAt);
      c.eq('requests sent after the 401, before identifying again', after.filter((h) => h.outcome !== 'skipped').map(line), []);
      c.ok(
        'the tapped event was held back as signature-expired',
        after.some((h) => h.endpoint === 'track-event' && h.reason === 'signature-expired'),
        after.map(line).join('; '),
      );
    }
    c.eq('failures other than 401', hooks.filter((h) => h.outcome === 'error' && h.status !== 401).map(line), []);

    // The app's backend hands over a fresh signature.
    tap('tab-home');
    tap('reidentify');
    await sleep(5000);
    const again = (await identifies()).at(-1);
    tap('tab-events');
    tap('track-screen-manual');
    await sleep(6000);
    hooks = (await hookCalls()).filter((h) => h.receivedAt > again.receivedAt - 5000);
    c.ok('identifying again succeeded', hooks.some((h) => h.endpoint === 'identify-user' && h.outcome === 'ok'), hooks.map(line).join('; '));
    c.ok('tracking resumed', hooks.some((h) => h.endpoint === 'track-screen' && h.outcome === 'ok'), hooks.map(line).join('; '));
    c.eq('failures after identifying again', hooks.filter((h) => h.outcome === 'error').map(line), []);
  },
};

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

// A slow flow only runs when it is named with --only.
const selected = Object.entries(flows).filter(([id, def]) => (only ? only.includes(id) : !def.slow));
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
  for (const n of checks.notes) console.log(`        note: ${n}`);
}
const failed = results.filter((r) => r[2] === 'FAIL').length;
console.log(`\n${platform}: ${results.length - failed} of ${results.length} passed`);
process.exit(failed ? 1 : 0);
