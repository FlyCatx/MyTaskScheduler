// Decoding + validating the calendar constraints the *model* returned.
//
// This file used to contain local keyword/regex "extraction" and call it AI. That was
// wrong on two counts: it never saw the material the model sees, and a regex that finds
// `08:00-10:00` cannot tell "上课" (a course, unavailable) from "可工作" (available).
// The semantic work now happens in a real model request (`src/constraints.c`), and this
// file only does what must be local and deterministic:
//
//   * validate every field the model sent (type, range, date, source, evidence);
//   * assign a stable id (so the same candidate is not imported twice);
//   * turn "recognised but not placeable" items into questions, never into blocks;
//   * apply accepted proposals to the real weekly / exceptions / occupancies data
//     without duplicating something the user already confirmed.

import '../model/calendar.dart';
import '../model/calendar_proposals.dart';

/// Outcome of asking the model for calendar constraints.
class CalendarProposalOutcome {
  final CalendarProposalSet? set;
  final String? error;

  /// Proposals the local validator dropped (shown as a warning, not hidden).
  final List<String> rejected;

  const CalendarProposalOutcome.failure(String this.error)
      : set = null,
        rejected = const [];

  CalendarProposalOutcome.success(CalendarProposalSet this.set,
      {this.rejected = const []})
      : error = null;

  bool get ok => set != null;
}

/// Outcome of decoding one native payload.
class ProposalDecodeResult {
  final CalendarProposalSet? set;

  /// Reasons individual proposals were dropped. Shown to the user: a silently
  /// shrinking list would look like the model simply found less.
  final List<String> rejected;

  final String? error;

  const ProposalDecodeResult.success(this.set, {this.rejected = const []})
      : error = null;

  const ProposalDecodeResult.failure(this.error)
      : set = null,
        rejected = const [];

  bool get ok => set != null;
}

/// Builds a [CalendarProposalSet] from the native `constraints` object.
///
/// The native layer already rejected non-JSON / wrong-shaped answers; this pass enforces
/// the *semantic* rules and is the only producer of proposals the UI ever sees.
ProposalDecodeResult decodeCalendarProposals(
  Object? raw, {
  required String materialSignature,
  required DateTime now,
  bool thinkingEnabled = false,
  String? thinkingEffort,
  String? protocol,
}) {
  if (raw is! Map) {
    return const ProposalDecodeResult.failure('模型返回的约束不是 JSON 对象');
  }
  final map = Map<String, dynamic>.from(raw);
  final rawProposals = map['proposals'];
  if (rawProposals is! List) {
    return const ProposalDecodeResult.failure('模型返回的约束缺少 proposals 数组');
  }

  final rejected = <String>[];
  final accepted = <CalendarProposal>[];
  final usedIds = <String>{};
  final usedNotes = <String>{};

  for (var i = 0; i < rawProposals.length; i++) {
    final item = rawProposals[i];
    if (item is! Map) {
      rejected.add('第 ${i + 1} 条不是 JSON 对象');
      continue;
    }
    final decoded = _decodeOne(Map<String, dynamic>.from(item), index: i);
    if (decoded.error != null) {
      rejected.add(decoded.error!);
      continue;
    }
    final proposal = decoded.proposal!;
    // The id is derived from the content, so the model cannot destabilise it and
    // identical candidates collapse instead of being imported twice.
    if (!usedIds.add(proposal.id)) continue;
    accepted.add(proposal);
  }

  final notes = <String>[];
  final rawNotes = map['notes'];
  if (rawNotes is List) {
    for (final n in rawNotes) {
      final text = '$n'.trim();
      if (text.isEmpty) continue;
      if (usedNotes.add(text)) notes.add(text);
    }
  }
  // Unplaceable proposals ("吃饭 30 分钟" with no clock time) are surfaced as questions.
  for (final p in accepted) {
    if (p.kind == CalendarProposalKind.unclear || p.needsTime) {
      final text = p.question ?? p.label;
      if (usedNotes.add(text)) notes.add(text);
    }
  }

  return ProposalDecodeResult.success(
    CalendarProposalSet(
      proposals: accepted,
      notes: notes,
      materialSignature: materialSignature,
      createdAt: now.toUtc(),
      thinkingEnabled: thinkingEnabled,
      thinkingEffort: thinkingEffort,
      protocol: protocol,
    ),
    rejected: rejected,
  );
}

class _Decoded {
  final CalendarProposal? proposal;
  final String? error;
  const _Decoded.ok(this.proposal) : error = null;
  const _Decoded.fail(this.error) : proposal = null;
}

_Decoded _decodeOne(Map<String, dynamic> j, {required int index}) {
  final where = '第 ${index + 1} 条';
  final kind = CalendarProposalKind.tryParse(j['kind']);
  if (kind == null) {
    return _Decoded.fail('$where：未知类型「${j['kind']}」');
  }
  final evidence = '${j['evidence'] ?? ''}'.trim();
  if (evidence.isEmpty) {
    return _Decoded.fail('$where（${kind.label}）：没有原文依据，无法核对');
  }
  final source = '${j['source'] ?? ''}'.trim();

  // ---- ranges
  final ranges = <WallClockRange>[];
  final rawRanges = j['ranges'];
  if (rawRanges != null && rawRanges is! List) {
    return _Decoded.fail('$where：ranges 必须是数组');
  }
  for (final r in (rawRanges as List<dynamic>?) ?? const []) {
    if (r is! Map) {
      return _Decoded.fail('$where：时段不是 JSON 对象');
    }
    final start = (r['start'] as num?)?.toInt();
    final end = (r['end'] as num?)?.toInt();
    if (start == null || end == null) {
      return _Decoded.fail('$where：时段缺少 start/end');
    }
    if (start < 0 || end <= start || end > 2880) {
      return _Decoded.fail('$where：时段 $start–$end 分钟不合法');
    }
    ranges.add(WallClockRange(start, end));
  }

  // ---- weekdays / date
  final weekdays = <int>[];
  final rawDays = j['weekdays'];
  if (rawDays != null && rawDays is! List) {
    return _Decoded.fail('$where：weekdays 必须是数组');
  }
  for (final d in (rawDays as List<dynamic>?) ?? const []) {
    final day = d is num ? d.toInt() : int.tryParse('$d');
    if (day == null || day < 1 || day > 7) {
      return _Decoded.fail('$where：星期「$d」不是 1–7');
    }
    if (!weekdays.contains(day)) weekdays.add(day);
  }
  weekdays.sort();

  final rawDate = '${j['date'] ?? ''}'.trim();
  String? date;
  if (rawDate.isNotEmpty) {
    if (rawDate == '每天' || rawDate == '每日') {
      date = null;
    } else {
      date = parseDateKey(rawDate);
      if (date == null) {
        return _Decoded.fail('$where：日期「$rawDate」不是 yyyy-MM-dd');
      }
    }
  }

  final duration = (j['durationMinutes'] as num?)?.toInt();
  if (duration != null && (duration <= 0 || duration > 1440)) {
    return _Decoded.fail('$where：时长 $duration 分钟不合法');
  }

  // A rule needs *something* to stand on: a window, a date, or a duration to ask about.
  final needsTime =
      ranges.isEmpty && (kind == CalendarProposalKind.occupancy) && duration != null;
  if (kind != CalendarProposalKind.unclear &&
      ranges.isEmpty &&
      !needsTime &&
      !(kind == CalendarProposalKind.exception && j['closed'] == true)) {
    return _Decoded.fail('$where（${kind.label}）：既没有时段，也没有可确认的时长');
  }
  if (kind == CalendarProposalKind.exception && date == null) {
    return _Decoded.fail('$where：日期例外必须给出具体日期');
  }

  final title = '${j['title'] ?? ''}'.trim();
  final occupancyKind = switch ('${j['occupancyKind'] ?? ''}') {
    'course' => 'course',
    'rest' => 'rest',
    'activity' => 'activity',
    _ => kind == CalendarProposalKind.occupancy ? 'activity' : 'activity',
  };
  final resolvedTitle = title.isNotEmpty
      ? title
      : switch (kind) {
          CalendarProposalKind.availability => '可用时间',
          CalendarProposalKind.occupancy => '占用',
          CalendarProposalKind.exception => '日期例外',
          CalendarProposalKind.unclear => '待确认',
        };

  final id = calendarProposalId(
    kind: kind,
    title: resolvedTitle,
    weekdays: date == null ? weekdays : const <int>[],
    date: date,
    ranges: ranges,
    occupancyKind: kind == CalendarProposalKind.occupancy ? occupancyKind : null,
  );

  final question = '${j['question'] ?? ''}'.trim();
  return _Decoded.ok(CalendarProposal(
    id: id,
    kind: kind,
    title: resolvedTitle,
    occupancyKind: occupancyKind,
    weekdays: date == null ? weekdays : const <int>[],
    date: date,
    closed: j['closed'] == true,
    ranges: ranges,
    durationMinutes: duration,
    evidence: evidence,
    source: source.isEmpty ? '（模型未注明来源）' : source,
    needsTime: needsTime,
    question: question.isEmpty ? null : question,
  ));
}

// ---------------------------------------------------------------- applying

/// Result of applying the ticked proposals to the real calendar data.
class AppliedProposals {
  final Map<int, List<WallClockRange>> weekly;
  final List<CalendarDateException> exceptions;
  final List<CalendarOccupancy> occupancies;
  final List<String> pendingNotes;

  /// How many proposals actually changed something (duplicates are skipped).
  final int applied;

  /// Proposals that were already present in the data (not imported again).
  final int skipped;

  const AppliedProposals({
    required this.weekly,
    required this.exceptions,
    required this.occupancies,
    required this.pendingNotes,
    this.applied = 0,
    this.skipped = 0,
  });
}

/// Writes [accepted] into a copy of the current editor state.
///
/// Deduplication is by *content*, not by id alone: reopening the dialog after a save
/// regenerates the same candidates, and the user must not end up with two identical
/// weekly windows. Identical text on a different weekday is kept, because it is a
/// different rule.
AppliedProposals applyAcceptedProposals({
  required Iterable<CalendarProposal> accepted,
  required Map<int, List<WallClockRange>> weekly,
  required List<CalendarDateException> exceptions,
  required List<CalendarOccupancy> occupancies,
  required List<String> pendingNotes,
  required String idPrefix,
}) {
  final nextWeekly = <int, List<WallClockRange>>{
    for (final e in weekly.entries) e.key: [...e.value],
  };
  final nextExceptions = <CalendarDateException>[...exceptions];
  final nextOccupancies = <CalendarOccupancy>[...occupancies];
  final nextNotes = <String>[...pendingNotes];
  final seenNotes = nextNotes.map((n) => n.trim()).toSet();
  var applied = 0;
  var skipped = 0;
  var sequence = nextOccupancies.length;

  for (final p in accepted) {
    if (!p.isApplicable) {
      // Cannot be placed: it stays a question, not a rule.
      final text = (p.question ?? p.label).trim();
      if (text.isNotEmpty && seenNotes.add(text)) nextNotes.add(text);
      skipped++;
      continue;
    }
    switch (p.kind) {
      case CalendarProposalKind.availability:
        final days = p.isRepeating
            ? (p.weekdays.isEmpty
                ? const <int>[1, 2, 3, 4, 5, 6, 7]
                : p.weekdays)
            : const <int>[];
        if (!p.isRepeating) {
          // A one-off "available on 2026-10-21" is an open date exception.
          final existing = _exceptionOn(nextExceptions, p.date!);
          if (existing == null) {
            nextExceptions.add(CalendarDateException(
              date: p.date!,
              closed: false,
              ranges: p.ranges,
              note: p.evidence,
            ));
            applied++;
          } else {
            skipped++;
          }
          break;
        }
        var changed = false;
        for (final d in days) {
          final current = nextWeekly[d] ?? const <WallClockRange>[];
          final merged = _merge([...current, ...p.ranges]);
          if (!_sameRanges(current, merged)) {
            nextWeekly[d] = merged;
            changed = true;
          }
        }
        if (changed) {
          applied++;
        } else {
          skipped++;
        }
      case CalendarProposalKind.occupancy:
        final isDuplicate = nextOccupancies.any((o) =>
            o.title.trim() == p.title.trim() &&
            o.kind == p.occupancyKind &&
            ((p.isRepeating && o.isWeekly && o.weekday == _firstWeekday(p)) ||
                (!p.isRepeating && o.date == p.date)) &&
            _sameRanges(o.ranges, p.ranges));
        if (isDuplicate) {
          skipped++;
          break;
        }
        final days = p.isRepeating
            ? (p.weekdays.isEmpty ? const <int>[1] : p.weekdays)
            : const <int>[0];
        for (final d in days) {
          sequence++;
          nextOccupancies.add(CalendarOccupancy(
            id: '$idPrefix-occ-$sequence-${p.id.substring(3, 9)}',
            title: p.title,
            kind: p.occupancyKind,
            date: p.isRepeating ? null : p.date,
            weekday: p.isRepeating ? d : 0,
            ranges: p.ranges,
            // The user ticked it, so it is confirmed data, not a provisional guess.
            provisional: false,
          ));
        }
        applied++;
      case CalendarProposalKind.exception:
        final existing = _exceptionOn(nextExceptions, p.date!);
        if (existing == null) {
          nextExceptions.add(CalendarDateException(
            date: p.date!,
            closed: p.closed,
            ranges: p.closed ? const <WallClockRange>[] : p.ranges,
            note: p.evidence,
          ));
          applied++;
        } else {
          skipped++;
        }
      case CalendarProposalKind.unclear:
        skipped++;
    }
  }

  return AppliedProposals(
    weekly: nextWeekly,
    exceptions: nextExceptions,
    occupancies: nextOccupancies,
    pendingNotes: nextNotes,
    applied: applied,
    skipped: skipped,
  );
}

int _firstWeekday(CalendarProposal p) => p.weekdays.isEmpty ? 1 : p.weekdays.first;

CalendarDateException? _exceptionOn(
    List<CalendarDateException> list, String date) {
  for (final e in list) {
    if (e.date == date) return e;
  }
  return null;
}

bool _sameRanges(List<WallClockRange> a, List<WallClockRange> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].startMinute != b[i].startMinute ||
        a[i].endMinute != b[i].endMinute) {
      return false;
    }
  }
  return true;
}

List<WallClockRange> _merge(List<WallClockRange> input) {
  if (input.isEmpty) return const <WallClockRange>[];
  final sorted = <WallClockRange>[...input]
    ..sort((a, b) => a.startMinute.compareTo(b.startMinute));
  final out = <WallClockRange>[sorted.first];
  for (final r in sorted.skip(1)) {
    final last = out.last;
    if (r.startMinute <= last.endMinute) {
      if (r.endMinute > last.endMinute) {
        out[out.length - 1] = WallClockRange(last.startMinute, r.endMinute);
      }
    } else {
      out.add(r);
    }
  }
  return out;
}

