// Structured calendar constraints proposed by the model.
//
// The model is asked (see `src/constraints.c`) to return *proposals*, never decisions:
//
//   availability — "每天 8:00-24:00 可工作"  → a weekly open window,
//   occupancy    — "周二/周四 8-10 上课"     → a course/activity/rest block,
//   exception    — "2026-10-22 全天不可用"   → a closed date,
//   unclear      — "中午吃饭 30 分钟"        → a question, never a guessed clock time.
//
// Every proposal carries: a stable id, its type, a title, weekday(s) or a concrete date,
// the wall-clock window (or only a duration when the start is unknown), the original
// evidence text and where it came from. Nothing here is applied by itself: the dialog
// starts with every box unticked and only an explicit user tick writes it into the
// real weekly / exceptions / occupancies data.
//
// Validation is strict and local: a payload with wrong types, impossible ranges, bad
// dates or no evidence is rejected instead of being repaired into "everything is
// available".

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'calendar.dart';

/// What the model claims to have found.
enum CalendarProposalKind {
  /// A window the user *can* work in.
  availability,

  /// A course / activity / rest block that reduces available time.
  occupancy,

  /// A date that does not follow the weekly rule (usually closed).
  exception,

  /// Recognised as a constraint but not placeable — becomes a question, not a rule.
  unclear;

  static CalendarProposalKind? tryParse(Object? raw) => switch ('$raw') {
        'availability' => CalendarProposalKind.availability,
        'occupancy' => CalendarProposalKind.occupancy,
        'exception' => CalendarProposalKind.exception,
        'unclear' => CalendarProposalKind.unclear,
        _ => null,
      };

  String get wireName => name;

  String get label => switch (this) {
        CalendarProposalKind.availability => '可用时间',
        CalendarProposalKind.occupancy => '占用',
        CalendarProposalKind.exception => '日期例外',
        CalendarProposalKind.unclear => '待确认',
      };
}

/// One proposal. Immutable; [id] is stable across re-analysis of the same material.
class CalendarProposal {
  final String id;
  final CalendarProposalKind kind;

  /// Display title; for an occupancy this is the block name ("上课", "午饭").
  final String title;

  /// `course` | `activity` | `rest` — only meaningful for [CalendarProposalKind.occupancy].
  final String occupancyKind;

  /// Repeating weekdays (1 = Monday … 7 = Sunday). Empty when [date] is set.
  final List<int> weekdays;

  /// One-off `yyyy-MM-dd`; null for a repeating rule.
  final String? date;

  /// True for a closed date exception (整日不可用).
  final bool closed;

  /// Wall-clock windows. Empty when only a duration is known (see [durationMinutes]).
  final List<WallClockRange> ranges;

  /// Duration in minutes when the model recognised a block but no exact clock time.
  final int? durationMinutes;

  /// The sentence this came from. Required — a proposal without evidence is rejected.
  final String evidence;

  /// Where it came from, e.g. `材料2:第3段`. Never empty (a placeholder is substituted).
  final String source;

  /// True when a start time still has to be supplied by the user.
  final bool needsTime;

  /// The question shown for an unplaceable constraint.
  final String? question;

  const CalendarProposal({
    required this.id,
    required this.kind,
    required this.title,
    this.occupancyKind = 'activity',
    this.weekdays = const [],
    this.date,
    this.closed = false,
    this.ranges = const [],
    this.durationMinutes,
    required this.evidence,
    required this.source,
    this.needsTime = false,
    this.question,
  });

  bool get isRepeating => date == null || date!.isEmpty;

  /// True when this proposal can be written into real data by ticking it.
  ///
  /// A closed date exception legitimately has no window, so it is applicable without
  /// ranges; everything else needs a window and no pending start time.
  bool get isApplicable {
    if (kind == CalendarProposalKind.unclear || needsTime) return false;
    if (kind == CalendarProposalKind.exception) return closed || ranges.isNotEmpty;
    return ranges.isNotEmpty;
  }

  /// Weekday label list, e.g. `周一、周四`; `每天` when no weekday is set.
  String get weekdayLabel {
    if (!isRepeating) return date!;
    if (weekdays.isEmpty) return '每天';
    return weekdays.map(_weekdayShort).join('、');
  }

  String get rangeLabel => ranges.isEmpty
      ? (durationMinutes == null ? '时段待补' : '约 $durationMinutes 分钟')
      : ranges.map(WallClockRange.format).join('、');

  /// One-line label used in the dialog and in test assertions.
  String get label {
    final kindText = kind == CalendarProposalKind.occupancy
        ? _occupancyKindLabel(occupancyKind)
        : kind.label;
    if (kind == CalendarProposalKind.exception) {
      return '$date ${closed ? '整天不可用' : rangeLabel}';
    }
    if (kind == CalendarProposalKind.unclear) {
      return question ?? title;
    }
    return '$kindText · $title · $weekdayLabel $rangeLabel';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind.wireName,        'title': title,
        'occupancyKind': occupancyKind,
        'weekdays': weekdays,
        'date': date,
        'closed': closed,
        'ranges': ranges.map((r) => r.toJson()).toList(growable: false),
        'durationMinutes': durationMinutes,
        'evidence': evidence,
        'source': source,
        'needsTime': needsTime,
        'question': question,
      };

  /// Same proposal with a user-supplied window.
  ///
  /// Used for a candidate the model recognised only by duration ("吃饭 30 分钟"): the
  /// user types the actual clock time here, so it can finally be applied. The id is
  /// recomputed because it is content-derived.
  CalendarProposal withRanges(List<WallClockRange> newRanges) => CalendarProposal(
        id: calendarProposalId(
          kind: kind,
          title: title,
          weekdays: weekdays,
          date: date,
          ranges: newRanges,
          occupancyKind:
              kind == CalendarProposalKind.occupancy ? occupancyKind : null,
        ),
        kind: kind,
        title: title,
        occupancyKind: occupancyKind,
        weekdays: weekdays,
        date: date,
        closed: closed,
        ranges: newRanges,
        durationMinutes: durationMinutes,
        evidence: evidence,
        source: source,
        needsTime: false,
        question: question,
      );

  factory CalendarProposal.fromJson(Map<String, dynamic> j) => CalendarProposal(
        id: (j['id'] as String?) ?? '',
        kind: CalendarProposalKind.tryParse(j['kind']) ??
            CalendarProposalKind.unclear,
        title: (j['title'] as String?) ?? '',
        occupancyKind: (j['occupancyKind'] as String?) ?? 'activity',
        weekdays: ((j['weekdays'] as List<dynamic>?) ?? const [])
            .whereType<num>()
            .map((e) => e.toInt())
            .where((d) => d >= 1 && d <= 7)
            .toSet()
            .toList(growable: false)
          ..sort(),
        date: (j['date'] as String?)?.trim(),
        closed: j['closed'] == true,
        ranges: ((j['ranges'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map((e) => WallClockRange.fromJson(Map<String, dynamic>.from(e)))
            .where((r) => r.isValid)
            .toList(growable: false),
        durationMinutes: (j['durationMinutes'] as num?)?.toInt(),
        evidence: (j['evidence'] as String?) ?? '',
        source: (j['source'] as String?) ?? '',
        needsTime: j['needsTime'] == true,
        question: (j['question'] as String?)?.trim(),
      );

  static String _weekdayShort(int weekday) => switch (weekday) {
        1 => '周一',
        2 => '周二',
        3 => '周三',
        4 => '周四',
        5 => '周五',
        6 => '周六',
        _ => '周日',
      };

  static String _occupancyKindLabel(String kind) => switch (kind) {
        'course' => '课程',
        'rest' => '休息',
        _ => '活动',
      };
}

/// Deterministic id for one proposal: same content → same id, different weekday/date →
/// different id. Used both for de-duplication and to remember "already applied".
String calendarProposalId({
  required CalendarProposalKind kind,
  required String title,
  required Iterable<int> weekdays,
  required String? date,
  required Iterable<WallClockRange> ranges,
  String? occupancyKind,
}) {
  final sortedDays = weekdays.toSet().toList()..sort();
  final sortedRanges = ranges
      .map((r) => '${r.startMinute}-${r.endMinute}')
      .toList()
    ..sort();
  final canonical = <String>[
    kind.wireName,
    occupancyKind ?? '',
    title.trim(),
    sortedDays.join('+'),
    (date ?? '').trim(),
    sortedRanges.join(','),
  ].join('|');
  final digest = sha1.convert(utf8.encode(canonical)).toString();
  return 'cp-${digest.substring(0, 12)}';
}

/// A whole validated answer from the model, plus the facts needed to keep it honest.
class CalendarProposalSet {
  /// Bumped when the wire format changes; older payloads are ignored, not guessed.
  static const int schemaVersion = 1;

  final List<CalendarProposal> proposals;

  /// Text that could not be structured (unplaceable constraints). Shown as 待确认.
  final List<String> notes;

  /// Which material this answer belongs to (see [materialSignature]).
  final String materialSignature;

  /// When the answer arrived (UTC).
  final DateTime createdAt;

  /// Thinking settings the request actually used, as reported by the native layer.
  /// Never a claim about the global settings: only this request.
  final bool thinkingEnabled;
  final String? thinkingEffort;
  final String? protocol;

  const CalendarProposalSet({
    required this.proposals,
    this.notes = const [],
    required this.materialSignature,
    required this.createdAt,
    this.thinkingEnabled = false,
    this.thinkingEffort,
    this.protocol,
  });

  bool get isEmpty => proposals.isEmpty && notes.isEmpty;

  /// Number of proposals the user can tick (unclear ones cannot be applied).
  int get applicableCount => proposals.where((p) => p.isApplicable).length;

  /// Honest one-line description of how this answer was produced.
  String get thinkingLabel {
    if (!thinkingEnabled) return '本次识别：未启用思考';
    final effort = thinkingEffort == null || thinkingEffort!.isEmpty
        ? ''
        : ' ${thinkingEffort!}';
    return '本次识别：思考$effort';
  }

  /// Asking again is free of side effects, so the dialog offers it explicitly instead of
  /// silently spending another request.
  CalendarProposalSet copyWith({
    List<CalendarProposal>? proposals,
    List<String>? notes,
  }) =>
      CalendarProposalSet(
        proposals: proposals ?? this.proposals,
        notes: notes ?? this.notes,
        materialSignature: materialSignature,
        createdAt: createdAt,
        thinkingEnabled: thinkingEnabled,
        thinkingEffort: thinkingEffort,
        protocol: protocol,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'materialSignature': materialSignature,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'thinkingEnabled': thinkingEnabled,
        'thinkingEffort': thinkingEffort,
        'protocol': protocol,
        'proposals': proposals.map((p) => p.toJson()).toList(growable: false),
        'notes': notes,
      };

  /// Returns null for an older/foreign payload instead of inventing an empty answer.
  static CalendarProposalSet? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final version = (j['schemaVersion'] as num?)?.toInt();
    if (version != schemaVersion) return null;
    final created =
        DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now();
    return CalendarProposalSet(
      proposals: ((j['proposals'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => CalendarProposal.fromJson(Map<String, dynamic>.from(e)))
          .where((p) => p.id.isNotEmpty && p.evidence.isNotEmpty)
          .toList(growable: false),
      notes: ((j['notes'] as List<dynamic>?) ?? const [])
          .map((e) => '$e'.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false),
      materialSignature: (j['materialSignature'] as String?) ?? '',
      createdAt: created,
      thinkingEnabled: j['thinkingEnabled'] == true,
      thinkingEffort: j['thinkingEffort'] as String?,
      protocol: j['protocol'] as String?,
    );
  }
}

/// Signature of the material a proposal set was computed from.
///
/// Cheap, deterministic and content-based: if the user adds a file or edits the draft,
/// the signature changes and the cached answer is no longer presented as current.
String materialSignature(List<String> parts) {
  final joined = parts.where((p) => p.trim().isNotEmpty).join('\n\u0000\n');
  if (joined.isEmpty) return '';
  return sha1.convert(utf8.encode(joined)).toString().substring(0, 16);
}

