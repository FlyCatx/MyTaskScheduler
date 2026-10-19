#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_mock_responses.py — 生成 HTTP 集成测试用的响应正文夹具。

夹具是**测试数据**，不是运行依赖；生成一次后随仓库保存，测试运行时不执行本脚本
（避免测试依赖 Python）。如需重建：

    python tests/gen_mock_responses.py

每个夹具是一个文件，内容为“模型输出”（即 Chat Completions 的 content 正文）。
test_http_integration.c 会读取它、做 JSON 字符串转义，再包进 OpenAI 兼容的响应外壳。
"""

import io
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data", "mock_responses")


def task(tid, name, deps, preconds, steps, urgency, impact, hours,
         src=("句子1",)):
    return {
        "id": tid,
        "name": name,
        "depends_on": list(deps),
        "preconditions": [{"description": d, "status": s} for d, s in preconds],
        "steps": list(steps),
        "urgency": urgency,
        "urgency_reason": "%s 的紧迫性理由" % tid,
        "impact": impact,
        "impact_reason": "%s 的影响力理由" % tid,
        "estimated_hours": hours,
        "estimate_reason": None if hours is None else "经验估计",
        "deadline": None,
        "source_refs": list(src),
    }


def envelope(content):
    """把模型输出包成 OpenAI 兼容响应外壳（仅用于生成夹具时的自检）。"""
    return {
        "id": "chatcmpl-fixture",
        "object": "chat.completion",
        "model": "mock-model",
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": content},
            "finish_reason": "stop",
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30},
    }


FIXTURES = {}

# 1) 完整合法的两任务计划
FIXTURES["valid_tasks.json"] = json.dumps({
    "schema_version": "1.0",
    "tasks": [
        task("M1", "整理需求", [], [("已获得材料", "met")], ["通读材料", "列出清单"],
             4, 5, 2.0),
        task("M2", "搭建骨架", ["M1"], [], ["创建目录", "配置构建"],
             3, 4, None, src=("句子2",)),
    ],
    "assumptions": ["材料即为全部待办"],
    "questions": ["API Key 何时就绪？"],
    "suggested_order": ["M1", "M2"],
}, ensure_ascii=False, indent=2)

# 2) 单任务、最小合法结构
FIXTURES["minimal_tasks.json"] = json.dumps({
    "schema_version": "1.0",
    "tasks": [task("M1", "唯一任务", [], [], ["唯一一步"], 3, 3, 1.0)],
    "assumptions": [],
    "questions": [],
    "suggested_order": ["M1"],
}, ensure_ascii=False, indent=2)

# 3) 缺失必需字段（depends_on / preconditions / steps 全部省略）
_no_fields = {
    "schema_version": "1.0",
    "tasks": [{
        "id": "M1",
        "name": "缺字段任务",
        "urgency": 3,
        "urgency_reason": "r",
        "impact": 3,
        "impact_reason": "r",
        "estimated_hours": 1.0,
        "estimate_reason": "r",
        "deadline": None,
        "source_refs": [],
    }],
}
FIXTURES["missing_required_fields.json"] = json.dumps(_no_fields, ensure_ascii=False,
                                                      indent=2)

# 4) 合法 JSON 但业务非法（依赖指向不存在的任务）
FIXTURES["invalid_business.json"] = json.dumps({
    "schema_version": "1.0",
    "tasks": [
        task("M1", "任务一", ["NOPE"], [], ["一步"], 3, 3, 1.0),
    ],
}, ensure_ascii=False, indent=2)

# 5) 非法 JSON（截断的对象）
FIXTURES["invalid_json.txt"] = '{"schema_version": "1.0", "tasks": [{"id": "M1",'

# 6) 大正文（用于响应大小上限测试；约 512 KiB）
FIXTURES["large_body.txt"] = json.dumps({
    "schema_version": "1.0",
    "tasks": [task("M1", "大响应任务", [], [], ["一步"], 3, 3, 1.0)],
    "assumptions": ["填充 " + ("x" * 512) for _ in range(1000)],
}, ensure_ascii=False)

# 7) 空壳：choices 存在但 content 为空串
FIXTURES["empty_content.json"] = ""


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, content in FIXTURES.items():
        path = os.path.join(OUT, name)
        with io.open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print("wrote %-32s %7d bytes" % (name, len(content.encode("utf-8"))))

    # 自检：除故意非法的之外，其余必须能被 json.loads 解析
    for name, content in FIXTURES.items():
        if name in ("invalid_json.txt", "empty_content.json"):
            continue
        json.loads(content)
    print("自检通过：合法夹具均可被 JSON 解析")


if __name__ == "__main__":
    main()

