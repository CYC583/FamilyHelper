// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
// Picks the "today's sentence" shown on the morning card.
//
// Pure and deterministic: no network, no AI, no clock read. The caller passes
// the local date (the Taipei calendar date) and persists which family quotes
// were already shown. Same date + seed + library always yields the same
// sentence, so a reinstalled phone or a second device shows the same card.

/// Longest sentence that fits the large-type card and a single spoken line.
const int maxQuoteLength = 40;

enum DailyQuoteSource { library, family }

class DailyQuote {
  final String id;
  final String text;
  final DailyQuoteSource source;

  /// Only set for family quotes, so the card can say who wrote it.
  final String? author;

  const DailyQuote({
    required this.id,
    required this.text,
    required this.source,
    this.author,
  });
}

/// A sentence written by a family member. It is shown once, ahead of the
/// built-in library, then the caller drops it from [pickDailyQuote]'s
/// `pendingFamily` list.
class FamilyQuote {
  final String id;
  final String text;
  final String author;
  final DateTime createdAt;
  final bool enabled;

  const FamilyQuote({
    required this.id,
    required this.text,
    required this.author,
    required this.createdAt,
    this.enabled = true,
  });

  bool get usable {
    final t = text.trim();
    return enabled && t.isNotEmpty && t.length <= maxQuoteLength;
  }
}

/// Choose today's sentence.
///
/// * An unshown, usable family quote wins; the oldest goes first.
/// * Otherwise the library is walked in a seed-shuffled order, one full pass
///   per cycle of [library].length days. Within a pass nothing repeats, and
///   the last sentence of one pass never equals the first of the next, so two
///   consecutive days never show the same sentence. A sentence late in one
///   pass can still reappear sooner than [library].length days later in the
///   next pass; only back-to-back repeats are ruled out.
///
/// Throws [ArgumentError] on an empty library rather than inventing text.
DailyQuote pickDailyQuote({
  required DateTime date,
  required String seed,
  required List<String> library,
  List<FamilyQuote> pendingFamily = const [],
}) {
  final family = pendingFamily.where((q) => q.usable).toList()
    ..sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  if (family.isNotEmpty) {
    final q = family.first;
    return DailyQuote(
      id: q.id,
      text: q.text.trim(),
      source: DailyQuoteSource.family,
      author: q.author,
    );
  }

  if (library.isEmpty) {
    throw ArgumentError.value(library, 'library', '句庫不可為空');
  }
  final n = library.length;
  final day = _dayNumber(date);
  final cycle = day ~/ n;
  final position = day % n;
  final index = _cycleOrder(n, seed, cycle)[position];
  return DailyQuote(
    id: 'lib-$index',
    text: library[index],
    source: DailyQuoteSource.library,
  );
}

/// Whole days since 1970-01-01 for the calendar date only, so time of day and
/// the device time zone cannot change the answer.
int _dayNumber(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

List<int> _cycleOrder(int n, String seed, int cycle) {
  if (n == 1) return const [0];
  if (n == 2) {
    // Alternate so two sentences never repeat back to back.
    final start = _hash('$seed#start') & 1;
    return [start, 1 - start];
  }
  final order = _shuffled(n, seed, cycle);
  if (cycle > 0) {
    final previousLast = _shuffled(n, seed, cycle - 1).last;
    if (order.first == previousLast) {
      final first = order[0];
      order[0] = order[1];
      order[1] = first;
    }
  }
  return order;
}

List<int> _shuffled(int n, String seed, int cycle) {
  final order = List<int>.generate(n, (i) => i);
  var state = _hash('$seed#$cycle');
  if (state == 0) state = 0x9E3779B9;
  int next() {
    // xorshift32: small, fixed algorithm, identical on every platform.
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= state >> 17;
    state ^= (state << 5) & 0xFFFFFFFF;
    return state;
  }

  for (var i = n - 1; i > 0; i--) {
    final j = next() % (i + 1);
    final tmp = order[i];
    order[i] = order[j];
    order[j] = tmp;
  }
  return order;
}

/// FNV-1a, 32-bit.
int _hash(String input) {
  var h = 0x811C9DC5;
  for (final unit in input.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}
