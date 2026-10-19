#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mock_server.py — 仅用于测试的本地 OpenAI 兼容 Chat Completions 模拟服务。

用途：在**不接触真实云端**的前提下，验证 TaskScheduler 的 HTTP 层、错误分类、
限流重试、取消与“120 秒提醒”等行为。它**不是**正式软件的运行依赖，也不进入发布包。

安全约束（与需求一致）：
  * 只监听回环地址（默认 127.0.0.1；拒绝绑定非回环地址）。
  * 不使用、也不需要真实 API Key：请求里的 Authorization 头只记录“是否存在”。
  * 不保存用户材料：请求正文除长度外一律不落盘（可选记录 SHA-256 前缀用于对账）。
  * 测试结束即退出；不注册系统服务、不开机自启。

行为由“控制文件”驱动：每次请求都重新读取控制文件，因此测试可以在不重启服务的情况下
逐场景切换行为。控制文件是 JSON，字段如下：

{
  "status": 200,              # HTTP 状态码
  "headers": {"X-Test": "1"}, # 额外响应头
  "body": "…",                # 响应正文（字符串）
  "body_b64": "…",            # 响应正文（base64，用于二进制/非法 UTF-8 场景）
  "delay_ms": 0,              # “首次响应延迟”：收到请求后先等这么久再写任何字节
  "total_ms": 0,              # “完整响应时间”：从收到请求起算，总耗时不少于这么久
  "chunks": 1,                # 正文分几段写出（>1 可模拟“先到一半再等”）
  "keep_open_ms": 0,          # 写完正文后保持连接不关闭的时长（模拟挂起）
  "drop": false,              # true = 不返回任何响应，直接关闭连接（模拟网络中断）
  "request_count_file": "…",  # 可选：覆盖命令行指定的计数文件
  "malformed_header": false   # true = 额外发送一个畸形的 Retry-After 头
}

计数：每次请求都会用**原子写**更新计数文件（JSON: {"count": N, "paths": [...]}），
测试据此判断“实际发起了几次请求”，而不是靠界面文字推断。
"""

import argparse
import base64
import json
import os
import socket
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 默认响应：合法的任务 JSON（OpenAI Chat Completions 外壳）
DEFAULT_TASK_JSON = json.dumps({
    "schema_version": "1.0",
    "tasks": [
        {
            "id": "M1",
            "name": "模拟任务一",
            "depends_on": [],
            "preconditions": [],
            "steps": ["第一步", "第二步"],
            "urgency": 4,
            "urgency_reason": "截止日期临近",
            "impact": 3,
            "impact_reason": "影响后续两项任务",
            "estimated_hours": 2.0,
            "estimate_reason": "经验估计",
            "deadline": None,
            "source_refs": ["句子1"]
        },
        {
            "id": "M2",
            "name": "模拟任务二",
            "depends_on": ["M1"],
            "preconditions": [{"description": "需要审批", "status": "unknown"}],
            "steps": ["等待审批"],
            "urgency": 2,
            "urgency_reason": "可延后",
            "impact": 4,
            "impact_reason": "决定最终交付",
            "estimated_hours": None,
            "estimate_reason": None,
            "deadline": None,
            "source_refs": ["句子2"]
        }
    ],
    "assumptions": ["材料中描述的任务即为全部待办"],
    "questions": ["审批何时完成？"],
    "suggested_order": ["M1", "M2"]
}, ensure_ascii=False)

DEFAULT_ENVELOPE = json.dumps({
    "id": "chatcmpl-mock-1",
    "object": "chat.completion",
    "created": 1700000000,
    "model": "mock-model",
    "choices": [
        {
            "index": 0,
            "message": {"role": "assistant", "content": DEFAULT_TASK_JSON},
            "finish_reason": "stop"
        }
    ],
    "usage": {"prompt_tokens": 100, "completion_tokens": 200, "total_tokens": 300}
}, ensure_ascii=False)

_control_lock = threading.Lock()
_count_lock = threading.Lock()
_seq_lock = threading.Lock()


def atomic_write_json(path, obj):
    """原子写：先写临时文件再替换，避免测试读到半截 JSON。"""
    if not path:
        return
    d = os.path.dirname(os.path.abspath(path))
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def load_control(path):
    with _control_lock:
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            # 控制文件缺失/半截时退回默认行为，保证测试不会挂死
            return {}


class MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "TaskSchedulerMock/1.0"

    # ---- 日志：只记录方法、路径、正文长度，绝不记录正文内容 ----
    def log_message(self, fmt, *args):  # noqa: D401
        if self.server.verbose:
            sys.stderr.write("[mock] " + (fmt % args) + "\n")

    def _next_seq(self):
        """请求序号由**服务端**维护且单调递增。

        不能让序号取决于磁盘上的计数文件：测试会为了“按场景计数”而重置该文件，
        序号就会跟着回退，于是 r1/r2 这类“第几次请求”的覆盖参数匹配错位。
        """
        with _seq_lock:
            self.server.seq += 1
            return self.server.seq

    def _bump_count(self, ctrl, seq):
        path = ctrl.get("request_count_file") or self.server.count_file
        with _count_lock:
            entry = {"count": seq, "paths": [], "last_content_length": 0}
            try:
                with open(path, "r", encoding="utf-8") as f:
                    prev = json.load(f)
                # 保留路径历史（便于对账），但 count 以服务端序号为准
                entry["paths"] = list(prev.get("paths", []))
            except (OSError, ValueError):
                pass
            entry["count"] = seq
            entry.setdefault("paths", []).append(self.path)
            entry["last_content_length"] = int(self.headers.get("Content-Length", 0) or 0)
            entry["auth_present"] = bool(self.headers.get("Authorization"))
            atomic_write_json(path, entry)

    def do_GET(self):
        ctrl = load_control(self.server.control_file)
        seq = self._next_seq()
        self._bump_count(ctrl, seq)
        body = b'{"status":"mock-server-ok"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        ctrl = load_control(self.server.control_file)
        length = int(self.headers.get("Content-Length", 0) or 0)
        # 读取请求体：仅在显式开启请求追踪时保留（供测试核对“修复请求确实发出”），
        # 默认只统计长度，绝不落盘。
        body_in = b""
        if length > 0:
            remaining = length
            chunks_in = []
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                remaining -= len(chunk)
                if self.server.trace_request_file:
                    chunks_in.append(chunk)
            if self.server.trace_request_file:
                body_in = b"".join(chunks_in)

        self._bump_count(ctrl, self._next_seq())

        start = time.monotonic()

        # ---- 按“第几次请求”覆盖参数（用于确定性地测试重试/修复路径）----
        # 服务端序号是**单调累计**的（跨场景不重置），因此测试会通过
        # control 文件里的 seq_offset 告诉服务端“本次场景的第 1 次请求”是哪个序号，
        # 这样 rN_* 覆盖才能稳定对应“本场景的第 N 次请求”，且不需要重置任何文件。
        try:
            seq_offset = int(ctrl.get("seq_offset", 0) or 0)
        except (TypeError, ValueError):
            seq_offset = 0
        seq = self.server.seq - seq_offset
        if seq < 1:
            seq = 1
        overrides = {}
        req_map = ctrl.get("requests") or {}
        if isinstance(req_map, dict):
            for key in ("status", "body", "body_b64", "body_file", "delay_ms",
                        "total_ms", "chunks", "keep_open_ms", "drop", "headers"):
                k = "r%d_%s" % (seq, key)
                if k in ctrl:
                    overrides[key] = ctrl[k]
            per = req_map.get(str(seq))
            if isinstance(per, dict):
                overrides.update(per)

        def p(name):
            """本请求的有效参数：按请求覆盖 > 顶层设置 > 内置默认。"""
            if name in overrides:
                return overrides[name]
            return ctrl.get(name)

        if p("drop"):
            # 模拟网络中断：不发响应直接关闭
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.close_connection = True
            return

        delay_ms = int(p("delay_ms") or 0)
        total_ms = int(p("total_ms") or 0)
        chunks = max(1, int(p("chunks") or 1))
        keep_open_ms = int(p("keep_open_ms") or 0)

        body_b64 = p("body_b64")
        body_val = p("body")
        body_file = p("body_file")
        if body_b64:
            body = base64.b64decode(body_b64)
        elif body_file:
            # 直接读取原始字节：测试夹具可以原样写入正文，无需任何 JSON 转义层，
            # 避免“C 字面量 + 控制文件 JSON + 外壳 content”多层转义出错。
            with open(body_file, "rb") as fp:
                body = fp.read()
        elif body_val is not None:
            body = str(body_val).encode("utf-8")
        else:
            body = DEFAULT_ENVELOPE.encode("utf-8")

        # “首次响应延迟”：在写任何字节之前等待
        if delay_ms > 0:
            time.sleep(delay_ms / 1000.0)

        status = int(p("status") or 200)
        self.send_response(status)
        hdrs = p("headers")
        if not isinstance(hdrs, dict):
            hdrs = {}
        hdrs = dict(hdrs)
        hdrs.setdefault("Content-Type", "application/json; charset=utf-8")
        for k, v in hdrs.items():
            self.send_header(str(k), str(v))
        if ctrl.get("extra_headers"):
            for k, v in (ctrl["extra_headers"] or {}).items():
                self.send_header(str(k), str(v))
        if ctrl.get("malformed_header"):
            # 畸形 Retry-After：客户端必须忽略而不是照着等
            self.send_header("Retry-After", "")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()

        # 把“本次请求实际使用的正文”写到旁路文件，便于测试对账
        # （例如确认客户端发出的确实是修复请求）。默认不记录，
        # 只有测试显式传入 --trace 时才写。
        try:
            trace = self.server.trace_file
            if trace:
                entry = {"seq": seq, "status": status, "body": body.decode("utf-8", "replace"),
                         "content_length": len(body)}
                atomic_write_json(trace, entry)
            treq = self.server.trace_request_file
            if treq:
                # 鉴权头的“形状”标记：只记录数量与布尔判断，
                # 绝不把 Authorization / API Key 的值写入任何文件。
                auth_vals = self.headers.get_all("Authorization") or []
                bearer_ok = False
                if len(auth_vals) == 1:
                    v = auth_vals[0]
                    bearer_ok = (
                        len(v) > 7
                        and v[:7].lower() == "bearer "
                        and "\r" not in v and "\n" not in v
                    )
                atomic_write_json(treq, {
                    "seq": seq,
                    "request_bytes": len(body_in),
                    # 只保留便于对账的标记，不保留用户材料全文
                    "has_repair_marker": ("上次输出存在问题" in body_in.decode("utf-8", "replace")),
                    "has_error_marker": ("校验错误" in body_in.decode("utf-8", "replace")),
                    "auth_present": bool(self.headers.get("Authorization")),
                    "auth_header_count": len(auth_vals),
                    "auth_bearer_shape_ok": bearer_ok,
                })
        except (OSError, ValueError):
            pass

        # 分段写出正文，并按 total_ms 把“完整响应时间”真正铺开。
        # 注意：如果只按 chunks 分段、且 total_ms 较大而 chunks 为 1，
        # 正文会在瞬间写完，total_ms 就形同虚设——那样无法验证“客户端在总超时禁用时
        # 能否等到一个慢响应的**完整**结果”。因此这里按 total_ms 推算分段数。
        total_s = max(0.0, total_ms / 1000.0)
        if total_s > 0 and body:
            # 每段至少间隔 20ms，避免产生成千上万次写操作
            eff_chunks = max(chunks, min(200, int(total_s / 0.02) or 1))
        else:
            eff_chunks = chunks
        share = max(1, -(-len(body) // eff_chunks)) if body else 1
        deadline = start + total_s
        pos = 0
        if body:
            while True:
                nxt = min(len(body), pos + share)
                piece = body[pos:nxt]
                if piece:
                    try:
                        self.wfile.write(piece)
                        self.wfile.flush()
                    except OSError:
                        self.close_connection = True
                        return
                pos = nxt
                if pos >= len(body):
                    break
                target = start + total_s * (pos / max(1, len(body)))
                now = time.monotonic()
                if target > now:
                    time.sleep(min(target - now, 0.5))
        now = time.monotonic()
        if deadline > now:
            time.sleep(deadline - now)

        if keep_open_ms > 0:
            time.sleep(keep_open_ms / 1000.0)
        self.close_connection = True


class MockServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, control_file, count_file, trace_file,
                 trace_request_file, verbose):
        super().__init__(addr, handler)
        self.control_file = control_file
        self.count_file = count_file
        self.trace_file = trace_file
        self.trace_request_file = trace_request_file
        self.verbose = verbose
        self.seq = 0        # 服务端权威的请求序号（单调递增，永不重置）


def main():
    ap = argparse.ArgumentParser(description="TaskScheduler 测试用本地模拟 HTTP 服务")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="0 = 由系统分配空闲端口")
    ap.add_argument("--control", required=True, help="行为控制文件路径")
    ap.add_argument("--count", required=True, help="请求计数文件路径")
    ap.add_argument("--port-file", required=True, help="把实际监听端口写入此文件")
    ap.add_argument("--trace", default="", help="可选：记录每次响应正文的旁路文件")
    ap.add_argument("--trace-request", default="",
                    help="可选：记录每次请求的对账标记（不含用户材料全文）")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    # 安全约束：只允许回环地址
    if args.host not in ("127.0.0.1", "::1", "localhost"):
        sys.stderr.write("拒绝绑定非回环地址：%s\n" % args.host)
        return 2

    atomic_write_json(args.control, {"status": 200, "body": DEFAULT_ENVELOPE})
    atomic_write_json(args.count, {"count": 0, "paths": []})

    srv = MockServer((args.host, args.port), MockHandler,
                     args.control, args.count, args.trace, args.trace_request,
                     args.verbose)
    port = srv.server_address[1]
    atomic_write_json(args.port_file, {"port": port, "host": args.host})
    sys.stderr.write("[mock] listening on http://%s:%d/ (control=%s)\n"
                     % (args.host, port, args.control))
    sys.stderr.flush()
    try:
        srv.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

