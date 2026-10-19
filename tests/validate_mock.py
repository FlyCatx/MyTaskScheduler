# validate_mock.py — 校验 model.c 内置 mock JSON 与 config.example.json。
# 用途：在无法编译 C 的 plan.c（依赖 cJSON）时，用 Python 验证 mock 数据符合协议。
import re
import ast
import json
import io

# 1) 从 model.c 提取并校验内置 mock JSON
src = io.open('src/model.c', encoding='utf-8').read()
m = re.search(r'MOCK_JSON\s*=\s*(.*?);\s*\n', src, re.S)
assert m, '未找到 MOCK_JSON'
body = m.group(1)
lits = re.findall(r'"(?:[^"\\]|\\.)*"', body)
joined = ''.join(ast.literal_eval(s) for s in lits)
data = json.loads(joined)

print('mock JSON 解析成功, schema_version =', data['schema_version'])
print('task 数量 =', len(data['tasks']))

# 协议要求这些字段【必须出现】（没有内容时显式写 [] 或 null）。
# 与 plan.c 的 require_field() 保持一致：内置 mock 也必须满足，否则 mock 模式会解析失败。
required = ['id', 'name', 'depends_on', 'preconditions', 'steps',
            'urgency', 'urgency_reason', 'impact', 'impact_reason',
            'estimated_hours', 'estimate_reason', 'deadline', 'source_refs']
all_ids = [t['id'] for t in data['tasks']]
ids = set()
for i, t in enumerate(data['tasks']):
    for f in required:
        assert f in t, 'tasks[%d] 缺少 %s' % (i, f)
    assert t['id'] not in ids, 'ID 重复 ' + t['id']
    ids.add(t['id'])
    assert 1 <= t['urgency'] <= 5 and 1 <= t['impact'] <= 5
    for d in t.get('depends_on', []):
        assert d in all_ids, '任务 %s 依赖不存在的 %s' % (t['id'], d)
    for p in t.get('preconditions', []):
        assert p['status'] in ('met', 'unmet', 'unknown')
    if t.get('estimated_hours') is not None:
        assert t['estimated_hours'] > 0, '工时必须为正'
print('所有任务字段校验通过')
for t in data['tasks']:
    print('  %-3s deps=%-12s precond=%-14s hours=%s' % (
        t['id'], str(t.get('depends_on', [])),
        str([p['status'] for p in t.get('preconditions', [])]),
        t.get('estimated_hours')))

# 2) 校验 config.example.json
cfg = json.load(io.open('config.example.json', encoding='utf-8'))
w = cfg['weights']
assert abs(sum(w.values()) - 1.0) < 1e-9, '权重和 != 1'
print()
print('config.example.json 校验通过, 权重和 =', round(sum(w.values()), 4))
print('全部通过')

