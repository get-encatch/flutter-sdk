import 'package:encatch_flutter/src/form_webview_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FormWebViewSkeleton', () {
    for (final height in <double>[0, 1, 10, 24, 60, 100, 180, 300]) {
      testWidgets('renders without overflow at ${height}px height', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                height: height,
                child: const FormWebViewSkeleton(
                  backgroundColor: Colors.white,
                  activeMode: Brightness.light,
                ),
              ),
            ),
          ),
        );

        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
