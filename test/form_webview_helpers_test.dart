import 'package:encatch_flutter/src/form_webview_helpers.dart';
import 'package:encatch_flutter/src/types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildFormWebViewUrl', () {
    const host = 'https://encatch.io';

    test('includes formId and ts params', () {
      final url = buildFormWebViewUrl(
        webHost: host,
        formId: 'my-form',
        instanceKey: 1,
        debugMode: false,
      );
      expect(url, contains('formId=my-form'));
      expect(url, contains('ts=1'));
    });

    test('increments ts for cache busting', () {
      final url0 = buildFormWebViewUrl(
        webHost: host,
        formId: 'f',
        instanceKey: 0,
        debugMode: false,
      );
      final url1 = buildFormWebViewUrl(
        webHost: host,
        formId: 'f',
        instanceKey: 1,
        debugMode: false,
      );
      expect(url0, contains('ts=0'));
      expect(url1, contains('ts=1'));
      expect(url0, isNot(equals(url1)));
    });

    test('does NOT include debug param when debugMode is false', () {
      final url = buildFormWebViewUrl(
        webHost: host,
        formId: 'f',
        instanceKey: 0,
        debugMode: false,
      );
      expect(url, isNot(contains('debug')));
    });

    test('includes debug=true when debugMode is true', () {
      final url = buildFormWebViewUrl(
        webHost: host,
        formId: 'f',
        instanceKey: 0,
        debugMode: true,
      );
      expect(url, contains('debug=true'));
    });

    test('does NOT include presentation param for modal', () {
      final url = buildFormWebViewUrl(
        webHost: host,
        formId: 'f',
        instanceKey: 0,
        debugMode: false,
        presentation: FormPresentation.modal,
      );
      expect(url, isNot(contains('presentation')));
    });

    test('includes presentation=inline for inline presentation', () {
      final url = buildFormWebViewUrl(
        webHost: host,
        formId: 'f',
        instanceKey: 0,
        debugMode: false,
        presentation: FormPresentation.inline,
      );
      expect(url, contains('presentation=inline'));
    });

    test('builds correct base path', () {
      final url = buildFormWebViewUrl(
        webHost: host,
        formId: 'f',
        instanceKey: 0,
        debugMode: false,
      );
      expect(url, startsWith('$host/s/flutter-sdk-form?'));
    });

    test('URL-encodes formId with special characters', () {
      final url = buildFormWebViewUrl(
        webHost: host,
        formId: 'form id&special=chars',
        instanceKey: 0,
        debugMode: false,
      );
      expect(url, isNot(contains('form id')));
      expect(url, isNot(contains('&special')));
      expect(url, contains('form%20id'));
    });
  });

  group('getBackgroundColor', () {
    test('prefers --background over --popover', () {
      final color = getBackgroundColor(
        '{"--background":"#112233","--popover":"#000000"}',
        Colors.white,
      );

      expect(color, const Color(0xFF112233));
    });

    test('falls back to --popover when --background is missing', () {
      final color = getBackgroundColor('{"--popover":"#445566"}', Colors.white);

      expect(color, const Color(0xFF445566));
    });

    test('parses rgb colors', () {
      final color = getBackgroundColor(
        '{"--background":"rgb(17, 34, 51)"}',
        Colors.white,
      );

      expect(color, const Color(0xFF112233));
    });

    test('parses rgba colors with decimal alpha', () {
      final color = getBackgroundColor(
        '{"--background":"rgba(255, 128, 0, 0.5)"}',
        Colors.white,
      );

      expect(color, const Color(0x80FF8000));
    });

    test('parses rgba colors with percent alpha', () {
      final color = getBackgroundColor(
        '{"--background":"rgba(255, 255, 255, 100%)"}',
        Colors.black,
      );

      expect(color, Colors.white);
    });

    test('uses fallback for invalid or empty theme JSON', () {
      expect(getBackgroundColor('{}', Colors.white), Colors.white);
      expect(getBackgroundColor('not-json', Colors.black), Colors.black);
    });

    test('uses fallback for unsupported oklch colors', () {
      final color = getBackgroundColor(
        '{"--background":"oklch(0.98 0.02 250)","--popover":"#445566"}',
        Colors.white,
      );

      expect(color, Colors.white);
    });
  });

  group('resolveActiveMode', () {
    test('returns light when shareableMode is light', () {
      expect(
        resolveActiveMode(
          shareableMode: 'light',
          systemBrightness: Brightness.dark,
        ),
        Brightness.light,
      );
    });

    test('returns dark when shareableMode is dark', () {
      expect(
        resolveActiveMode(
          shareableMode: 'dark',
          systemBrightness: Brightness.light,
        ),
        Brightness.dark,
      );
    });

    test('falls back to system brightness for system or unknown modes', () {
      expect(
        resolveActiveMode(
          shareableMode: 'system',
          systemBrightness: Brightness.dark,
        ),
        Brightness.dark,
      );
      expect(
        resolveActiveMode(
          shareableMode: null,
          systemBrightness: Brightness.light,
        ),
        Brightness.light,
      );
    });
  });

  group('resolveFormWebViewTheme', () {
    ShowFormPayload payload({
      EncatchTheme? theme,
      String? shareableMode,
      Map<String, dynamic>? themes,
    }) {
      return ShowFormPayload(
        formId: 'form',
        resetMode: ResetMode.always,
        triggerType: TriggerType.manual,
        formConfig: ShowFormResponse(
          feedbackConfigurationId: 'cfg',
          appearanceProperties: {
            'featureSettings': {
              if (shareableMode != null) 'shareableMode': shareableMode,
            },
            if (themes != null) 'themes': themes,
          },
        ),
        theme: theme,
      );
    }

    test('prefers payload theme over shareableMode', () {
      final theme = resolveFormWebViewTheme(
        payload(theme: EncatchTheme.dark, shareableMode: 'light'),
        systemBrightness: Brightness.light,
      );

      expect(theme.activeMode, Brightness.dark);
    });

    test('uses system brightness when theme and shareableMode are system', () {
      final theme = resolveFormWebViewTheme(
        payload(theme: EncatchTheme.system, shareableMode: 'system'),
        systemBrightness: Brightness.dark,
      );

      expect(theme.activeMode, Brightness.dark);
      expect(theme.backgroundColor, const Color(0xFF1a1a1a));
    });

    test('loads background from resolved active theme JSON', () {
      final theme = resolveFormWebViewTheme(
        payload(
          theme: EncatchTheme.light,
          themes: {
            'light': {'theme': '{"--background":"#112233"}'},
          },
        ),
        systemBrightness: Brightness.dark,
      );

      expect(theme.activeMode, Brightness.light);
      expect(theme.backgroundColor, const Color(0xFF112233));
    });
  });
}
