import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const EncatchProvider(
      apiKey: 'YOUR_API_KEY_HERE',
      config: EncatchConfig(
        debugMode: true,
        theme: EncatchTheme.system,
      ),
      child: MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Encatch Flutter Example',
      // Add EncatchNavigatorObserver for automatic screen tracking
      navigatorObservers: [EncatchNavigatorObserver()],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/settings': (context) => const SettingsScreen(),
      },
    );
  }
}

// ============================================================================
// Home Screen
// ============================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isIdentified = false;
  String _status = 'Not identified';

  @override
  void initState() {
    super.initState();

    // Listen to form lifecycle events
    Encatch.on((eventType, payload) {
      debugPrint('[Encatch Event] $eventType — formId: ${payload.formId}');
    });
  }

  Future<void> _identifyUser() async {
    try {
      await Encatch.identifyUser(
        'user@example.com',
        traits: UserTraits(
          set: {
            'name': 'Jane Doe',
            'plan': 'pro',
            'signupDate': DateTime.now().toIso8601String(),
          },
        ),
        options: const IdentifyOptions(
          locale: 'en-US',
          country: 'US',
        ),
      );
      setState(() {
        _isIdentified = true;
        _status = 'Identified as user@example.com';
      });
    } catch (e) {
      setState(() => _status = 'Identify failed: $e');
    }
  }

  Future<void> _trackEvent() async {
    await Encatch.trackEvent('button_tapped');
    setState(() => _status = 'Event tracked: button_tapped');
  }

  Future<void> _showForm() async {
    await Encatch.showForm('your-form-slug-here');
    setState(() => _status = 'Form triggered');
  }

  Future<void> _trackScreen() async {
    await Encatch.trackScreen('HomeScreen');
    setState(() => _status = 'Screen tracked: HomeScreen');
  }

  Future<void> _resetUser() async {
    await Encatch.resetUser();
    setState(() {
      _isIdentified = false;
      _status = 'User reset';
    });
  }

  Future<void> _submitNativeForm() async {
    // Example: submit a custom native form without showing the WebView
    final request = buildSubmitRequest(
      options: const BuildSubmitRequestOptions(
        formConfigurationId: 'your-form-configuration-id',
        triggerType: TriggerType.manual,
        responseLanguageCode: 'en',
      ),
      responses: [
        const NativeFormResponse(questionId: 'q1', type: 'rating', value: '5'),
        const NativeFormResponse(
          questionId: 'q2',
          type: 'short_answer',
          value: 'Great product!',
        ),
        const NativeFormResponse(questionId: 'q3', type: 'nps', value: '9'),
      ],
    );
    await Encatch.submitForm(request);
    setState(() => _status = 'Native form submitted');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Encatch Example'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SDK Status',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _status,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        _isIdentified ? Icons.person : Icons.person_outline,
                        size: 16,
                        color: _isIdentified ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _isIdentified ? 'Identified' : 'Anonymous',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: _isIdentified ? Colors.green : Colors.grey,
                            ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Identity actions
            Text('Identity', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _isIdentified ? null : _identifyUser,
              icon: const Icon(Icons.person_add),
              label: const Text('Identify User'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _isIdentified ? _resetUser : null,
              icon: const Icon(Icons.logout),
              label: const Text('Reset User'),
            ),
            const SizedBox(height: 24),

            // Tracking actions
            Text('Tracking', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _trackEvent,
              icon: const Icon(Icons.bolt),
              label: const Text('Track Event'),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _trackScreen,
              icon: const Icon(Icons.pageview),
              label: const Text('Track Screen'),
            ),
            const SizedBox(height: 24),

            // Form actions
            Text('Forms', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _showForm,
              icon: const Icon(Icons.feedback),
              label: const Text('Show Form (WebView)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _submitNativeForm,
              icon: const Icon(Icons.send),
              label: const Text('Submit Native Form'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Settings Screen (demonstrates screen tracking via EncatchNavigatorObserver)
// ============================================================================

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.language),
            title: const Text('Set Locale'),
            subtitle: const Text('Sets locale to fr-FR'),
            onTap: () {
              Encatch.setLocale('fr-FR');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Locale set to fr-FR')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.public),
            title: const Text('Set Country'),
            subtitle: const Text('Sets country to FR'),
            onTap: () {
              Encatch.setCountry('FR');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Country set to FR')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: const Text('Set Theme: Dark'),
            onTap: () {
              Encatch.setTheme(EncatchTheme.dark);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Theme set to dark')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.brightness_7),
            title: const Text('Set Theme: Light'),
            onTap: () {
              Encatch.setTheme(EncatchTheme.light);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Theme set to light')),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.add_comment),
            title: const Text('Pre-fill Response'),
            subtitle:
                const Text('Adds a pre-filled answer before showing a form'),
            onTap: () {
              Encatch.addToResponse('question_id_here', 'pre-filled value');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Response added. Show a form to see it.')),
              );
            },
          ),
        ],
      ),
    );
  }
}
