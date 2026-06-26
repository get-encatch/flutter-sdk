import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ============================================================================
  // Types tests
  // ============================================================================

  group('EncatchConfig', () {
    test('defaults are correct', () {
      const config = EncatchConfig();
      expect(config.apiBaseUrl, isNull);
      expect(config.webHost, isNull);
      expect(config.theme, isNull);
      expect(config.isFullScreen, isNull);
      expect(config.debugMode, isNull);
      expect(config.appVersion, isNull);
    });

    test('SDK defaults use production API and form hosts', () {
      expect(Encatch.baseUrl, 'https://api.encatch.com');
      expect(Encatch.webHost, 'https://form.encatch.com');
    });

    test('values are set correctly', () {
      const config = EncatchConfig(
        apiBaseUrl: 'https://custom.encatch.com',
        webHost: 'https://forms.custom.encatch.com',
        theme: EncatchTheme.dark,
        debugMode: true,
        isFullScreen: false,
        appVersion: '2.0.0',
      );
      expect(config.apiBaseUrl, 'https://custom.encatch.com');
      expect(config.webHost, 'https://forms.custom.encatch.com');
      expect(config.theme, EncatchTheme.dark);
      expect(config.debugMode, true);
      expect(config.isFullScreen, false);
      expect(config.appVersion, '2.0.0');
    });
  });

  group('UserTraits', () {
    test('toJson includes only non-null fields', () {
      const traits = UserTraits(
        set: {'name': 'Alice'},
        increment: {'loginCount': 1},
      );
      final json = traits.toJson();
      expect(json[r'$set'], {'name': 'Alice'});
      expect(json[r'$increment'], {'loginCount': 1});
      expect(json.containsKey(r'$setOnce'), isFalse);
      expect(json.containsKey(r'$decrement'), isFalse);
      expect(json.containsKey(r'$unset'), isFalse);
    });

    test('toJson with all fields', () {
      const traits = UserTraits(
        set: {'plan': 'pro'},
        setOnce: {'firstSeen': '2024-01-01'},
        increment: {'pageViews': 1},
        decrement: {'credits': 1},
        unset: ['tempField'],
      );
      final json = traits.toJson();
      expect(json[r'$set'], {'plan': 'pro'});
      expect(json[r'$setOnce'], {'firstSeen': '2024-01-01'});
      expect(json[r'$increment'], {'pageViews': 1});
      expect(json[r'$decrement'], {'credits': 1});
      expect(json[r'$unset'], ['tempField']);
    });
  });

  group('ApiDeviceInfo', () {
    test('toJson includes only non-null fields', () {
      const info = ApiDeviceInfo(
        deviceOs: 'android',
        deviceType: 'native',
        sdkVersion: '1.0.0',
        appVersion: '2.0.0',
      );
      final json = info.toJson();
      expect(json[r'$deviceOs'], 'android');
      expect(json[r'$deviceType'], 'native');
      expect(json[r'$sdkVersion'], '1.0.0');
      expect(json[r'$appVersion'], '2.0.0');
      expect(json.containsKey(r'$deviceSize'), isFalse);
      expect(json.containsKey(r'$countryCode'), isFalse);
    });

    test('toJson with all fields', () {
      const info = ApiDeviceInfo(
        deviceOs: 'ios',
        deviceVersion: '17.0',
        deviceOsVersion: '17.0',
        deviceType: 'native',
        sdkVersion: '1.0.0',
        appVersion: '3.0.0',
        app: 'com.example.app',
        deviceLanguage: 'en-US',
        userLanguage: 'fr-FR',
        countryCode: 'FR',
        preferredTheme: 'dark',
        timezone: 'Europe/Paris',
        urlOrScreenName: 'HomeScreen',
      );
      final json = info.toJson();
      expect(json[r'$deviceOs'], 'ios');
      expect(json[r'$deviceVersion'], '17.0');
      expect(json[r'$app'], 'com.example.app');
      expect(json[r'$userLanguage'], 'fr-FR');
      expect(json[r'$countryCode'], 'FR');
      expect(json[r'$timezone'], 'Europe/Paris');
      expect(json[r'$urlOrScreenName'], 'HomeScreen');
    });
  });

  group('Preferences', () {
    test('fromJson / toJson roundtrip', () {
      const prefs = Preferences(locale: 'en-US', country: 'US');
      final json = prefs.toJson();
      final restored = Preferences.fromJson(json);
      expect(restored.locale, 'en-US');
      expect(restored.country, 'US');
    });

    test('fromJson with missing fields returns null', () {
      final prefs = Preferences.fromJson({});
      expect(prefs.locale, isNull);
      expect(prefs.country, isNull);
    });
  });

  // ============================================================================
  // Form helpers tests
  // ============================================================================

  group('buildSubmitRequest', () {
    test('builds request from rating response', () {
      final req = buildSubmitRequest(
        options: const BuildSubmitRequestOptions(
          formConfigurationId: 'form-config-123',
          triggerType: TriggerType.manual,
        ),
        responses: [
          const NativeFormResponse(questionId: 'q1', type: 'rating', value: 5),
        ],
      );

      expect(req.triggerType, TriggerType.manual);
      expect(req.formDetails.formConfigurationId, 'form-config-123');
      final questions = req.formDetails.response?['questions'] as List<dynamic>;
      expect(questions.length, 1);
      expect(questions[0]['questionId'], 'q1');
      expect(questions[0]['answer']['rating'], 5);
    });

    test('builds request from nps response', () {
      final req = buildSubmitRequest(
        options: const BuildSubmitRequestOptions(formConfigurationId: 'cfg'),
        responses: [
          const NativeFormResponse(questionId: 'q_nps', type: 'nps', value: 9),
        ],
      );
      final questions = req.formDetails.response?['questions'] as List<dynamic>;
      expect(questions[0]['answer']['nps'], 9);
    });

    test('builds request from short_answer response', () {
      final req = buildSubmitRequest(
        options: const BuildSubmitRequestOptions(formConfigurationId: 'cfg'),
        responses: [
          const NativeFormResponse(
            questionId: 'q2',
            type: 'short_answer',
            value: 'Great product!',
          ),
        ],
      );
      final questions = req.formDetails.response?['questions'] as List<dynamic>;
      expect(questions[0]['answer']['shortAnswer'], 'Great product!');
    });

    test('builds request from multiple_choice response', () {
      final req = buildSubmitRequest(
        options: const BuildSubmitRequestOptions(formConfigurationId: 'cfg'),
        responses: [
          const NativeFormResponse(
            questionId: 'q3',
            type: 'multiple_choice',
            value: ['a', 'b', 'c'],
          ),
        ],
      );
      final questions = req.formDetails.response?['questions'] as List<dynamic>;
      expect(questions[0]['answer']['multipleChoiceMultiple'], ['a', 'b', 'c']);
    });

    test('builds request from long_text response', () {
      final req = buildSubmitRequest(
        options: const BuildSubmitRequestOptions(formConfigurationId: 'cfg'),
        responses: [
          const NativeFormResponse(
            questionId: 'q4',
            type: 'long_text',
            value: 'Detailed feedback here.',
          ),
        ],
      );
      final questions = req.formDetails.response?['questions'] as List<dynamic>;
      expect(questions[0]['answer']['longText'], 'Detailed feedback here.');
    });

    test('handles multiple responses', () {
      final req = buildSubmitRequest(
        options: const BuildSubmitRequestOptions(
          formConfigurationId: 'cfg-456',
          responseLanguageCode: 'en',
          completionTimeInSeconds: 45,
          feedbackIdentifier: 'ident-abc',
        ),
        responses: [
          const NativeFormResponse(
            questionId: 'q1',
            type: 'rating',
            value: '4',
          ),
          const NativeFormResponse(
            questionId: 'q2',
            type: 'short_answer',
            value: 'Good',
          ),
          const NativeFormResponse(
            questionId: 'q3',
            type: 'single_choice',
            value: 'option_a',
          ),
        ],
      );

      expect(req.formDetails.responseLanguageCode, 'en');
      expect(req.formDetails.completionTimeInSeconds, 45);
      expect(req.formDetails.feedbackIdentifier, 'ident-abc');
      final questions = req.formDetails.response?['questions'] as List<dynamic>;
      expect(questions.length, 3);
      expect(questions[2]['answer']['singleChoice'], 'option_a');
    });

    test('defaults triggerType to manual', () {
      final req = buildSubmitRequest(
        options: const BuildSubmitRequestOptions(formConfigurationId: 'cfg'),
        responses: [],
      );
      expect(req.triggerType, TriggerType.manual);
    });
  });

  // ============================================================================
  // API request toJson tests
  // ============================================================================

  group('ShowFormRequest.toJson', () {
    test('includes required fields', () {
      const req = ShowFormRequest(formSlugOrId: 'my-form');
      final json = req.toJson();
      expect(json['formSlugOrId'], 'my-form');
    });

    test('includes optional fields when set', () {
      const req = ShowFormRequest(
        formSlugOrId: 'my-form',
        triggerType: TriggerType.automatic,
        language: 'fr',
      );
      final json = req.toJson();
      expect(json['triggerType'], 'automatic');
      expect(json['language'], 'fr');
    });
  });

  group('IdentifyUserResponse.fromJson', () {
    test('parses complete response', () {
      final res = IdentifyUserResponse.fromJson({
        'message': 'ok',
        'userId': 'user-123',
        'formConfigurationId': 'form-456',
        'pingAgainIn': 60,
        r'$feedbackTransactions': 'txn-data',
      });
      expect(res.message, 'ok');
      expect(res.userId, 'user-123');
      expect(res.formConfigurationId, 'form-456');
      expect(res.pingAgainIn, 60);
      expect(res.feedbackTransactions, 'txn-data');
    });

    test('handles missing optional fields', () {
      final res = IdentifyUserResponse.fromJson({'message': 'ok'});
      expect(res.userId, isNull);
      expect(res.formConfigurationId, isNull);
      expect(res.pingAgainIn, isNull);
    });
  });

  group('FormMessageTypeExt', () {
    test('fromString returns correct enum value', () {
      expect(
        FormMessageTypeExt.fromString('form:ready'),
        FormMessageType.formReady,
      );
      expect(
        FormMessageTypeExt.fromString('form:submit'),
        FormMessageType.formSubmit,
      );
      expect(
        FormMessageTypeExt.fromString('form:complete'),
        FormMessageType.formComplete,
      );
      expect(
        FormMessageTypeExt.fromString('form:close'),
        FormMessageType.formClose,
      );
      expect(
        FormMessageTypeExt.fromString('form:resize'),
        FormMessageType.formResize,
      );
      expect(
        FormMessageTypeExt.fromString('form:readyToDismiss'),
        FormMessageType.formReadyToDismiss,
      );
    });

    test('fromString returns null for unknown type', () {
      expect(FormMessageTypeExt.fromString('unknown:type'), isNull);
    });

    test('value returns correct string', () {
      expect(FormMessageType.formReady.value, 'form:ready');
      expect(FormMessageType.formSectionChange.value, 'form:section:change');
      expect(
        FormMessageType.formRefineTextRequest.value,
        'form:refineTextRequest',
      );
    });
  });

  group('SdkMessageTypeExt', () {
    test('value returns correct string for all types', () {
      expect(SdkMessageType.formConfig.value, 'sdk:formConfig');
      expect(SdkMessageType.theme.value, 'sdk:theme');
      expect(SdkMessageType.locale.value, 'sdk:locale');
      expect(SdkMessageType.resetData.value, 'sdk:resetData');
      expect(SdkMessageType.prefillResponses.value, 'sdk:prefillResponses');
      expect(SdkMessageType.refineTextResponse.value, 'sdk:refineTextResponse');
      expect(
        SdkMessageType.submitPartialBeforeDismiss.value,
        'sdk:submitPartialBeforeDismiss',
      );
    });
  });

  // ============================================================================
  // RefineTextResponse tests
  // ============================================================================

  group('RefineTextResponse', () {
    test('fromJson / toJson roundtrip', () {
      final res = RefineTextResponse.fromJson({
        'message': 'ok',
        'refinedText': 'Polished text here.',
        'status': 200,
      });
      expect(res.refinedText, 'Polished text here.');
      expect(res.status, 200);

      final json = res.toJson();
      expect(json['refinedText'], 'Polished text here.');
      expect(json['status'], 200);
    });
  });
}
