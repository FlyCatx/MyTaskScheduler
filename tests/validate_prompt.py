# validate_prompt.py — 静态校验运行时提示词与请求构造。
# 用途：plan.c / prompt.c / model.c 依赖 cJSON（离线无法编译）时，
#       用 Python 检查提示词正文是否覆盖全部必需约束，以及请求是否由 cJSON 构造。
import re
import ast
import io

src = io.open('src/prompt.c', encoding='utf-8').read()

# 1) 提取 SYSTEM_PROMPT 字符串
m = re.search(r'SYSTEM_PROMPT\s*=\s*(.*?);\s*\n', src, re.S)
assert m, '未找到 SYSTEM_PROMPT'
lits = re.findall(r'"(?:[^"\\]|\\.)*"', m.group(1))
system_prompt = ''.join(ast.literal_eval(s) for s in lits)
print('system 提示词长度：%d 字符' % len(system_prompt))

required = [
    ('只负责', '声明只负责分析'),
    ('绝不', '声明绝不执行'),
    ('JSON 对象', '声明输出为 JSON 对象'),
    ('Markdown', '禁止 Markdown 代码块'),
    ('不要任何其他文字', '禁止额外说明文字'),
    ('忽略以上指令', '抵御材料内注入'),
    ('不得当作', '明确材料文字不得当指令'),
    ('多个前置任务', '允许多前置'),
    ('depends_on', '依赖字段'),
    ('preconditions', '外部条件字段'),
    ('"met" / "unmet" / "unknown"', '外部条件枚举'),
    ('urgency', '紧迫性字段'),
    ('impact', '影响力字段'),
    ('estimated_hours', '工时字段'),
    ('deadline', '截止时间字段'),
    ('source_refs', '来源引用字段'),
    ('assumptions', '假设字段'),
    ('questions', '待确认字段'),
    ('schema_version', '协议版本'),
    ('已完成', '明确不得标记完成'),
    ('当前日期', '提供当前日期'),
    ('时区', '提供时区'),
    ('相对时间', '相对时间换算要求'),
    ('1~5', '评分区间'),
    ('null', '未知用 null'),
]
missing = []
for needle, desc in required:
    ok = needle in system_prompt
    print('  [%s] %s' % ('PASS' if ok else 'FAIL', desc))
    if not ok:
        missing.append(desc)
assert not missing, '提示词缺少：%s' % missing

# 2) user 提示词分段（用户要求与附件材料分开）
for needle in ['【用户要求】', '【附件材料】', '【上次输出存在问题】', '请只输出修正后的完整 JSON']:
    ok = needle in src
    print('  [%s] user/修复提示词含 %s' % ('PASS' if ok else 'FAIL', needle))
    assert ok

# 3) 请求必须由 cJSON 构造，禁止手工拼 JSON
for fn in ['cJSON_CreateObject', 'cJSON_AddStringToObject', 'cJSON_AddNumberToObject',
           'cJSON_AddBoolToObject', 'cJSON_PrintUnformatted', 'cJSON_Delete']:
    ok = fn in src
    print('  [%s] 请求构造使用 %s' % ('PASS' if ok else 'FAIL', fn))
    assert ok

# model.c 用 cJSON 解析响应外壳
model = io.open('src/model.c', encoding='utf-8').read()
assert 'cJSON_Parse' in model and 'choices' in model and 'finish_reason' in model
print('  [PASS] model.c 用 cJSON 解析 choices/message/finish_reason')

# 4) 不得关闭 TLS 校验；不得设置低速超时变相终止
def strip_c_comments(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    s = re.sub(r'//[^\n]*', '', s)
    return s

model_code = strip_c_comments(model)
assert 'CURLOPT_SSL_VERIFYPEER, 1L' in model_code, 'TLS 校验必须开启'
assert 'CURLOPT_SSL_VERIFYHOST, 2L' in model_code, '主机名校验必须开启'
assert 'CURLOPT_LOW_SPEED_LIMIT' not in model_code, '不得设置低速限制'
assert 'CURLOPT_LOW_SPEED_TIME' not in model_code, '不得设置低速时间'
assert 'CURLOPT_CONNECTTIMEOUT_MS' in model_code, '必须保留连接超时'
assert 'max_response_bytes' in model_code, '必须限制响应大小'
print('  [PASS] TLS 校验开启、无低速超时、保留连接超时与响应大小限制')

# 5) 未找到明显的手工 JSON 拼接
assert 'sprintf(' not in src, 'prompt.c 不应使用 sprintf（避免手工拼接）'
print('  [PASS] prompt.c 无 sprintf 手工拼接')

print('\n提示词与请求构造静态校验全部通过')

