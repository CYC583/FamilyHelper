// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/common/host_liveness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 2, 12);
  DateTime ago(Duration d) => now.subtract(d);

  group('assessHostLiveness', () {
    test('從未開啟分享：不是離線，是「尚未分享」', () {
      final a = assessHostLiveness(now: now, consentStatus: null);
      expect(a.state, HostLiveness.neverShared);
    });

    test('長輩暫停或撤銷：分開顯示，不當成離線', () {
      expect(
        assessHostLiveness(now: now, consentStatus: 'paused').state,
        HostLiveness.paused,
      );
      expect(
        assessHostLiveness(now: now, consentStatus: 'revoked').state,
        HostLiveness.revoked,
      );
    });

    test('暫停或撤銷時，過期的回報時間不能讓它變成疑似離線', () {
      final a = assessHostLiveness(
        now: now,
        consentStatus: 'paused',
        lastReportAt: ago(const Duration(days: 3)),
      );
      expect(a.state, HostLiveness.paused);
    });

    test('已同意且最近有回報：正常', () {
      final a = assessHostLiveness(
        now: now,
        consentStatus: 'enabled',
        lastReportAt: ago(const Duration(minutes: 20)),
      );
      expect(a.state, HostLiveness.fresh);
      expect(a.silentFor, const Duration(minutes: 20));
    });

    test('剛好滿 3 小時沒回報才算疑似離線（未滿不算）', () {
      expect(
        assessHostLiveness(
          now: now,
          consentStatus: 'enabled',
          lastReportAt: ago(const Duration(hours: 2, minutes: 59)),
        ).state,
        HostLiveness.fresh,
      );
      final a = assessHostLiveness(
        now: now,
        consentStatus: 'enabled',
        lastReportAt: ago(const Duration(hours: 3)),
      );
      expect(a.state, HostLiveness.suspectedOffline);
      expect(a.silentFor, const Duration(hours: 3));
    });

    test('門檻可調，但不得低於下限', () {
      final a = assessHostLiveness(
        now: now,
        consentStatus: 'enabled',
        lastReportAt: ago(const Duration(minutes: 90)),
        staleAfter: const Duration(hours: 1),
      );
      expect(a.state, HostLiveness.suspectedOffline);
      expect(
        () => assessHostLiveness(
          now: now,
          consentStatus: 'enabled',
          staleAfter: const Duration(minutes: 5),
        ),
        throwsArgumentError,
      );
    });

    test('剛同意、還沒收到第一筆：先顯示等待，超過門檻才疑似離線', () {
      final enabledAt = ago(const Duration(minutes: 10));
      expect(
        assessHostLiveness(
          now: now,
          consentStatus: 'enabled',
          consentUpdatedAt: enabledAt,
        ).state,
        HostLiveness.awaitingFirstReport,
      );
      expect(
        assessHostLiveness(
          now: now,
          consentStatus: 'enabled',
          consentUpdatedAt: ago(const Duration(hours: 4)),
        ).state,
        HostLiveness.suspectedOffline,
      );
    });

    test('已同意但完全沒有任何時間資料：不宣稱正常，標示無法判定', () {
      final a = assessHostLiveness(now: now, consentStatus: 'enabled');
      expect(a.state, HostLiveness.unknown);
    });

    test('無法辨識的同意狀態：無法判定，不假裝正常', () {
      final a = assessHostLiveness(
        now: now,
        consentStatus: 'something-new',
        lastReportAt: ago(const Duration(minutes: 1)),
      );
      expect(a.state, HostLiveness.unknown);
    });

    test('回報時間比現在還晚（兩邊時鐘差）：視為剛回報，不出現負的靜默時間', () {
      final a = assessHostLiveness(
        now: now,
        consentStatus: 'enabled',
        lastReportAt: now.add(const Duration(minutes: 3)),
      );
      expect(a.state, HostLiveness.fresh);
      expect(a.silentFor, Duration.zero);
    });

    test('回報時間在最近一次同意之前：那是舊同意的資料，不採信', () {
      final a = assessHostLiveness(
        now: now,
        consentStatus: 'enabled',
        lastReportAt: ago(const Duration(minutes: 5)),
        consentUpdatedAt: ago(const Duration(minutes: 1)),
      );
      expect(a.state, HostLiveness.awaitingFirstReport);
    });
  });

  group('nextOutageStep：每次斷線只通知一次，恢復只解除一次', () {
    HostLivenessAssessment offline(DateTime lastReport) =>
        HostLivenessAssessment(
          HostLiveness.suspectedOffline,
          lastReportAt: lastReport,
          silentFor: const Duration(hours: 4),
        );
    const fresh = HostLivenessAssessment(HostLiveness.fresh);

    test('第一次疑似離線：開啟事件並通知', () {
      final step = nextOutageStep(
        assessment: offline(DateTime.utc(2026, 10, 2, 8)),
        openOutageKey: null,
      );
      expect(step.action, OutageAction.open);
      expect(step.key, isNotNull);
    });

    test('同一次斷線持續中：不重複通知', () {
      final a = offline(DateTime.utc(2026, 10, 2, 8));
      final first = nextOutageStep(assessment: a, openOutageKey: null);
      final again = nextOutageStep(assessment: a, openOutageKey: first.key);
      expect(again.action, OutageAction.none);
      expect(again.key, first.key);
    });

    test('恢復上線：解除一次，之後不再重複解除', () {
      final open = nextOutageStep(
        assessment: offline(DateTime.utc(2026, 10, 2, 8)),
        openOutageKey: null,
      );
      final resolved = nextOutageStep(
        assessment: fresh,
        openOutageKey: open.key,
      );
      expect(resolved.action, OutageAction.resolve);
      expect(resolved.key, isNull);
      final after = nextOutageStep(assessment: fresh, openOutageKey: null);
      expect(after.action, OutageAction.none);
    });

    test('恢復後再次斷線，是新的事件', () {
      final first = nextOutageStep(
        assessment: offline(DateTime.utc(2026, 10, 2, 8)),
        openOutageKey: null,
      );
      final second = nextOutageStep(
        assessment: offline(DateTime.utc(2026, 10, 3, 8)),
        openOutageKey: null,
      );
      expect(second.action, OutageAction.open);
      expect(second.key, isNot(first.key));
    });

    test('長輩暫停或撤銷時，解除未結的離線事件，不留著誤導家人', () {
      final open = nextOutageStep(
        assessment: offline(DateTime.utc(2026, 10, 2, 8)),
        openOutageKey: null,
      );
      for (final state in [HostLiveness.paused, HostLiveness.revoked]) {
        final step = nextOutageStep(
          assessment: HostLivenessAssessment(state),
          openOutageKey: open.key,
        );
        expect(step.action, OutageAction.resolve, reason: '$state');
      }
    });

    test('無法判定時不開新事件，也不擅自解除舊事件', () {
      final open = nextOutageStep(
        assessment: offline(DateTime.utc(2026, 10, 2, 8)),
        openOutageKey: null,
      );
      final step = nextOutageStep(
        assessment: const HostLivenessAssessment(HostLiveness.unknown),
        openOutageKey: open.key,
      );
      expect(step.action, OutageAction.none);
      expect(step.key, open.key);
    });
  });
}
