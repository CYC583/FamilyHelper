// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
// Pure rules for "is grandma's phone still reporting?" (spec FH-06).
//
// No I/O or clock reads. The caller passes the consent status, the server's
// last-report time and "now". The result never claims the phone is healthy
// when the inputs cannot show it, and it keeps these cases apart so the family
// is not misled: never shared, paused by grandma, revoked by grandma, waiting
// for the first report, reporting normally, and suspected offline.
//
// "Suspected offline" is a guess from silence. Samsung battery saving, a dead
// battery, no network and a stopped app all look the same from here, so the UI
// must say "suspected" and "last report at ...", never "phone is off".

enum HostLiveness {
  /// Grandma never turned sharing on.
  neverShared,

  /// Grandma paused sharing. Not an outage.
  paused,

  /// Grandma withdrew consent. Not an outage.
  revoked,

  /// Sharing was just enabled and nothing has arrived yet.
  awaitingFirstReport,

  /// A report arrived recently enough.
  fresh,

  /// Sharing is on but nothing valid has arrived for too long.
  suspectedOffline,

  /// Inputs cannot support any claim (unrecognised status, no timestamps).
  unknown,
}

class HostLivenessAssessment {
  final HostLiveness state;

  /// Last report that counts (not older than the current consent), if any.
  final DateTime? lastReportAt;

  /// The instant silence is measured from: [lastReportAt], or the moment
  /// consent was last given when nothing valid has arrived since.
  final DateTime? since;

  /// How long nothing valid has arrived, never negative.
  final Duration? silentFor;

  const HostLivenessAssessment(
    this.state, {
    this.lastReportAt,
    this.since,
    this.silentFor,
  });
}

const Duration defaultStaleAfter = Duration(hours: 3);
const Duration minimumStaleAfter = Duration(minutes: 30);

/// Assess liveness. [consentStatus] is the stored value: `enabled`, `paused`,
/// `revoked`, or null when no consent record exists.
///
/// A report older than [consentUpdatedAt] belongs to a previous consent and is
/// ignored. A report dated after [now] (clock difference between server and
/// phone) counts as "just now" rather than producing a negative duration.
///
/// Throws [ArgumentError] when [staleAfter] is below [minimumStaleAfter]; a
/// tiny value would raise false alarms on every normal reporting gap.
HostLivenessAssessment assessHostLiveness({
  required DateTime now,
  required String? consentStatus,
  DateTime? lastReportAt,
  DateTime? consentUpdatedAt,
  Duration staleAfter = defaultStaleAfter,
}) {
  if (staleAfter < minimumStaleAfter) {
    throw ArgumentError.value(
      staleAfter,
      'staleAfter',
      '離線判斷門檻不得少於 ${minimumStaleAfter.inMinutes} 分鐘',
    );
  }
  switch (consentStatus) {
    case null:
      return const HostLivenessAssessment(HostLiveness.neverShared);
    case 'paused':
      return const HostLivenessAssessment(HostLiveness.paused);
    case 'revoked':
      return const HostLivenessAssessment(HostLiveness.revoked);
    case 'enabled':
      break;
    default:
      return const HostLivenessAssessment(HostLiveness.unknown);
  }

  final validReport =
      lastReportAt != null &&
          (consentUpdatedAt == null || !lastReportAt.isBefore(consentUpdatedAt))
      ? lastReportAt
      : null;
  final since = validReport ?? consentUpdatedAt;
  if (since == null) {
    return const HostLivenessAssessment(HostLiveness.unknown);
  }
  var silent = now.difference(since);
  if (silent.isNegative) silent = Duration.zero;

  if (silent >= staleAfter) {
    return HostLivenessAssessment(
      HostLiveness.suspectedOffline,
      lastReportAt: validReport,
      since: since,
      silentFor: silent,
    );
  }
  return HostLivenessAssessment(
    validReport != null ? HostLiveness.fresh : HostLiveness.awaitingFirstReport,
    lastReportAt: validReport,
    since: since,
    silentFor: silent,
  );
}

enum OutageAction { none, open, resolve }

class OutageStep {
  final OutageAction action;

  /// Key of the outage that is open after this step, or null when none is.
  final String? key;

  const OutageStep(this.action, this.key);
}

/// Decide whether to open or resolve an outage event, so each outage notifies
/// the family once and recovery clears it once.
///
/// [openOutageKey] is the key of the currently open outage, or null. An
/// outage's key comes from when its silence began, so a later, separate outage
/// has a different key.
///
/// Pausing or revoking resolves an open outage (it is no longer a fault
/// signal). An `unknown` assessment neither opens nor resolves: it must not
/// invent an outage or hide a real one.
OutageStep nextOutageStep({
  required HostLivenessAssessment assessment,
  required String? openOutageKey,
}) {
  switch (assessment.state) {
    case HostLiveness.suspectedOffline:
      final instant = assessment.since ?? assessment.lastReportAt;
      final key = 'outage-${instant?.toUtc().millisecondsSinceEpoch ?? 0}';
      if (openOutageKey == key) return OutageStep(OutageAction.none, key);
      return OutageStep(OutageAction.open, key);
    case HostLiveness.unknown:
      return OutageStep(OutageAction.none, openOutageKey);
    case HostLiveness.neverShared:
    case HostLiveness.paused:
    case HostLiveness.revoked:
    case HostLiveness.awaitingFirstReport:
    case HostLiveness.fresh:
      return openOutageKey == null
          ? const OutageStep(OutageAction.none, null)
          : const OutageStep(OutageAction.resolve, null);
  }
}
