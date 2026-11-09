// 时区目录：任务 10 的“备注与时区”可搜索选单的数据源。
//
// 设计要点：
//   * 选项来自 `package:timezone` 自带的 IANA 数据库，**不是**只硬编码截图里的
//     几个城市；新增/更名的地区随 tzdb 自动出现；
//   * 展示用“中文城市 + 当前 UTC 偏移 + IANA 标识”，保存的永远是 IANA ID；
//   * 同一当前偏移但 DST 规则不同的地区（例如 Europe/London 与 Africa/Abidjan）
//     分别列出，并标出“有夏令时”，用户可以区分；
//   * 搜索只缩小选项（匹配中文名、IANA ID、UTC 偏移与常见别名），不接受任意文本
//     作为保存值；
//   * 旧数据里的 IANA ID 即使没有中文别名也保留可见选项：先按 ID 精确命中，
//     目录里没有时才进入“修复入口”。

import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 一个可保存的时区选项。
class ScheduleTimeZoneOption {
  const ScheduleTimeZoneOption({
    required this.id,
    required this.cityLabel,
    required this.offsetMinutes,
    required this.observesDst,
  });

  /// 保存到日程的 IANA 时区 ID，例如 `Asia/Shanghai`。
  final String id;

  /// 中文城市/地区展示名；没有中文别名时退化为 IANA 城市名。
  final String cityLabel;

  /// 参考时刻下的 UTC 偏移（分钟，东正西负）。
  final int offsetMinutes;

  /// 该地区在该年是否使用夏令时（1 月与 7 月偏移不同）。
  final bool observesDst;

  /// 形如 `(UTC+08:00)` 的偏移展示。
  String get offsetLabel => formatUtcOffset(offsetMinutes);

  /// 下拉项的完整主标题。
  String get displayLabel => '$offsetLabel $cityLabel';

  /// 搜索文本（小写）：城市/别名、IANA ID、偏移。
  String get searchText =>
      '${cityLabel.toLowerCase()} ${id.toLowerCase()} '
      '${offsetLabel.toLowerCase()} ${_aliasText(id)}';

  @override
  bool operator ==(Object other) =>
      other is ScheduleTimeZoneOption && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

String _aliasText(String id) {
  final aliases = _timeZoneAliases[id];
  return aliases == null ? '' : aliases.toLowerCase();
}

/// 把分钟偏移格式化成 `UTC+08:00` / `UTC-05:30` / `UTC+00:00`。
String formatUtcOffset(int minutes) {
  final sign = minutes < 0 ? '-' : '+';
  final abs = minutes.abs();
  final h = (abs ~/ 60).toString().padLeft(2, '0');
  final m = (abs % 60).toString().padLeft(2, '0');
  return 'UTC$sign$h:$m';
}

/// 时区目录：构建一次并缓存（数据库本身是全局的）。
class ScheduleTimeZoneCatalog {
  ScheduleTimeZoneCatalog._();

  static List<ScheduleTimeZoneOption>? _cache;
  static int? _cacheYear;
  static Map<String, ScheduleTimeZoneOption>? _byId;

  /// 该年目录（偏移随 DST 变化，按年缓存即可）。
  static List<ScheduleTimeZoneOption> options(DateTime at) {
    final year = at.year;
    if (_cache != null && _cacheYear == year) return _cache!;
    try {
      tzdata.initializeTimeZones();
    } catch (_) {
      // 数据库已初始化时重复调用无害；失败时仍返回空目录而不是崩溃。
    }
    final january = DateTime.utc(year, 1, 15, 12);
    final july = DateTime.utc(year, 7, 15, 12);
    final entries = <ScheduleTimeZoneOption>[];
    final byId = <String, ScheduleTimeZoneOption>{};
    for (final location in tz.timeZoneDatabase.locations.values) {
      final id = location.name;
      final offsetJan = _offsetAt(location, january);
      final offsetJul = _offsetAt(location, july);
      final offset = _offsetAt(location, at.toUtc());
      final option = ScheduleTimeZoneOption(
        id: id,
        cityLabel: _cityLabel(id),
        offsetMinutes: offset,
        observesDst: offsetJan != offsetJul,
      );
      entries.add(option);
      byId[id] = option;
    }
    entries.sort((a, b) {
      final byOffset = a.offsetMinutes.compareTo(b.offsetMinutes);
      if (byOffset != 0) return byOffset;
      final byCity = a.cityLabel.compareTo(b.cityLabel);
      if (byCity != 0) return byCity;
      return a.id.compareTo(b.id);
    });
    _cache = List<ScheduleTimeZoneOption>.unmodifiable(entries);
    _cacheYear = year;
    _byId = byId;
    return _cache!;
  }

  /// 精确按 IANA ID 查找；目录里没有返回 null（旧值需要修复入口）。
  static ScheduleTimeZoneOption? find(String? iana, DateTime at) {
    final id = iana?.trim() ?? '';
    if (id.isEmpty) return null;
    options(at);
    return _byId?[id];
  }

  /// 搜索：空查询返回全部；只缩小选项，不接受自由文本作为保存值。
  static List<ScheduleTimeZoneOption> search(String query, DateTime at) {
    final all = options(at);
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    final terms = q.split(RegExp(r'\s+'));
    return all.where((option) {
      for (final term in terms) {
        if (!option.searchText.contains(term)) return false;
      }
      return true;
    }).toList(growable: false);
  }

  /// 仅测试用：丢弃缓存（跨年/跨 DST 用例）。
  static void resetForTest() {
    _cache = null;
    _cacheYear = null;
    _byId = null;
  }

  static int _offsetAt(tz.Location location, DateTime utc) {
    try {
      return tz.TZDateTime.from(utc.toUtc(), location).timeZoneOffset.inMinutes;
    } catch (_) {
      return 0;
    }
  }
}

/// 中文城市/地区名。没有条目的地区退化为 IANA 城市名（英文），仍然可搜索、
/// 可保存——但绝不自造中文名或伪造 IANA ID。
const Map<String, String> _zhCityNames = <String, String>{
  'UTC': '协调世界时',
  'Etc/UTC': '协调世界时',
  'Etc/GMT': '格林尼治标准时间',
  'Etc/GMT+0': '格林尼治标准时间',
  'Etc/GMT-0': '格林尼治标准时间',
  'Etc/GMT+8': '固定 UTC-08:00',
  'Etc/GMT+9': '固定 UTC-09:00',
  'Etc/GMT-8': '固定 UTC+08:00',
  'Etc/GMT-9': '固定 UTC+09:00',
  'Asia/Shanghai': '北京，重庆，香港特别行政区，乌鲁木齐',
  'Asia/Chongqing': '重庆',
  'Asia/Harbin': '哈尔滨',
  'Asia/Kashgar': '喀什',
  'Asia/Urumqi': '乌鲁木齐',
  'Asia/Hong_Kong': '香港特别行政区',
  'Asia/Macau': '澳门特别行政区',
  'Asia/Taipei': '台北',
  'Asia/Tokyo': '东京',
  'Asia/Seoul': '首尔',
  'Asia/Pyongyang': '平壤',
  'Asia/Singapore': '新加坡',
  'Asia/Kuala_Lumpur': '吉隆坡',
  'Asia/Bangkok': '曼谷',
  'Asia/Ho_Chi_Minh': '河内，胡志明市',
  'Asia/Saigon': '胡志明市',
  'Asia/Phnom_Penh': '金边',
  'Asia/Vientiane': '万象',
  'Asia/Yangon': '仰光',
  'Asia/Rangoon': '仰光',
  'Asia/Dhaka': '达卡',
  'Asia/Kolkata': '加尔各答，新德里，孟买',
  'Asia/Calcutta': '加尔各答',
  'Asia/Karachi': '卡拉奇',
  'Asia/Kathmandu': '加德满都',
  'Asia/Katmandu': '加德满都',
  'Asia/Colombo': '科伦坡',
  'Asia/Kabul': '喀布尔',
  'Asia/Tashkent': '塔什干',
  'Asia/Almaty': '阿拉木图',
  'Asia/Aqtobe': '阿克托别',
  'Asia/Bishkek': '比什凯克',
  'Asia/Dushanbe': '杜尚别',
  'Asia/Ashgabat': '阿什哈巴德',
  'Asia/Tehran': '德黑兰',
  'Asia/Baghdad': '巴格达',
  'Asia/Riyadh': '利雅得',
  'Asia/Kuwait': '科威特',
  'Asia/Qatar': '卡塔尔',
  'Asia/Bahrain': '巴林',
  'Asia/Dubai': '迪拜',
  'Asia/Muscat': '马斯喀特',
  'Asia/Jerusalem': '耶路撒冷',
  'Asia/Tel_Aviv': '特拉维夫',
  'Asia/Beirut': '贝鲁特',
  'Asia/Damascus': '大马士革',
  'Asia/Amman': '安曼',
  'Asia/Nicosia': '尼科西亚',
  'Asia/Istanbul': '伊斯坦布尔',
  'Europe/Istanbul': '伊斯坦布尔',
  'Asia/Baku': '巴库',
  'Asia/Tbilisi': '第比利斯',
  'Asia/Yerevan': '埃里温',
  'Asia/Kathmandu ': '加德满都',
  'Asia/Yekaterinburg': '叶卡捷琳堡',
  'Asia/Novosibirsk': '新西伯利亚',
  'Asia/Krasnoyarsk': '克拉斯诺亚尔斯克',
  'Asia/Irkutsk': '伊尔库茨克',
  'Asia/Yakutsk': '雅库茨克',
  'Asia/Vladivostok': '符拉迪沃斯托克',
  'Asia/Magadan': '马加丹',
  'Asia/Kamchatka': '堪察加',
  'Europe/London': '伦敦',
  'Europe/Dublin': '都柏林',
  'Europe/Lisbon': '里斯本',
  'Europe/Madrid': '马德里',
  'Europe/Barcelona': '巴塞罗那',
  'Europe/Paris': '巴黎',
  'Europe/Brussels': '布鲁塞尔',
  'Europe/Amsterdam': '阿姆斯特丹',
  'Europe/Luxembourg': '卢森堡',
  'Europe/Berlin': '柏林',
  'Europe/Munich': '慕尼黑',
  'Europe/Zurich': '苏黎世',
  'Europe/Vienna': '维也纳',
  'Europe/Rome': '罗马',
  'Europe/Malta': '马耳他',
  'Europe/Copenhagen': '哥本哈根',
  'Europe/Oslo': '奥斯陆',
  'Europe/Stockholm': '斯德哥尔摩',
  'Europe/Helsinki': '赫尔辛基',
  'Europe/Tallinn': '塔林',
  'Europe/Riga': '里加',
  'Europe/Vilnius': '维尔纽斯',
  'Europe/Warsaw': '华沙',
  'Europe/Prague': '布拉格',
  'Europe/Bratislava': '布拉迪斯拉发',
  'Europe/Budapest': '布达佩斯',
  'Europe/Ljubljana': '卢布尔雅那',
  'Europe/Zagreb': '萨格勒布',
  'Europe/Belgrade': '贝尔格莱德',
  'Europe/Sarajevo': '萨拉热窝',
  'Europe/Skopje': '斯科普里',
  'Europe/Tirane': '地拉那',
  'Europe/Athens': '雅典',
  'Europe/Sofia': '索菲亚',
  'Europe/Bucharest': '布加勒斯特',
  'Europe/Chisinau': '基希讷乌',
  'Europe/Kyiv': '基辅',
  'Europe/Kiev': '基辅',
  'Europe/Minsk': '明斯克',
  'Europe/Moscow': '莫斯科',
  'Europe/Kaliningrad': '加里宁格勒',
  'Europe/Samara': '萨马拉',
  'Europe/Volgograd': '伏尔加格勒',
  'Europe/Reykjavik': '雷克雅未克',
  'Atlantic/Azores': '亚速尔群岛',
  'Atlantic/Madeira': '马德拉',
  'Atlantic/Canary': '加那利群岛',
  'Atlantic/Cape_Verde': '佛得角',
  'Africa/Cairo': '开罗',
  'Africa/Casablanca': '卡萨布兰卡',
  'Africa/Algiers': '阿尔及尔',
  'Africa/Tunis': '突尼斯',
  'Africa/Tripoli': '的黎波里',
  'Africa/Lagos': '拉各斯',
  'Africa/Accra': '阿克拉',
  'Africa/Abidjan': '阿比让',
  'Africa/Dakar': '达喀尔',
  'Africa/Nairobi': '内罗毕',
  'Africa/Addis_Ababa': '亚的斯亚贝巴',
  'Africa/Khartoum': '喀土穆',
  'Africa/Juba': '朱巴',
  'Africa/Kampala': '坎帕拉',
  'Africa/Dar_es_Salaam': '达累斯萨拉姆',
  'Africa/Lusaka': '卢萨卡',
  'Africa/Harare': '哈拉雷',
  'Africa/Maputo': '马普托',
  'Africa/Johannesburg': '约翰内斯堡',
  'Africa/Windhoek': '温得和克',
  'Africa/Luanda': '罗安达',
  'Africa/Kinshasa': '金沙萨',
  'Africa/Brazzaville': '布拉柴维尔',
  'Africa/Douala': '杜阿拉',
  'Africa/Abuja': '阿布贾',
  'America/New_York': '纽约',
  'America/Chicago': '芝加哥',
  'America/Denver': '丹佛',
  'America/Phoenix': '菲尼克斯',
  'America/Los_Angeles': '洛杉矶',
  'America/Anchorage': '安克雷奇',
  'America/Adak': '阿达克',
  'Pacific/Honolulu': '檀香山',
  'America/Toronto': '多伦多',
  'America/Vancouver': '温哥华',
  'America/Edmonton': '埃德蒙顿',
  'America/Winnipeg': '温尼伯',
  'America/Halifax': '哈利法克斯',
  'America/St_Johns': '圣约翰斯',
  'America/Montreal': '蒙特利尔',
  'America/Mexico_City': '墨西哥城',
  'America/Tijuana': '蒂华纳',
  'America/Monterrey': '蒙特雷',
  'America/Guatemala': '危地马拉城',
  'America/Costa_Rica': '圣何塞',
  'America/Panama': '巴拿马城',
  'America/Havana': '哈瓦那',
  'America/Jamaica': '金斯敦',
  'America/Santo_Domingo': '圣多明各',
  'America/Puerto_Rico': '圣胡安',
  'America/Caracas': '加拉加斯',
  'America/Bogota': '波哥大',
  'America/Lima': '利马',
  'America/Quito': '基多',
  'America/La_Paz': '拉巴斯',
  'America/Santiago': '圣地亚哥',
  'America/Argentina/Buenos_Aires': '布宜诺斯艾利斯',
  'America/Buenos_Aires': '布宜诺斯艾利斯',
  'America/Sao_Paulo': '圣保罗',
  'America/Rio_de_Janeiro': '里约热内卢',
  'America/Manaus': '马瑙斯',
  'America/Montevideo': '蒙得维的亚',
  'America/Asuncion': '亚松森',
  'Australia/Sydney': '悉尼',
  'Australia/Melbourne': '墨尔本',
  'Australia/Brisbane': '布里斯班',
  'Australia/Perth': '珀斯',
  'Australia/Adelaide': '阿德莱德',
  'Australia/Darwin': '达尔文',
  'Australia/Hobart': '霍巴特',
  'Pacific/Auckland': '奥克兰',
  'Pacific/Wellington': '惠灵顿',
  'Pacific/Fiji': '苏瓦',
  'Pacific/Guam': '关岛',
  'Pacific/Port_Moresby': '莫尔兹比港',
  'Pacific/Tahiti': '塔希提',
  'Pacific/Apia': '阿皮亚',
  'Pacific/Tongatapu': '努库阿洛法',
  'Indian/Maldives': '马累',
  'Indian/Mauritius': '路易港',
  'Indian/Reunion': '留尼汪',
  'Indian/Mahe': '维多利亚',
  'South_Pole': '南极点',
  'Antarctica/McMurdo': '麦克默多站',
};

/// 搜索别名：IANA 城市名之外，用户可能输入的地区/国家名。
const Map<String, String> _timeZoneAliases = <String, String>{
  'Asia/Shanghai': '中国 上海 shanghai china cst 北京 香港',
  'Asia/Hong_Kong': '香港 hong kong 中国',
  'Asia/Macau': '澳门 macau 中国',
  'Asia/Taipei': '台湾 台北 taiwan 中国',
  'Asia/Tokyo': '日本 东京 japan 东京都',
  'Asia/Seoul': '韩国 首尔 korea seoul',
  'Asia/Singapore': '新加坡 singapore',
  'Asia/Kuala_Lumpur': '马来西亚 吉隆坡 malaysia',
  'Asia/Bangkok': '泰国 曼谷 thailand',
  'Asia/Ho_Chi_Minh': '越南 河内 胡志明 vietnam',
  'Asia/Kolkata': '印度 新德里 孟买 india delhi mumbai',
  'Asia/Dubai': '阿联酋 迪拜 uae emirates',
  'Asia/Riyadh': '沙特 利雅得 saudi',
  'Asia/Jerusalem': '以色列 耶路撒冷 israel',
  'Asia/Istanbul': '土耳其 伊斯坦布尔 turkey',
  'Europe/London': '英国 伦敦 uk britain gmt',
  'Europe/Paris': '法国 巴黎 france cet',
  'Europe/Berlin': '德国 柏林 germany',
  'Europe/Madrid': '西班牙 马德里 spain',
  'Europe/Rome': '意大利 罗马 italy',
  'Europe/Amsterdam': '荷兰 阿姆斯特丹 netherlands',
  'Europe/Brussels': '比利时 布鲁塞尔 belgium',
  'Europe/Zurich': '瑞士 苏黎世 switzerland',
  'Europe/Vienna': '奥地利 维也纳 austria',
  'Europe/Stockholm': '瑞典 斯德哥尔摩 sweden',
  'Europe/Oslo': '挪威 奥斯陆 norway',
  'Europe/Copenhagen': '丹麦 哥本哈根 denmark',
  'Europe/Helsinki': '芬兰 赫尔辛基 finland',
  'Europe/Warsaw': '波兰 华沙 poland',
  'Europe/Prague': '捷克 布拉格 czech',
  'Europe/Budapest': '匈牙利 布达佩斯 hungary',
  'Europe/Athens': '希腊 雅典 greece',
  'Europe/Moscow': '俄罗斯 莫斯科 russia',
  'Europe/Kyiv': '乌克兰 基辅 ukraine',
  'America/New_York': '美国 纽约 usa us eastern est edt',
  'America/Chicago': '美国 芝加哥 usa us central cst cdt',
  'America/Denver': '美国 丹佛 usa us mountain mst mdt',
  'America/Phoenix': '美国 菲尼克斯 亚利桑那 usa us arizona',
  'America/Los_Angeles': '美国 洛杉矶 旧金山 西雅图 usa us pacific pst pdt',
  'America/Anchorage': '美国 阿拉斯加 安克雷奇 usa alaska',
  'Pacific/Honolulu': '美国 夏威夷 檀香山 usa hawaii',
  'America/Toronto': '加拿大 多伦多 canada',
  'America/Vancouver': '加拿大 温哥华 canada',
  'America/Mexico_City': '墨西哥 墨西哥城 mexico',
  'America/Sao_Paulo': '巴西 圣保罗 brazil',
  'America/Argentina/Buenos_Aires': '阿根廷 布宜诺斯艾利斯 argentina',
  'America/Santiago': '智利 圣地亚哥 chile',
  'America/Bogota': '哥伦比亚 波哥大 colombia',
  'America/Lima': '秘鲁 利马 peru',
  'Australia/Sydney': '澳大利亚 悉尼 australia nsw',
  'Australia/Melbourne': '澳大利亚 墨尔本 australia victoria',
  'Australia/Brisbane': '澳大利亚 布里斯班 australia queensland',
  'Australia/Perth': '澳大利亚 珀斯 australia western',
  'Australia/Adelaide': '澳大利亚 阿德莱德 australia south',
  'Pacific/Auckland': '新西兰 奥克兰 new zealand nz',
  'Africa/Cairo': '埃及 开罗 egypt',
  'Africa/Johannesburg': '南非 约翰内斯堡 south africa',
  'Africa/Lagos': '尼日利亚 拉各斯 nigeria',
  'Africa/Nairobi': '肯尼亚 内罗毕 kenya',
  'UTC': '世界标准时间 协调世界时 gmt utc',
  'Etc/UTC': '世界标准时间 协调世界时 gmt utc',
};

String _cityLabel(String id) {
  final zh = _zhCityNames[id];
  if (zh != null) return zh;
  if (id == 'UTC') return '协调世界时';
  final slash = id.lastIndexOf('/');
  final city = slash >= 0 ? id.substring(slash + 1) : id;
  return city.replaceAll('_', ' ');
}
