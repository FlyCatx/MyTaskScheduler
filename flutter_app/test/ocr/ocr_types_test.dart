import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';

void main() {
  group('error codes', () {
    test('wire values match the host protocol', () {
      expect(OcrErrorCode.encrypted.wire, 'encrypted');
      expect(OcrErrorCode.renderFailed.wire, 'render_failed');
      expect(OcrErrorCode.ocrFailed.wire, 'ocr_failed');
      expect(OcrErrorCode.noLanguage.wire, 'no_language');
      expect(OcrErrorCode.tooLarge.wire, 'too_large');
      expect(OcrErrorCode.pageOutOfRange.wire, 'page_out_of_range');
    });

    test('fromWire maps known codes and defaults to protocolError', () {
      expect(OcrErrorCodeInfo.fromWire('encrypted'), OcrErrorCode.encrypted);
      expect(OcrErrorCodeInfo.fromWire('TOO_LARGE'), OcrErrorCode.tooLarge);
      expect(OcrErrorCodeInfo.fromWire('something_new'), OcrErrorCode.protocolError);
      expect(OcrErrorCodeInfo.fromWire(''), OcrErrorCode.protocolError);
    });

    test('every code has a Chinese explanation', () {
      for (final code in OcrErrorCode.values) {
        expect(code.defaultMessage, isNotEmpty);
        expect(code.defaultMessage, matches(RegExp(r'[\u4e00-\u9fff]')));
      }
    });
  });

  group('page spec', () {
    test('parses single pages and ranges', () {
      expect(parseOcrPageSpec('1-3,5'), <int>[1, 2, 3, 5]);
      expect(parseOcrPageSpec('5, 1, 1, 2-2'), <int>[1, 2, 5]);
      expect(parseOcrPageSpec(''), isEmpty);
      expect(parseOcrPageSpec('7'), <int>[7]);
    });

    test('rejects malformed specs', () {
      expect(() => parseOcrPageSpec('0'), throwsFormatException);
      expect(() => parseOcrPageSpec('5-3'), throwsFormatException);
      expect(() => parseOcrPageSpec('a'), throwsFormatException);
      expect(() => parseOcrPageSpec('3-'), throwsFormatException);
    });

    test('formats back to a compact spec', () {
      expect(formatOcrPageSpec(<int>[5, 1, 2, 3]), '1-3,5');
      expect(formatOcrPageSpec(<int>[4]), '4');
      expect(formatOcrPageSpec(const <int>[]), '');
    });
  });

  group('OcrAvailability', () {
    const availability = OcrAvailability(
      available: true,
      languages: <OcrLanguage>[
        OcrLanguage(tag: 'en-US', displayName: 'English'),
        OcrLanguage(tag: 'zh-Hans-CN', displayName: '中文（简体）'),
        OcrLanguage(tag: 'fr-FR', displayName: 'Français', recognizer: false),
      ],
    );

    test('matches language aliases', () {
      expect(availability.supportsLanguage('zh-Hans-CN'), isTrue);
      expect(availability.supportsLanguage('zh-CN'), isTrue);
      expect(availability.supportsLanguage('en'), isTrue);
      expect(availability.supportsLanguage('fr-FR'), isTrue);
      expect(availability.supportsLanguage('de-DE'), isFalse);
      expect(availability.supportsLanguage(''), isFalse);
    });

    test('preferredTags puts the requested language first', () {
      expect(availability.preferredTags('zh-Hans-CN'), <String>['zh-Hans-CN', 'en-US']);
      expect(availability.preferredTags('de-DE'), <String>['en-US', 'zh-Hans-CN']);
      expect(availability.preferredTags(), <String>['en-US', 'zh-Hans-CN']);
    });

    test('unavailable factory carries the reason', () {
      final unavailable = OcrAvailability.unavailable('找不到组件');
      expect(unavailable.available, isFalse);
      expect(unavailable.problem, '找不到组件');
      expect(unavailable.languages, isEmpty);
    });
  });

  group('OcrLimits', () {
    const limits = OcrLimits.standard;

    test('clamps DPI into the supported range', () {
      expect(limits.clampDpi(150), 150);
      expect(limits.clampDpi(1), limits.minDpi);
      expect(limits.clampDpi(10000), limits.maxDpi);
      expect(limits.isValidDpi(150), isTrue);
      expect(limits.isValidDpi(10), isFalse);
    });

    test('clamps page lists to the document and the per-job limit', () {
      const info = OcrDocumentInfo(kind: 'pdf', pageCount: 4);
      expect(limits.clampPages(<int>[3, 1, 9, 2], info), <int>[1, 2, 3]);
      expect(
        limits.clampPages(<int>[for (var i = 1; i <= 400; i++) i],
            const OcrDocumentInfo(kind: 'pdf', pageCount: 400)),
        hasLength(limits.maxPagesPerJob),
      );
    });

    test('describe mentions the enforced limits', () {
      expect(limits.describe(), contains('DPI'));
      expect(limits.describe(), contains('页'));
    });
  });

  group('OcrCancellation', () {
    test('notifies listeners once and is idempotent', () {
      final cancellation = OcrCancellation();
      var calls = 0;
      cancellation.addListener(() => calls++);
      cancellation.cancel();
      cancellation.cancel();
      expect(calls, 1);
      expect(cancellation.isCancelled, isTrue);
    });

    test('a listener added after cancellation runs immediately', () {
      final cancellation = OcrCancellation()..cancel();
      var called = false;
      cancellation.addListener(() => called = true);
      expect(called, isTrue);
    });
  });

  group('OcrProgress', () {
    test('fraction is computed from completed+failed and clamped', () {
      const progress = OcrProgress(
        phase: OcrPhase.recognizing,
        currentPage: 2,
        totalPages: 4,
        completed: 1,
        failed: 1,
      );
      expect(progress.fraction, closeTo(0.5, 0.0001));
      expect(
        const OcrProgress(phase: OcrPhase.preparing).fraction,
        isNull,
      );
      expect(
        const OcrProgress(phase: OcrPhase.recognizing, totalPages: 2, completed: 5)
            .fraction,
        1.0,
      );
    });
  });

  group('source ref', () {
    test('round-trips through JSON', () {
      const ref = OcrSourceRef(
        documentSha256: 'abc',
        page: 3,
        width: 1240,
        height: 1754,
        dpi: 150,
        engine: 'Windows.Media.Ocr',
        engineVersion: 'v1',
        language: 'zh-Hans-CN',
        method: OcrMethod.ocr,
        bbox: OcrRect(1, 2, 3, 4),
      );
      final decoded = OcrSourceRef.fromJson(ref.toJson());
      expect(decoded, isNotNull);
      expect(decoded!.page, 3);
      expect(decoded.bbox!.width, 3);
      expect(decoded.describe, contains('第 3 页'));
      expect(decoded.locationLabel, '第 3 页');
    });

    test('invalid JSON returns null instead of guessing', () {
      expect(OcrSourceRef.fromJson(null), isNull);
      expect(OcrSourceRef.fromJson(<String, Object?>{'page': 1}), isNull);
      expect(OcrSourceRef.fromJson(<String, Object?>{'documentSha256': 'x', 'page': 0}), isNull);
    });
  });

  group('OcrDocumentInfo', () {
    test('allPages is 1-based and complete', () {
      const info = OcrDocumentInfo(kind: 'pdf', pageCount: 3);
      expect(info.allPages, <int>[1, 2, 3]);
    });
  });
}
