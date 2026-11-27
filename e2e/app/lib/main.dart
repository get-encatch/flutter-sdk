// End-to-end test app for the Encatch Flutter SDK. See README.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// Build-time defaults (see README). All of them can be changed on the set-up
// screen.
const _envDefault = String.fromEnvironment('E2E_ENV', defaultValue: 'mock');
const _apiBaseDefault = String.fromEnvironment('E2E_API_BASE');
const _webHostDefault = String.fromEnvironment(
  'E2E_WEB_HOST',
  defaultValue: 'https://form.dev.encatch.com',
);
const _apiKeyDefault = String.fromEnvironment('E2E_API_KEY');
const _secretDefault = String.fromEnvironment('E2E_SECRET');
const _sessionTimeDefault = bool.fromEnvironment('E2E_SESSION_TIME');
const _collectorDefault = String.fromEnvironment('E2E_COLLECTOR');
const _formIdDefault = String.fromEnvironment(
  'E2E_FORM_ID',
  defaultValue: '0190f1d2-0000-7000-8000-00000000f001',
);

/// The host machine as seen from the device.
String get _hostMachine => Platform.isAndroid ? '10.0.2.2' : 'localhost';
String get _localMock => 'http://$_hostMachine:8797';

class E2eConfig {
  E2eConfig({
    required this.env,
    required this.apiBase,
    required this.webHost,
    required this.apiKey,
    required this.secret,
    required this.sessionTime,
    required this.collector,
    required this.formId,
    required this.trackRoot,
    required this.autoStartVisitor,
    required this.persistUser,
  });
  final String env; // 'mock' or 'dev'
  final String apiBase;
  final String webHost;
  final String apiKey;

  /// Secret of a secure test key, for signing locally on DEV. Empty otherwise.
  final String secret;
  final bool sessionTime;

  /// Where the app reports what the SDK did. Always the local mock.
  final String collector;
  final String formId;

  /// Passed to `EncatchNavigatorObserver(trackRootRoute:)`. Off by default,
  /// like the SDK.
  final bool trackRoot;

  /// Passed to `EncatchProvider(autoStartVisitorSession:)`. On by default,
  /// like the SDK.
  final bool autoStartVisitor;

  /// Passed to `EncatchConfig(persistUserAcrossRestarts:)`. On by default,
  /// like the SDK.
  final bool persistUser;

  bool get isMock => env == 'mock';
}

late E2eConfig config;

/// How many times the login screen's "Track a screen myself" was tapped. Each
/// tap tracks a different screen name, so a run can tell them apart.
int ownScreens = 0;

/// Lines shown at the bottom of every screen, newest first.
final log = ValueNotifier<List<String>>([]);

void note(String line) {
  log.value = [line, ...log.value.take(11)];
}

/// Tells the local collector what the SDK did. Never sent to Encatch.
void report(String kind, Map<String, Object?> data) {
  note('$kind ${data.values.join(' ')}');
  http
      .post(
        Uri.parse('${config.collector}/__mock/hooks'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'kind': kind, ...data}),
      )
      .catchError((Object _) => http.Response('', 599));
}

/// Tells the local collector about a debug-hook call. Not shown on screen:
/// there is one per request.
void hook(Map<String, Object?> data) {
  http
      .post(
        Uri.parse('${config.collector}/__mock/hooks'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'kind': 'hook', ...data}),
      )
      .catchError((Object _) => http.Response('', 599));
}

/// A stable id for the test runner.
Widget tid(String id, Widget child) =>
    Semantics(identifier: id, container: true, child: child);

Widget button(String id, String label, VoidCallback? onPressed) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: tid(
    id,
    SizedBox(
      width: double.infinity,
      child: ElevatedButton(onPressed: onPressed, child: Text(label)),
    ),
  ),
);

void main() => runApp(const E2eApp());

class E2eApp extends StatefulWidget {
  const E2eApp({super.key});
  @override
  State<E2eApp> createState() => _E2eAppState();
}

class _E2eAppState extends State<E2eApp> {
  bool _started = false;
  void Function()? _unsubscribe;

  void _start(E2eConfig chosen) {
    config = chosen;
    _unsubscribe = Encatch.on((type, payload) {
      report('event', {'type': type.name, 'formId': payload.formId ?? ''});
    });
    setState(() => _started = true);
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) {
      return MaterialApp(
        title: 'Encatch FL E2E',
        home: SetupScreen(onStart: _start),
      );
    }
    return EncatchProvider(
      apiKey: config.apiKey,
      autoStartVisitorSession: config.autoStartVisitor,
      config: EncatchConfig(
        apiBaseUrl: config.apiBase,
        webHost: config.webHost,
        debugMode: true,
        persistUserAcrossRestarts: config.persistUser,
        // What an app does: get a fresh signature from its backend and
        // identify again, unless the user signed out or switched meanwhile.
        onSignatureExpired: (info) async {
          report('signatureExpired', {'userName': info.userName});
          final secure = await sign(info.userName, SignatureMode.valid);
          if (Encatch.userName != info.userName) return;
          await Encatch.identifyUser(
            info.userName,
            options: secure == null ? null : IdentifyOptions(secure: secure),
          );
          report('identify', {'userName': info.userName, 'signature': 'fresh'});
        },
        onBeforeShowForm: (payload) async {
          report('beforeShowForm', {
            'formId': payload.formId,
            'trigger': payload.triggerType.name,
          });
          return true;
        },
        // The debug hooks, reported to the local collector so a run can check
        // them. Only what the hooks carry: no key, headers or bodies.
        onResponse: (info) => hook({
          'endpoint': info.endpoint,
          'attempt': info.attempt,
          'outcome': info.outcome,
          'status': info.status,
          'reason': info.reason,
          'rateLimited': info.rateLimited,
        }),
      ),
      child: MaterialApp(
        title: 'Encatch FL E2E',
        navigatorObservers: [
          EncatchNavigatorObserver(trackRootRoute: config.trackRoot),
        ],
        initialRoute: '/login',
        routes: {
          '/login': (_) => const LoginScreen(),
          '/home': (_) => const HomeScreen(),
          '/dev-page': (_) => const PlainScreen('dev-page'),
          '/dev-immediate': (_) => const PlainScreen('dev-immediate'),
          '/dev-delayed': (_) => const PlainScreen('dev-delayed'),
          '/checkout': (_) => const PlainScreen('checkout'),
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Set-up
// ---------------------------------------------------------------------------

class SetupScreen extends StatefulWidget {
  const SetupScreen({required this.onStart, super.key});
  final void Function(E2eConfig) onStart;
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  String _env = _envDefault == 'dev' ? 'dev' : 'mock';
  late final _apiBase = TextEditingController(text: _defaultApiBase(_env));
  late final _apiKey = TextEditingController(text: _defaultApiKey(_env));
  final _secret = TextEditingController(text: _secretDefault);
  final _formId = TextEditingController(text: _formIdDefault);
  bool _sessionTime = _sessionTimeDefault;
  bool _trackRoot = false;
  bool _autoStartVisitor = true;
  bool _persistUser = true;

  static String _defaultApiBase(String env) => _apiBaseDefault.isNotEmpty
      ? _apiBaseDefault
      : (env == 'dev' ? 'https://api.dev.encatch.com' : _localMock);
  static String _defaultApiKey(String env) => _apiKeyDefault.isNotEmpty
      ? _apiKeyDefault
      : (env == 'dev' ? '' : 'mock-api-key');

  void _setEnv(String env) {
    setState(() {
      _env = env;
      _apiBase.text = _defaultApiBase(env);
      _apiKey.text = _defaultApiKey(env);
      // The built-in form id belongs to the mock. Start DEV with an empty
      // field, so a test types the id it wants without having to erase.
      _formId.text = env == 'dev' && _envDefault != 'dev' ? '' : _formIdDefault;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set-up')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          tid('setup-env', Text('Environment: $_env')),
          Row(
            children: [
              Expanded(
                child: button('env-mock', 'Mock', () => _setEnv('mock')),
              ),
              const SizedBox(width: 8),
              Expanded(child: button('env-dev', 'DEV', () => _setEnv('dev'))),
            ],
          ),
          tid(
            'setup-api-base',
            TextField(
              controller: _apiBase,
              decoration: const InputDecoration(labelText: 'API base URL'),
            ),
          ),
          tid(
            'setup-api-key',
            TextField(
              controller: _apiKey,
              decoration: const InputDecoration(labelText: 'API key'),
            ),
          ),
          tid(
            'setup-secret',
            TextField(
              controller: _secret,
              decoration: const InputDecoration(
                labelText: 'Secret of a secure test key (DEV only)',
              ),
            ),
          ),
          tid(
            'setup-session-time',
            SwitchListTile(
              title: const Text('Key has a session time'),
              value: _sessionTime,
              onChanged: (v) => setState(() => _sessionTime = v),
            ),
          ),
          tid(
            'setup-form-id',
            TextField(
              controller: _formId,
              decoration: const InputDecoration(labelText: 'Manual form id'),
            ),
          ),
          tid(
            'setup-track-root',
            SwitchListTile(
              dense: true,
              title: const Text('Track the "/" route'),
              value: _trackRoot,
              onChanged: (v) => setState(() => _trackRoot = v),
            ),
          ),
          tid(
            'setup-auto-start-visitor',
            SwitchListTile(
              dense: true,
              title: const Text('Auto-start visitor session'),
              value: _autoStartVisitor,
              onChanged: (v) => setState(() => _autoStartVisitor = v),
            ),
          ),
          tid(
            'setup-persist-user',
            SwitchListTile(
              dense: true,
              title: const Text('Keep the user after an app restart'),
              value: _persistUser,
              onChanged: (v) => setState(() => _persistUser = v),
            ),
          ),
          const SizedBox(height: 12),
          button('setup-start', 'Start', () {
            widget.onStart(
              E2eConfig(
                env: _env,
                apiBase: _apiBase.text.trim(),
                webHost: _webHostDefault,
                apiKey: _apiKey.text.trim(),
                secret: _secret.text.trim(),
                sessionTime: _sessionTime,
                collector: _collectorDefault.isNotEmpty
                    ? _collectorDefault
                    : _localMock,
                formId: _formId.text.trim(),
                trackRoot: _trackRoot,
                autoStartVisitor: _autoStartVisitor,
                persistUser: _persistUser,
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Login
// ---------------------------------------------------------------------------

/// `expired` signs a time 20 minutes old: already past a 15-minute session
/// time.
enum SignatureMode { none, valid, wrong, expired }

const _expiredAge = Duration(minutes: 20);

/// Stands in for the customer's backend: returns a signature for [userName].
Future<SecureOptions?> sign(String userName, SignatureMode mode) async {
  if (mode == SignatureMode.none) return null;
  if (mode == SignatureMode.wrong) {
    return const SecureOptions(signature: 'not-the-right-signature');
  }
  if (config.isMock) {
    final r = await http.get(
      Uri.parse(
        '${config.collector}/__mock/sign'
        '?userName=${Uri.encodeQueryComponent(userName)}'
        '&apiKey=${Uri.encodeQueryComponent(config.apiKey)}'
        '${mode == SignatureMode.expired ? '&ageMinutes=${_expiredAge.inMinutes}' : ''}',
      ),
    );
    final json = jsonDecode(r.body) as Map<String, dynamic>;
    return SecureOptions(
      signature: json['signature'] as String,
      generatedDateTimeinUTC: json['time'] as String?,
    );
  }
  final age = mode == SignatureMode.expired ? _expiredAge : Duration.zero;
  final time = config.sessionTime
      ? '${DateTime.now().subtract(age).millisecondsSinceEpoch}'
      : null;
  final signature = Hmac(
    sha256,
    utf8.encode(config.secret),
  ).convert(utf8.encode('$userName${time ?? ''}')).toString();
  return SecureOptions(signature: signature, generatedDateTimeinUTC: time);
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userName = TextEditingController(
    text: 'flutter-e2e-${DateTime.now().millisecondsSinceEpoch}',
  );
  SignatureMode _mode = SignatureMode.none;

  Future<void> _login() async {
    final name = _userName.text.trim();
    final secure = await sign(name, _mode);
    await Encatch.identifyUser(
      name,
      options: secure == null ? null : IdentifyOptions(secure: secure),
    );
    report('identify', {'userName': name, 'signature': _mode.name});
    if (mounted) Navigator.of(context).pushReplacementNamed('/home');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Login (${config.env})')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          tid(
            'login-username',
            TextField(
              controller: _userName,
              decoration: const InputDecoration(labelText: 'User name'),
            ),
          ),
          tid('login-signature', Text('Signature: ${_mode.name}')),
          Row(
            children: [
              for (final mode in SignatureMode.values) ...[
                Expanded(
                  child: button(
                    'sig-${mode.name}',
                    mode.name,
                    () => setState(() => _mode = mode),
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ],
          ),
          button('login-button', 'Log in', _login),
          button('visitor-button', 'Continue as a visitor', () {
            note('visitor');
            Navigator.of(context).pushReplacementNamed('/home');
          }),
          tid('login-identified', Text('identified: ${Encatch.isIdentified}')),
          // Read on a tap, not at build: init is still running when this
          // screen is first built.
          button('login-status', 'Report status', () {
            report('status', {
              'userName': Encatch.userName ?? '',
              'userId': Encatch.userId ?? '',
              'identified': Encatch.isIdentified,
            });
            setState(() {});
          }),
          ...identifyButtons(),
          // The app's own call, which is sent whatever the session is doing.
          button('track-own-screen', 'Track a screen myself', () {
            ownScreens++;
            Encatch.trackScreen('/own-$ownScreens');
            note('own screen /own-$ownScreens');
          }),
          const LogPanel(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Home, with tabs
// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      const HomeTab(),
      const EventsTab(),
      const BurstTab(),
      const InlineTab(),
    ];
    return Scaffold(
      appBar: AppBar(title: Text('Encatch FL E2E (${config.env})')),
      body: tabs[_tab],
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        items: [
          for (final (id, label, icon) in [
            ('tab-home', 'Home', Icons.home),
            ('tab-events', 'Events', Icons.bolt),
            ('tab-burst', 'Burst', Icons.speed),
            ('tab-inline', 'Inline', Icons.view_agenda),
          ])
            BottomNavigationBarItem(icon: tid(id, Icon(icon)), label: label),
        ],
      ),
    );
  }
}

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});
  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  @override
  Widget build(BuildContext context) {
    void open(String route) => Navigator.of(context).pushNamed(route);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        tid(
          'status-user',
          Text('user: ${Encatch.userName ?? '-'} id: ${Encatch.userId ?? '-'}'),
        ),
        // identifyUser() returns before the server replies, so the id is read
        // here, later, and not straight after logging in.
        button('refresh-status', 'Refresh status', () {
          report('status', {
            'userName': Encatch.userName ?? '',
            'userId': Encatch.userId ?? '',
            'identified': Encatch.isIdentified,
          });
          setState(() {});
        }),
        ...identifyButtons(),
        button('open-dev-page', 'Open dev-page', () => open('/dev-page')),
        button(
          'open-dev-immediate',
          'Open dev-immediate',
          () => open('/dev-immediate'),
        ),
        button(
          'open-dev-delayed',
          'Open dev-delayed',
          () => open('/dev-delayed'),
        ),
        button('open-checkout', 'Open checkout', () => open('/checkout')),
        // A route named "/", which the observer only reports when
        // trackRootRoute is on.
        button(
          'open-root',
          'Open a route named "/"',
          () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/'),
              builder: (_) => const PlainScreen('root'),
            ),
          ),
        ),
        // What an app does when its backend hands it a new signature.
        button('reidentify', 'Identify again, fresh signature', () async {
          final name = Encatch.userName;
          if (name == null) return;
          final secure = await sign(name, SignatureMode.valid);
          await Encatch.identifyUser(
            name,
            options: secure == null ? null : IdentifyOptions(secure: secure),
          );
          report('identify', {'userName': name, 'signature': 'fresh'});
        }),
        button('logout', 'Log out', () async {
          await Encatch.resetUser();
          note('logout');
          if (context.mounted) {
            Navigator.of(context).pushReplacementNamed('/login');
          }
        }),
        button('logout-login-race', 'Log out, then log in, not awaited', () {
          Encatch.resetUser();
          Encatch.identifyUser('flutter-e2e-race');
          note('race started');
        }),
        const LogPanel(),
      ],
    );
  }
}

class EventsTab extends StatefulWidget {
  const EventsTab({super.key});
  @override
  State<EventsTab> createState() => _EventsTabState();
}

class _EventsTabState extends State<EventsTab> {
  late final _formId = TextEditingController(text: config.formId);

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        button(
          'track-dev-event',
          'Track dev_event',
          () => Encatch.trackEvent('dev_event'),
        ),
        // Triggers the DEV form that has a "Remind me later" button. The name
        // starts with fl_ so no other test run on the project can trigger it.
        button(
          'track-fl-remind',
          'Track fl_remind_event',
          () => Encatch.trackEvent('fl_remind_event'),
        ),
        button(
          'track-custom-event',
          'Track button_tapped',
          () => Encatch.trackEvent('button_tapped'),
        ),
        button(
          'track-screen-manual',
          'Track screen manual-screen',
          () => Encatch.trackScreen('manual-screen'),
        ),
        tid(
          'form-id',
          TextField(
            controller: _formId,
            decoration: const InputDecoration(labelText: 'Form id'),
          ),
        ),
        button(
          'show-form',
          'Show form',
          () => Encatch.showForm(_formId.text.trim()),
        ),
        button('stop-session', 'Stop session', () => Encatch.stopSession()),
        button('start-session', 'Start session', () => Encatch.startSession()),
        button('pause-session', 'Pause session', Encatch.pauseSession),
        button('resume-session', 'Resume session', Encatch.resumeSession),
        const LogPanel(),
      ],
    );
  }
}

/// Fires many calls at once. Mock environment only, so a burst can never be
/// sent to a real server.
class BurstTab extends StatelessWidget {
  const BurstTab({super.key});

  @override
  Widget build(BuildContext context) {
    if (!config.isMock) {
      return Center(
        child: tid(
          'burst-disabled',
          const Text('Bursts only run against the mock.'),
        ),
      );
    }
    void burst(String name, int count, void Function(int i) call) {
      for (var i = 0; i < count; i++) {
        call(i);
      }
      note('burst $name x$count');
    }

    final user = Encatch.userName ?? 'flutter-e2e-burst';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        button(
          'burst-identify',
          '20 identical identifyUser',
          () => burst('identify', 20, (_) => Encatch.identifyUser(user)),
        ),
        button(
          'burst-event-same',
          '20 identical trackEvent',
          () => burst('event-same', 20, (_) => Encatch.trackEvent('burst')),
        ),
        button(
          'burst-event-different',
          '20 different trackEvent',
          () => burst(
            'event-different',
            20,
            (i) => Encatch.trackEvent('burst-$i'),
          ),
        ),
        button(
          'burst-screen-same',
          '20 identical trackScreen',
          () => burst('screen-same', 20, (_) => Encatch.trackScreen('/burst')),
        ),
        button(
          'burst-survey-screen',
          '18 trackScreen on a survey screen',
          () => burst(
            'survey-screen',
            18,
            (_) => Encatch.trackScreen('/checkout'),
          ),
        ),
        button('burst-reset-identify', 'resetUser then identifyUser', () {
          Encatch.resetUser();
          Encatch.identifyUser('flutter-e2e-race');
          note('burst reset-identify');
        }),
        const LogPanel(),
      ],
    );
  }
}

class InlineTab extends StatelessWidget {
  const InlineTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        button(
          'inline-show',
          'Show the form inline',
          () => Encatch.showForm(config.formId),
        ),
        tid('inline-slot', const EncatchInlineForm()),
        const LogPanel(),
      ],
    );
  }
}

class PlainScreen extends StatelessWidget {
  const PlainScreen(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          tid('screen-name', Text('Screen: $name')),
          button('go-back', 'Back', () => Navigator.of(context).pop()),
          const LogPanel(),
        ],
      ),
    );
  }
}

/// identifyUser() repeats and setUserProperties(), for the dedupe flow. They
/// act on the current user (the one the SDK holds), so they also work right
/// after a restart, before anyone logs in again.
List<Widget> identifyButtons() {
  String? user() => Encatch.userName;
  return [
    button('identify-again', 'Identify again', () {
      final name = user();
      if (name == null) return;
      Encatch.identifyUser(name);
      note('identify again $name');
    }),
    button('identify-free', 'Identify with plan free', () {
      final name = user();
      if (name == null) return;
      Encatch.identifyUser(
        name,
        traits: const UserTraits(set: {'e2e_plan': 'free'}),
      );
      note('identify free $name');
    }),
    button('set-props', 'Set properties', () {
      final name = user();
      if (name == null) return;
      Encatch.setUserProperties(
        name,
        const UserTraits(set: {'e2e_tier': 'gold'}, increment: {'e2e_taps': 1}),
      );
      note('set properties $name');
    }),
  ];
}

/// The newest things the SDK did, for on-screen checks.
class LogPanel extends StatelessWidget {
  const LogPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: log,
      builder: (_, lines, _) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: tid(
          'event-log',
          Text(
            lines.isEmpty ? '(nothing yet)' : lines.join('\n'),
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
        ),
      ),
    );
  }
}
