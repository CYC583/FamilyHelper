// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/common/daily_quote.dart';
import 'package:familyhelper/app/common/daily_quote_library.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> lib(int n) => List.generate(n, (i) => '第$i句平安');

void main() {
  test('內建句庫使用目前長輩首頁的呼叫名稱', () {
    expect(builtInQuotes.where((quote) => quote.contains('呼叫孫女')), isEmpty);
    expect(builtInQuotes.any((quote) => quote.contains('呼叫家人')), isTrue);
  });
  group('每日一句挑選', () {
    test('同一天、同一種子、同一句庫，結果固定', () {
      final a = pickDailyQuote(
        date: DateTime(2026, 10, 2),
        seed: 'host-1',
        library: lib(20),
      );
      final b = pickDailyQuote(
        date: DateTime(2026, 10, 2, 23, 59),
        seed: 'host-1',
        library: lib(20),
      );
      expect(a.text, b.text);
      expect(a.source, DailyQuoteSource.library);
    });

    test('每一輪（句庫長度天、從輪的起點算）內每句只出現一次', () {
      final library = lib(37);
      // Day number 37 * 20000 is a cycle boundary, so this window is one pass.
      final start = DateTime.utc(1970, 1, 1).add(Duration(days: 37 * 20000));
      final seen = <String>{};
      for (var i = 0; i < library.length; i++) {
        seen.add(
          pickDailyQuote(
            date: start.add(Duration(days: i)),
            seed: 'host-1',
            library: library,
          ).text,
        );
      }
      expect(seen.length, library.length);
    });

    test('輪與輪交界、以及整年中，不會連續兩天同一句', () {
      final library = lib(11);
      final start = DateTime(2026, 1, 1);
      String? previous;
      for (var i = 0; i < 365 * 2; i++) {
        final text = pickDailyQuote(
          date: start.add(Duration(days: i)),
          seed: 'host-2',
          library: library,
        ).text;
        expect(text, isNot(previous), reason: '第 $i 天重複');
        previous = text;
      }
    });

    test('不同種子的長輩順序不同', () {
      final library = lib(30);
      final day = DateTime(2026, 10, 2);
      final orders = {
        for (final seed in ['a', 'b', 'c', 'd'])
          seed: [
            for (var i = 0; i < 10; i++)
              pickDailyQuote(
                date: day.add(Duration(days: i)),
                seed: seed,
                library: library,
              ).text,
          ].join('|'),
      };
      expect(orders.values.toSet().length, greaterThan(1));
    });

    test('跨月、跨年與閏日仍連續不重複', () {
      final library = lib(5);
      String? previous;
      for (final d in [
        DateTime(2027, 12, 30),
        DateTime(2027, 12, 31),
        DateTime(2028, 1, 1),
        DateTime(2028, 2, 28),
        DateTime(2028, 2, 29),
        DateTime(2028, 3, 1),
      ]) {
        final text = pickDailyQuote(date: d, seed: 'x', library: library).text;
        expect(text, isNot(previous));
        previous = text;
      }
    });

    test('只有一句時不會當掉', () {
      final q = pickDailyQuote(
        date: DateTime(2026, 10, 2),
        seed: 's',
        library: ['只有一句'],
      );
      expect(q.text, '只有一句');
    });

    test('句庫是空的就明確拒絕，不回傳假內容', () {
      expect(
        () => pickDailyQuote(
          date: DateTime(2026, 10, 2),
          seed: 's',
          library: const [],
        ),
        throwsArgumentError,
      );
    });
  });

  group('家人新增的句子', () {
    test('尚未顯示的家人句子優先，並標示來源與作者', () {
      final q = pickDailyQuote(
        date: DateTime(2026, 10, 2),
        seed: 's',
        library: lib(10),
        pendingFamily: [
          FamilyQuote(
            id: 'q2',
            text: '阿嬤，今天也要記得喝水喔',
            author: '孫女',
            createdAt: DateTime(2026, 10, 2, 9),
          ),
          FamilyQuote(
            id: 'q1',
            text: '我們都很想你',
            author: '孫子',
            createdAt: DateTime(2026, 10, 1, 9),
          ),
        ],
      );
      expect(q.source, DailyQuoteSource.family);
      expect(q.id, 'q1'); // oldest first
      expect(q.text, '我們都很想你');
      expect(q.author, '孫子');
    });

    test('已停用或空白的家人句子不會被挑到', () {
      final q = pickDailyQuote(
        date: DateTime(2026, 10, 2),
        seed: 's',
        library: lib(10),
        pendingFamily: [
          FamilyQuote(
            id: 'off',
            text: '停用的句子',
            author: '孫女',
            createdAt: DateTime(2026, 10, 1),
            enabled: false,
          ),
          FamilyQuote(
            id: 'blank',
            text: '   ',
            author: '孫女',
            createdAt: DateTime(2026, 10, 1),
          ),
        ],
      );
      expect(q.source, DailyQuoteSource.library);
    });

    test('家人句子過長時不挑，避免大字卡爆版', () {
      final q = pickDailyQuote(
        date: DateTime(2026, 10, 2),
        seed: 's',
        library: lib(10),
        pendingFamily: [
          FamilyQuote(
            id: 'long',
            text: '長' * (maxQuoteLength + 1),
            author: '孫女',
            createdAt: DateTime(2026, 10, 1),
          ),
        ],
      );
      expect(q.source, DailyQuoteSource.library);
    });

    test('輸入的清單不會被修改', () {
      final pending = [
        FamilyQuote(
          id: 'a',
          text: '早安',
          author: '孫女',
          createdAt: DateTime(2026, 10, 1),
        ),
      ];
      final library = lib(5);
      pickDailyQuote(
        date: DateTime(2026, 10, 2),
        seed: 's',
        library: library,
        pendingFamily: pending,
      );
      expect(pending.length, 1);
      expect(library, lib(5));
    });
  });

  group('內建句庫品質', () {
    test('句庫通過驗證：沒有重複、空白或過長', () {
      expect(validateQuoteLibrary(builtInQuotes), isEmpty);
    });

    test('句庫數量至少夠一個月不重複', () {
      expect(builtInQuotes.length, greaterThanOrEqualTo(60));
    });

    test('驗證器能抓到重複、空白、過長與禁用內容', () {
      final problems = validateQuoteLibrary([
        '今天天氣很好',
        '今天天氣很好',
        '   ',
        '長' * (maxQuoteLength + 1),
        '你一定要吃藥',
        '保證不會生病',
        '你已經老了',
      ]);
      expect(problems.length, greaterThanOrEqualTo(6));
    });

    test('句庫不含醫療承諾、指示或貶低長輩的字眼', () {
      for (final q in builtInQuotes) {
        for (final banned in bannedQuotePhrases) {
          expect(q.contains(banned), isFalse, reason: '「$q」含「$banned」');
        }
      }
    });
  });
}
