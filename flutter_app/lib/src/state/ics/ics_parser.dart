// RFC 5545 内容行解析（iCalendar / ICS）。
//
// 这一层只负责“文本 → 组件树”，不解释任何时间语义：
//   * 折叠行展开：续行以空格或 TAB 开头，去掉这一个前导字符后拼到上一行；
//   * 内容行：`NAME *(";" param) ":" value`，参数值可以是带引号的字符串，
//     引号里允许出现 `:`、`;`、`,`，同一个参数可以有多个逗号分隔的值；
//   * 参数值的 RFC 6868 转义（`^n` / `^^` / `^'`）；
//   * TEXT 值的 RFC 5545 转义（`\\` `\;` `\,` `\n`，见 [unescapeText]）；
//   * UTF-8 BOM、`\r\n`、`\n`、单独的 `\r` 都接受；
//   * BEGIN/END 必须正确嵌套；名字大小写不敏感，统一转大写。
//
// 这里刻意不用正则、也不用 `split(':')`：参数里带引号的 `:` / `;` / `,`
// 会让这两种写法直接出错（真实导出器里 TZID 与 X- 参数都可能带引号）。
//
// 解析出的树由 ics_event_extractor.dart 解释；本层不做时间判断，也不修改原文件。

/// 一条内容行（RFC 5545 §3.1）。
class IcalProperty {
  IcalProperty({
    required this.name,
    required Map<String, List<String>> parameters,
    required this.value,
    required this.line,
  }) : parameters = Map<String, List<String>>.unmodifiable(
          parameters.map(
            (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
          ),
        );

  /// 大写属性名（如 `DTSTART`）。
  final String name;

  /// 大写参数名 → 值列表（同名参数多次出现时合并）。
  final Map<String, List<String>> parameters;

  /// 冒号之后的原始值（TEXT 类型需再经过 [unescapeText]）。
  final String value;

  /// 该逻辑行在文件中的起始行号（1 起）。
  final int line;

  /// 参数的第一项；不存在返回 null。
  String? parameter(String key) {
    final values = parameters[key.toUpperCase()];
    if (values == null || values.isEmpty) return null;
    return values.first;
  }

  /// 参数的所有值（含多值参数）；不存在返回空列表。
  List<String> parameterValues(String key) =>
      parameters[key.toUpperCase()] ?? const <String>[];

  /// 参数是否存在（即使值为空）。
  bool hasParameter(String key) => parameters.containsKey(key.toUpperCase());

  /// 值去掉首尾空白后的形式。
  String get trimmedValue => value.trim();

  @override
  String toString() => 'IcalProperty($name@$line=${value.length > 40 ? '${value.substring(0, 40)}…' : value})';
}

/// 一个组件（VCALENDAR / VEVENT / VTIMEZONE / VALARM / …）。
class IcalComponent {
  IcalComponent({
    required this.name,
    required List<IcalProperty> properties,
    required List<IcalComponent> children,
  })  : properties = List<IcalProperty>.unmodifiable(properties),
        children = List<IcalComponent>.unmodifiable(children);

  /// 大写组件名。
  final String name;
  final List<IcalProperty> properties;
  final List<IcalComponent> children;

  /// 第一个同名属性（大小写不敏感）。
  IcalProperty? property(String name) {
    final upper = name.toUpperCase();
    for (final property in properties) {
      if (property.name == upper) return property;
    }
    return null;
  }

  /// 所有同名属性。
  List<IcalProperty> propertiesNamed(String name) {
    final upper = name.toUpperCase();
    return properties.where((p) => p.name == upper).toList(growable: false);
  }

  /// 第一条同名属性的值；不存在返回 null。
  String? valueOf(String name) => property(name)?.value;

  /// 直接子组件。
  List<IcalComponent> childrenNamed(String name) {
    final upper = name.toUpperCase();
    return children.where((c) => c.name == upper).toList(growable: false);
  }

  /// 自身及所有后代中名为 [name] 的组件（深度优先，顺序稳定）。
  ///
  /// 用它可以容忍“VEVENT 直接位于文件顶层”或“多个 VCALENDAR”这类不规范
  /// 但真实存在的导出结果。
  List<IcalComponent> allNamed(String name) {
    final upper = name.toUpperCase();
    final out = <IcalComponent>[];
    void walk(IcalComponent component) {
      if (component.name == upper) out.add(component);
      for (final child in component.children) {
        walk(child);
      }
    }

    walk(this);
    return out;
  }

  @override
  String toString() =>
      'IcalComponent($name, ${properties.length} props, ${children.length} children)';
}

/// ICS 文本不合法。message 面向用户，line 便于定位。
class IcsParseException implements Exception {
  const IcsParseException(this.message, this.line);

  final String message;
  final int line;

  @override
  String toString() => line > 0 ? 'ICS 解析失败（第 $line 行）：$message' : 'ICS 解析失败：$message';
}

/// 解析整份 ICS 文本，返回根组件。
///
/// * 只有一个顶层组件时原样返回（通常是 VCALENDAR）；
/// * 出现多个顶层组件时，返回一个合成的 `VCALENDAR` 容器，其 children 是
///   全部顶层组件——调用方用 [IcalComponent.allNamed] 仍能找到所有 VEVENT；
/// * 结构错误（属性落在组件外、END 与 BEGIN 不匹配、组件未闭合、根组件结束
///   后还有内容）抛 [IcsParseException]。
IcalComponent parseIcs(String text) {
  final stripped =
      text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? text.substring(1) : text;
  if (stripped.trim().isEmpty) {
    throw const IcsParseException('文件为空，没有任何 iCalendar 内容', 0);
  }
  final logicalLines = _unfoldLines(text);
  if (logicalLines.isEmpty) {
    throw const IcsParseException('文件为空，没有任何 iCalendar 内容', 0);
  }

  final root = <IcalComponent>[];
  final stack = <_ComponentBuilder>[];

  for (final entry in logicalLines) {
    final line = entry.text;
    if (line.trim().isEmpty) continue;
    final property = _parseContentLine(line, entry.line);
    if (property.name == 'BEGIN') {
      final componentName = property.trimmedValue.toUpperCase();
      if (componentName.isEmpty) {
        throw IcsParseException('BEGIN 缺少组件名', entry.line);
      }
      stack.add(_ComponentBuilder(componentName, entry.line));
      continue;
    }
    if (property.name == 'END') {
      final componentName = property.trimmedValue.toUpperCase();
      if (stack.isEmpty) {
        throw IcsParseException('END:$componentName 没有对应的 BEGIN', entry.line);
      }
      final builder = stack.removeLast();
      if (builder.name != componentName) {
        throw IcsParseException(
          'END:$componentName 与 BEGIN:${builder.name} 不匹配（BEGIN 在第 ${builder.startLine} 行）',
          entry.line,
        );
      }
      final component = builder.build();
      if (stack.isEmpty) {
        root.add(component);
      } else {
        stack.last.children.add(component);
      }
      continue;
    }
    if (stack.isEmpty) {
      throw IcsParseException('属性 ${property.name} 落在任何组件之外', entry.line);
    }
    stack.last.properties.add(property);
  }

  if (stack.isNotEmpty) {
    throw IcsParseException(
      '组件 ${stack.last.name} 没有闭合（BEGIN 在第 ${stack.last.startLine} 行）',
      logicalLines.last.line,
    );
  }
  if (root.isEmpty) {
    throw const IcsParseException('没有解析到任何 iCalendar 组件', 0);
  }
  if (root.length == 1) return root.first;
  // 多个顶层组件：包一层合成 VCALENDAR，保持 children 顺序。
  return IcalComponent(
    name: 'VCALENDAR',
    properties: const <IcalProperty>[],
    children: root,
  );
}

/// 展开 RFC 5545 的 TEXT 值转义：`\\` `\;` `\,` `\n`（以及常见的 `\N`）。
///
/// 未知转义（如 `\: `）保留被转义的字符本身，不把反斜杠泄漏给用户。
String unescapeText(String raw) {
  if (!raw.contains(r'\')) return raw;
  final out = StringBuffer();
  var i = 0;
  while (i < raw.length) {
    final char = raw[i];
    if (char != r'\' || i + 1 >= raw.length) {
      out.write(char);
      i++;
      continue;
    }
    final next = raw[i + 1];
    switch (next) {
      case 'n':
      case 'N':
        out.write('\n');
      case r'\':
        out.write(r'\');
      case ';':
        out.write(';');
      case ',':
        out.write(',');
      default:
        // 非标准转义：丢掉反斜杠，保留字符本身。
        out.write(next);
    }
    i += 2;
  }
  return out.toString();
}

// ------------------------------------------------------------------ internals

class _PendingLine {
  const _PendingLine(this.line, this.text);
  final int line;
  final String text;
}

class _ComponentBuilder {
  _ComponentBuilder(this.name, this.startLine);
  final String name;
  final int startLine;
  final List<IcalProperty> properties = <IcalProperty>[];
  final List<IcalComponent> children = <IcalComponent>[];

  IcalComponent build() => IcalComponent(
        name: name,
        properties: properties,
        children: children,
      );
}

/// 按 RFC 5545 §3.1 展开折叠行，并按 `\r\n` / `\n` / `\r` 切分物理行。
List<_PendingLine> _unfoldLines(String text) {
  var source = text;
  if (source.isNotEmpty && source.codeUnitAt(0) == 0xFEFF) {
    source = source.substring(1); // UTF-8 BOM
  }
  final out = <_PendingLine>[];
  StringBuffer? current;
  var currentLine = 0;

  void flush() {
    if (current == null) return;
    out.add(_PendingLine(currentLine, current.toString()));
    current = null;
  }

  var index = 0;
  var lineNumber = 1;
  while (index <= source.length) {
    // 取一行（不含行尾）。
    final start = index;
    while (index < source.length &&
        source.codeUnitAt(index) != 0x0A &&
        source.codeUnitAt(index) != 0x0D) {
      index++;
    }
    final raw = source.substring(start, index);
    // 跳过行尾：\r\n 算一个，单独的 \r / \n 各自算一个。
    if (index < source.length) {
      if (source.codeUnitAt(index) == 0x0D) {
        index++;
        if (index < source.length && source.codeUnitAt(index) == 0x0A) index++;
      } else {
        index++;
      }
    }
    final isContinuation = raw.isNotEmpty &&
        (raw.codeUnitAt(0) == 0x20 || raw.codeUnitAt(0) == 0x09);
    if (isContinuation) {
      if (current == null) {
        throw IcsParseException('折叠行（以空格/TAB 开头）前面没有内容行', lineNumber);
      }
      current!.write(raw.substring(1));
    } else {
      flush();
      current = StringBuffer(raw);
      currentLine = lineNumber;
    }
    lineNumber++;
    if (index >= source.length) break;
  }
  flush();
  return out;
}

/// `NAME *(";" param) ":" value`，参数值可用双引号包裹并含 `:` `;` `,`。
IcalProperty _parseContentLine(String line, int lineNumber) {
  var index = 0;

  // 组名可带前缀（`group.NAME`），取最后一个点之后的部分作为属性名。
  while (index < line.length &&
      line.codeUnitAt(index) != 0x3B && // ;
      line.codeUnitAt(index) != 0x3A) {
    // :
    index++;
  }
  if (index >= line.length) {
    throw IcsParseException('内容行缺少冒号：$line', lineNumber);
  }
  var name = line.substring(0, index).trim();
  final dot = name.lastIndexOf('.');
  if (dot >= 0) name = name.substring(dot + 1);
  name = name.toUpperCase();
  if (name.isEmpty) {
    throw IcsParseException('内容行缺少属性名：$line', lineNumber);
  }

  final parameters = <String, List<String>>{};
  while (index < line.length && line.codeUnitAt(index) == 0x3B) {
    index++; // ;
    final nameStart = index;
    while (index < line.length &&
        line.codeUnitAt(index) != 0x3D && // =
        line.codeUnitAt(index) != 0x3B &&
        line.codeUnitAt(index) != 0x3A) {
      index++;
    }
    if (index >= line.length || line.codeUnitAt(index) != 0x3D) {
      throw IcsParseException('参数缺少等号：$line', lineNumber);
    }
    final parameterName = line.substring(nameStart, index).trim().toUpperCase();
    if (parameterName.isEmpty) {
      throw IcsParseException('参数缺少名字：$line', lineNumber);
    }
    index++; // =
    final values = <String>[];
    while (true) {
      if (index < line.length && line.codeUnitAt(index) == 0x22) {
        // 带引号的参数值：内部的 `:` `;` `,` 都是普通字符。
        index++;
        final buffer = StringBuffer();
        var closed = false;
        while (index < line.length) {
          final code = line.codeUnitAt(index);
          if (code == 0x22) {
            closed = true;
            index++;
            break;
          }
          buffer.writeCharCode(code);
          index++;
        }
        if (!closed) {
          throw IcsParseException('参数引号没有闭合：$line', lineNumber);
        }
        values.add(_decodeCaretEscapes(buffer.toString()));
      } else {
        final valueStart = index;
        while (index < line.length &&
            line.codeUnitAt(index) != 0x2C && // ,
            line.codeUnitAt(index) != 0x3B && // ;
            line.codeUnitAt(index) != 0x3A) {
          // :
          index++;
        }
        values.add(line.substring(valueStart, index));
      }
      if (index < line.length && line.codeUnitAt(index) == 0x2C) {
        index++; // ,
        continue;
      }
      break;
    }
    parameters.putIfAbsent(parameterName, () => <String>[]).addAll(values);
  }

  if (index >= line.length || line.codeUnitAt(index) != 0x3A) {
    throw IcsParseException('内容行缺少冒号：$line', lineNumber);
  }
  index++; // :
  final value = line.substring(index);
  return IcalProperty(
    name: name,
    parameters: parameters,
    value: value,
    line: lineNumber,
  );
}

/// RFC 6868 参数值转义：`^n` 换行、`^^` → `^`、`^'` → `"`。
String _decodeCaretEscapes(String raw) {
  if (!raw.contains('^')) return raw;
  final out = StringBuffer();
  var i = 0;
  while (i < raw.length) {
    final char = raw[i];
    if (char == '^' && i + 1 < raw.length) {
      switch (raw[i + 1]) {
        case 'n':
        case 'N':
          out.write('\n');
        case '^':
          out.write('^');
        case "'":
          out.write('"');
        default:
          out.write(char);
          out.write(raw[i + 1]);
      }
      i += 2;
      continue;
    }
    out.write(char);
    i++;
  }
  return out.toString();
}
