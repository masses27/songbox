/// 搜索框里的「模糊」：在把关键词递给接口之前先收拾一遍，收不出结果时
/// 再给出几个更宽的写法。
library;

/// 把一行输入收拾成适合发出去的样子。
///
/// 手机输入法会打出全角空格、全角字母数字和全角标点（「晴天　周杰倫」「ＡＢＣ」
/// 「晴天／周杰伦」），而 cloudsearch 是按整串去匹配的 —— 多一个看不见的空格就是
/// 另一个关键词，搜不到还被当成「这首歌真没有」。这些毛病不需要问服务器，本地就能修好。
///
/// 全角标点一律换成空格：实测「晴天／周杰伦」搜出来 207 条，而中间换成空格的
/// 「晴天 周杰伦」是 250 条 —— 那个斜杠在她手里就是分隔符，不是歌名的一部分。
String normalizeKeyword(String raw) {
  final b = StringBuffer();
  for (final r in raw.runes) {
    if (r >= 0xFF10 && r <= 0xFF19 || r >= 0xFF21 && r <= 0xFF3A || r >= 0xFF41 && r <= 0xFF5A) {
      // 全角 ASCII 里「就是字母和数字」的三小截，减 0xFEE0 得半角码位。
      b.writeCharCode(r - 0xFEE0);
    } else if (r == 0x200B) {
      // 零宽空格：看不见，但足以让整串变成另一个关键词。
      continue;
    } else if (r == 0x3000 || r == 0x3001 || _widePunct(r)) {
      b.write(' ');
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 全角 ASCII 区间里除了字母数字之外的四段标点（！？…（）…：；…［］…｛｝）。
bool _widePunct(int r) =>
    (r >= 0xFF01 && r <= 0xFF0F) ||
    (r >= 0xFF1A && r <= 0xFF20) ||
    (r >= 0xFF3B && r <= 0xFF40) ||
    (r >= 0xFF5B && r <= 0xFF5E);

/// 一个结果都没有时可以再问一遍的写法，按「最值得先试」排好。
///
/// 只做本地能确定有用的两件事：把词与词之间的空格去掉（「周杰 伦」多半是
/// 手滑），以及把长句拆成单个词（「周杰伦 晴天」搜不到时，任一半都还有得搜，
/// 到底哪半是歌名让服务器去判，两个都递出来）。
List<String> relaxations(String keyword) {
  final kw = normalizeKeyword(keyword);
  final out = <String>{};
  final flat = kw.replaceAll(RegExp(r'\s+'), '');
  if (flat.isNotEmpty && flat != kw) out.add(flat);
  // 剩下的按她打的顺序给：先写的那个词才是她心里的主关键词。
  out.addAll(kw.split(' ').where((t) => t.length >= 2));
  out.remove(kw);
  return out.take(4).toList();
}
