// Step 12b (Q&A with AI streaming). Fails on 1.1.2 until the fix lands.
@Tags(['pending-fix'])
library;

import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  group('step 12b: Q&A with AI', () {
    tearDown(stopSdk);

    test('the answer arrives piece by piece', () async {
      final api = FakeApi();
      await startSdk(api);
      final pieces = <String>[];
      final result = await Encatch.streamQnaWithAi(
        const QnaWithAiRequest(
          feedbackConfigurationId: defaultFormId,
          questionId: 'q1',
          conversation: [
            QnaWithAiConversationTurn(question: 'Why?', answer: ''),
          ],
        ),
        onChunk: pieces.add,
      );
      const answer = 'This answer was streamed by the fake.';
      expect(result.answer, answer);
      expect(pieces.length, greaterThan(1), reason: 'one call per piece');
      expect(pieces.join(), answer);
    });
  });
}
