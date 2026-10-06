// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'daily_quote.dart';

/// Phrases that must never appear in the built-in library: medical promises or
/// instructions, orders, and words that diminish an older person. The app is a
/// companion, not a clinician or a supervisor.
const List<String> bannedQuotePhrases = [
  '保證',
  '治好',
  '痊癒',
  '不會生病',
  '一定要',
  '必須',
  '不准',
  '不可以',
  '老了',
  '老人家',
  '沒用',
];

/// Problems found in a quote list; empty means the list is acceptable.
List<String> validateQuoteLibrary(List<String> quotes) {
  final problems = <String>[];
  final seen = <String>{};
  for (var i = 0; i < quotes.length; i++) {
    final q = quotes[i];
    final t = q.trim();
    if (t.isEmpty) {
      problems.add('第 ${i + 1} 句是空白');
      continue;
    }
    if (t.length > maxQuoteLength) {
      problems.add('第 ${i + 1} 句超過 $maxQuoteLength 字：$t');
    }
    if (!seen.add(t)) problems.add('第 ${i + 1} 句重複：$t');
    for (final banned in bannedQuotePhrases) {
      if (t.contains(banned)) {
        problems.add('第 ${i + 1} 句含不適合的字眼「$banned」：$t');
      }
    }
  }
  return problems;
}

/// Built-in sentences for the morning card. They are neutral about weather,
/// season and time of day (the weather line and the good-night card cover
/// those), make no promise the family cannot keep, and never give orders.
/// Target is about 400; this is the first reviewed batch.
const List<String> builtInQuotes = [
  '今天也是平平安安的一天',
  '早安，願你今天心情舒服',
  '慢慢開始這一天，不用趕',
  '喝一口溫水，今天輕輕鬆鬆',
  '家人都在你身邊，只是隔著一點距離',
  '慢慢來，今天沒有誰在催你',
  '看看窗外，說不定有小鳥來問早',
  '今天的你，已經很棒了',
  '好好吃一餐，讓身體暖暖的',
  '有空走到窗邊，伸伸懶腰吧',
  '笑一笑，今天會更好',
  '你煮的菜，是我們心裡最好吃的味道',
  '謝謝你一直為家人惦記著',
  '累了就坐下來歇一歇，沒有關係',
  '今天看到的美好，歡迎拍下來給我們看',
  '小小的日子，也值得好好過',
  '肩膀放鬆，深呼吸，慢慢吐氣',
  '你笑起來，我們都放心了',
  '家裡有你，才像家',
  '今天也想聽你說說話',
  '一杯熱茶，一段安靜的好時光',
  '不急，一件一件慢慢做',
  '你是我們最珍惜的人',
  '好心情，是今天送給自己的禮物',
  '讓眼睛休息一下，看看遠方的綠',
  '孩子們都記得你的好',
  '有點想你，所以說聲早安',
  '慢慢走，我們陪你',
  '願你今天遇見小小的開心',
  '吃飯配點青菜，今天也顧好自己',
  '想起你做過的拿手菜，嘴角就上揚',
  '不管多遠，我們的心和你在一起',
  '你願意慢慢來，我們願意慢慢等',
  '今天有沒有曬到一點太陽呢',
  '你說的故事，我們都好愛聽',
  '沏壺茶，今天不用太忙',
  '好好照顧自己，就是最大的幫忙',
  '家人傳來的問候，請你收下',
  '今天也有人惦記著你',
  '慢慢喝完這杯水，讓身體舒服一些',
  '不管晴天雨天，都有好心情的方法',
  '你的平安，是我們最大的心願',
  '抬頭看看天空，雲慢慢走過',
  '想起你種的那些花，就覺得很溫暖',
  '今天想吃點什麼好吃的呢',
  '輕輕哼一首你愛的歌吧',
  '你今天的樣子，我們都喜歡',
  '別擔心我們，我們都過得很好',
  '打個電話給老朋友，聊聊也很好',
  '小小的散步，心情也跟著輕快',
  '午後打個盹也很好，不用不好意思',
  '每一天都是新的，慢慢享受',
  '你在，我們就安心',
  '有需要就按「呼叫家人」，我們都在',
  '想說的話，今天都可以說給我們聽',
  '今天的飯菜，希望合你的胃口',
  '你辛苦了，今天讓自己舒服一點',
  '早起的鳥兒有蟲吃，慢起的你有我們愛',
  '你是家裡最安定的力量',
  '世界很大，但你的家人都在這裡',
  '慢慢呼吸，慢慢微笑',
  '有你在，過節才有味道',
  '你種的菜、你煮的湯，都是我們的回憶',
  '謝謝你把我們養大',
  '今天也請你多笑幾次',
  '好久沒聽你講以前的事了，改天說給我們聽',
  '一起看夕陽，雖然隔著螢幕',
  '願今天的每一步都走得穩穩的',
  '慢慢走路，看看路邊的小花',
  '今天讓我們說聲：我愛你',
  '你一天的心情，我們都想知道',
  '看電視看久了，起來走走吧',
  '想你的時候，我們就看看你的照片',
  '生活很簡單，有你就很好',
  '打開窗戶，讓新鮮的空氣進來',
  '你總是先想到我們，今天換我們想你',
  '記得吃早餐，我們才放心',
  '雲慢慢飄，心情也可以慢慢來',
  '家裡的燈，永遠為你亮著',
  '把煩惱放一邊，今天只想開心的事',
  '你的笑聲，是我們最愛的聲音',
  '我們很幸福，因為有你',
  '今天的茶，要不要配點小點心',
  '深呼吸，今天一切都剛剛好',
  '有人在遠方，天天為你加油',
  '謝謝你，今天也好好的',
  '傍晚想出門走走的話，慢慢來就好',
  '你一個人的時候，我們也在想你',
  '今天不用做很多事，開心就夠了',
  '你的存在，就是家人最大的安慰',
  '今天也請你好好愛自己',
];
