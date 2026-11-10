/// Internal seams used by the SDK's own tests.
///
/// This file is NOT exported from `encatch_flutter.dart`, so nothing here is
/// part of the public API. Host apps must not import it.
library;

import 'package:http/http.dart' as http;

/// HTTP client used for every request the SDK makes. Tests replace it with a
/// fake; production code never reassigns it.
http.Client sdkHttpClient = http.Client();

/// Returns the SDK to its pre-`init` state. Registered by `Encatch.init`, so it
/// is null until the SDK has been initialised once. Tests only.
Future<void> Function()? resetSdkForTest;
