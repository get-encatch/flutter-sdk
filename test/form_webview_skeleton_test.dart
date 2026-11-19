import 'package:encatch_flutter/src/form_webview_skeleton.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FormWebViewSkeleton', () {
    for (final height in <double>[0, 1, 10, 24, 60, 100, 180, 300]) {
      testWidgets('renders without overflow at ${height}px height', (
        tester,
      ) async {
        // No Material ancestor: the SDK must not need one.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                height: height,
                child: const FormWebViewSkeleton(
                  backgroundColor: Color(0xFFFFFFFF),
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
