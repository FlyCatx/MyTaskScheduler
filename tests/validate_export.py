# validate_export.py — 静态校验导出模块的关键约束。
# 重点：JSON 导出必须用 cJSON 构造、必须包含约定字段、绝不能写入 API Key；
#       TXT 导出必须不依赖 cJSON（这样才能离线测试）。
import re
import io

txt_src = io.open('src/export.c', encoding='utf-8').read()
json_src = io.open('src/export_json.c', encoding='utf-8').read()
hdr = io.open('src/export.h', encoding='utf-8').read()

print('== TXT 导出（export.c） ==')
assert 'cJSON.h' not in txt_src, 'export.c 不应依赖 cJSON（否则无法离线测试）'
print('  [PASS] export.c 不含 cJSON 依赖')
assert 'ts_export_write_file(path, b.data, b.len, 1' in txt_src
print('  [PASS] TXT 以 UTF-8 BOM 写出（便于记事本显示中文）')
for section in ['建议执行顺序', '受阻任务（外部条件未满足）', '待确认任务（外部条件未知）',
                '受影响任务（上游受阻或待确认）', '执行步骤', '外部条件', '排序理由',
                '完成后立即解锁', '来源引用', '模型的假设', '待确认事项', '算法版本', '排序时间']:
    assert section in txt_src, 'TXT 缺少分区/字段：%s' % section
print('  [PASS] TXT 覆盖：建议顺序/步骤/前置条件/理由/受阻/待确认/受影响/假设/待确认事项')
assert '未包含在上面的建议执行顺序中' in txt_src
print('  [PASS] 明确说明受阻任务未混入可执行序列')

print()
print('== JSON 导出（export_json.c） ==')
for fn in ['cJSON_CreateObject', 'cJSON_AddStringToObject', 'cJSON_AddNumberToObject',
           'cJSON_AddBoolToObject', 'cJSON_AddNullToObject', 'cJSON_AddItemToObject',
           'cJSON_AddItemToArray', 'cJSON_Print']:
    assert fn in json_src, 'JSON 导出未使用 ' + fn
print('  [PASS] JSON 由 cJSON 构造（不做字符串拼接）')

# 绝不写入密钥本身
assert '"api_key"' not in json_src, 'JSON 导出中不得出现 api_key 字段名'
assert 'api_key_env' in json_src, '应写入 api_key_env（仅环境变量名）'
assert 'api_key_present' in json_src, '应只写入“是否存在密钥”的布尔值'
print('  [PASS] 只写 api_key_env / api_key_present，绝不写入 API Key')

# 约定字段
need = ['schema_version', 'algorithm_version', 'exported_at', 'sorted_at',
        'config', 'weights', 'reference_hours', 'tasks', 'order',
        'blocked', 'pending', 'affected', 'assumptions', 'questions', 'summary',
        'depends_on', 'preconditions', 'steps', 'urgency', 'impact',
        'estimated_hours', 'deadline', 'source_refs',
        'actual_status', 'ready_state', 'level', 'score', 'final',
        'hours_unknown', 'chain_incomplete', 'reason', 'unlocked', 'still_waiting',
        'candidates', 'unresolvable_reason']
missing = [x for x in need if ('"%s"' % x) not in json_src]
assert not missing, 'JSON 缺少字段：%s' % missing
print('  [PASS] JSON 含完整任务数据/依赖/评分依据/权重/算法版本/协议版本/排序时间/状态快照/最终顺序')

assert 'ts_export_write_file(path, printed, strlen(printed), 0' in json_src
print('  [PASS] JSON 写出不带 BOM（避免严格解析器拒绝）')

assert 'ts_export_plan' in json_src, '格式分派应在 export_json.c（避免 TXT 侧被 cJSON 牵连）'
assert 'ts_export_plan' not in txt_src
print('  [PASS] 格式分派与 JSON 同处一个编译单元，TXT 侧保持零 cJSON 依赖')

print()
print('== export.h ==')
for name in ['ts_export_txt', 'ts_export_json', 'ts_export_plan', 'ts_export_format_from_path']:
    assert name in hdr
assert 'TS_ALGORITHM_VERSION' in hdr and 'TS_SCHEMA_VERSION' in hdr
print('  [PASS] 对外接口与算法/协议版本常量齐备')

print()
print('导出模块静态校验全部通过')

