// 时区目录（任务 10.3/10.4）单测：来自 IANA 数据库、中文城市+UTC 偏移展示、
// 保存 IANA ID、搜索只缩小选项、同偏移不同 DST 地区可区分、旧值精确命中。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_timezones.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_timezones.dart';

void main() {
  setUpAll(IcsTimeZoneResolver.ensureDatabase);
  setUp(ScheduleTimeZoneCatalog.resetForTest);
  tearDown(ScheduleTimeZoneCatalog.resetForTest);

  final at = DateTime.utc(2026, 11, 6, 3);

  test('目录来自 IANA 数据库而不是硬编码截图城市', () {
    final options = ScheduleTimeZoneCatalog.options(at);
    expect(options.length, greaterThan(300));
    expect(options.map((o) => o.id), contains('Asia/Shanghai'));
    expect(options.map((o) => o.id), contains('America/New_York'));
    expect(options.map((o) => o.id), contains('Pacific/Auckland'));
    expect(options.map((o) => o.id), contains('Africa/Abidjan'));
  });

  test('搜索中文城市/地区与 IANA 名称；不接受任意文本作为保存值', () {
    final beijing = ScheduleTimeZoneCatalog.search('北京', at);
    expect(beijing.any((o) => o.id == 'Asia/Shanghai'), isTrue);
    expect(
      beijing.firstWhere((o) => o.id == 'Asia/Shanghai').displayLabel,
      contains('北京'),
    );
    final byId = ScheduleTimeZoneCatalog.search('Asia/Tokyo', at);
    expect(byId.any((o) => o.id == 'Asia/Tokyo'), isTrue);
    // 拼音/英文别名可搜。
    expect(
      ScheduleTimeZoneCatalog.search('london', at).any(
            (o) => o.id == 'Europe/London',
          ),
      isTrue,
    );
    // 任意文本不产生新选项：搜索只是过滤。
    expect(ScheduleTimeZoneCatalog.search('随便输入的城市', at), isEmpty);
    // 目录里没有的 IANA 值返回 null，由界面显示“修复入口”。
    expect(ScheduleTimeZoneCatalog.find('Not/AZone', at), isNull);
  });

  test('UTC 偏移展示格式与排序', () {
    expect(formatUtcOffset(8 * 60), 'UTC+08:00');
    expect(formatUtcOffset(-5 * 60), 'UTC-05:00');
    expect(formatUtcOffset(5 * 60 + 30), 'UTC+05:30');
    expect(formatUtcOffset(0), 'UTC+00:00');

    final options = ScheduleTimeZoneCatalog.options(at);
    for (var i = 1; i < options.length; i++) {
      expect(
        options[i].offsetMinutes,
        greaterThanOrEqualTo(options[i - 1].offsetMinutes),
        reason: '按当前 UTC 偏移升序排列，便于用户查找',
      );
    }
  });

  test('同偏移不同 DST 地区分别列出并可区分', () {
    final london = ScheduleTimeZoneCatalog.find('Europe/London', at);
    final abidjan = ScheduleTimeZoneCatalog.find('Africa/Abidjan', at);
    expect(london, isNotNull);
    expect(abidjan, isNotNull);
    // 11 月两地当前都是 UTC+00:00，但伦敦有夏令时、阿比让没有。
    final november = DateTime.utc(2026, 11, 6, 3);
    final londonOptions = ScheduleTimeZoneCatalog.options(november);
    final londonNow =
        londonOptions.firstWhere((option) => option.id == 'Europe/London');
    final abidjanNow =
        londonOptions.firstWhere((option) => option.id == 'Africa/Abidjan');
    expect(londonNow.offsetMinutes, abidjanNow.offsetMinutes);
    expect(londonNow.observesDst, isTrue);
    expect(abidjanNow.observesDst, isFalse);
    // 两者是不同的 IANA ID，保存结果可区分。
    expect(londonNow.id, isNot(abidjanNow.id));
  });

  test('没有中文别名的旧 IANA 值仍精确命中；大小写/空白修复', () {
    // Etc/GMT+5 没有中文城市名，但属于 IANA 数据库，必须能预选。
    final option = ScheduleTimeZoneCatalog.find('Etc/GMT+5', at);
    expect(option, isNotNull);
    expect(option!.id, 'Etc/GMT+5');
    expect(option.displayLabel, contains('UTC-05:00'));
    expect(ScheduleTimeZoneCatalog.find('  Asia/Shanghai  ', at)?.id,
        'Asia/Shanghai');
  });
}
