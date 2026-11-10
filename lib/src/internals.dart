/// Internal seams used by the SDK's own tests.
///
/// This file is NOT exported from `encatch_flutter.dart`, so nothing here is
/// part of the public API. Host apps must not import it.
library;

import 'package:http/http.dart' as http;

import 'logger.dart';

/// HTTP client used for every request the SDK makes. Tests replace it with a
/// fake; production code never reassigns it.
http.Client sdkHttpClient = http.Client();

/// The current time in milliseconds since the epoch. Tests replace it so the
/// SDK follows fake time; production code never reassigns it.
int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

/// How long a request may take before it counts as a network failure.
const requestTimeout = Duration(seconds: 30);

/// The SDK's logger, set by `Encatch.init`. Internal files that are not part of
/// the `Encatch` class log through this.
EncatchLogger sdkLogger = const EncatchLogger(debugMode: false);

/// True while the session is stopped (`Encatch.stopSession()`), including a
/// stop saved by an earlier run of the app. Kept in step by `Encatch`; read by
/// `EncatchProvider`, which then skips its session start at launch.
bool sessionStopped = false;

/// How `EncatchNavigatorObserver` reports a screen once the SDK is
/// initialised. While the session is stopped the screen is remembered but not
/// sent. Null until `Encatch.init` has been called.
void Function(String screenName)? autoTrackScreen;

/// Returns the SDK to its pre-`init` state. Registered by `Encatch.init`, so it
/// is null until the SDK has been initialised once. Tests only.
Future<void> Function()? resetSdkForTest;
