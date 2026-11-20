"""Writes test/chat/fixtures/follow_run_info.jsonl (run from app/:
`python3 test/chat/fixtures/make_follow_run_info.py test/chat/fixtures/follow_run_info.jsonl`): a synthetic two-turn
session in DSH 0.2 follow-frame shape with realistic timing (step markers,
timed assistant streams, an approval wait, todo writes, usage)."""
import difflib, json, sys

T0 = 1792720800000  # fixed epoch ms
WS = "/root/workspace"
seq = 0
lines_out = []

def ev(t, typ, data):
    global seq
    e = {"type": typ, "seq": seq, "time": T0 + t, "data": data}
    seq += 1
    return e

def hunks(before, after, n=3):
    a = before.split("\n"); b = after.split("\n")
    out = []
    for group in difflib.SequenceMatcher(None, a, b).get_grouped_opcodes(n):
        old, new = [], []
        for tag, i1, i2, j1, j2 in group:
            if tag == "equal":
                old += a[i1:i2]; new += b[j1:j2]
            else:
                old += a[i1:i2]; new += b[j1:j2]
        out.append({"oldText": "\n".join(old) if old else None, "newText": "\n".join(new)})
    return out

def stream(t_start, ttft, reasoning, text, tool_ms):
    """Compact stream records: reasoning, then text, then tool-call args."""
    recs = []
    t = t_start + ttft
    if reasoning:
        parts = [reasoning[i:i+6] for i in range(0, len(reasoning), 6)]
        dt = [45] * (len(parts) - 1)
        recs.append({"type": "reasoning-chunks", "index": 0, "time0": T0 + t, "texts": parts, "dt": dt})
        t += 45 * len(parts)
    if text:
        parts = [text[i:i+4] for i in range(0, len(text), 4)]
        dt = [30] * (len(parts) - 1)
        recs.append({"type": "text-chunks", "index": 1, "time0": T0 + t, "texts": parts, "dt": dt})
        t += 30 * len(parts)
    if tool_ms:
        recs.append({"type": "tool-call-chunks", "index": 2, "id": "x", "name": "x", "time0": T0 + t, "args": ["{", "}"], "dt": [tool_ms]})
    return recs

def message(t, turn, step, mid, text, reasoning, calls, usage, rec):
    content = []
    if reasoning: content.append({"type": "reasoning", "text": reasoning})
    if text: content.append({"type": "text", "text": text})
    for cid, name, args in calls:
        content.append({"type": "tool-call", "id": cid, "name": name, "arguments": json.dumps(args, ensure_ascii=False)})
    return ev(t, "assistant/message", {
        "turn": turn, "step": step,
        "message": {"id": mid, "role": "assistant", "content": content,
                    "source": {"kind": "llm", "provider": "deepseek-official", "model": "deepseek-flash"}},
        "usage": usage, "stream": rec})

def call(t, turn, step, cid, name, args):
    return ev(t, "tool/call", {"turn": turn, "step": step, "callId": cid, "name": name, "arguments": json.dumps(args, ensure_ascii=False)})

def result(t, turn, step, cid, text, meta=None, error=False):
    d = {"turn": turn, "step": step, "message": {"id": "r-" + cid, "role": "tool", "source": {"kind": "tool", "callId": cid},
         "toolCallId": cid, "content": [{"type": "text", "text": text}], "isError": error}}
    if meta is not None: d["meta"] = meta
    return ev(t, "tool/result", d)

def usage(unc, hit, out, reasoning=None):
    u = {"inputTokens": unc, "outputTokens": out, "cacheReadTokens": hit, "cacheWriteTokens": 0, "totalTokens": unc + hit + out}
    if reasoning is not None: u["reasoningTokens"] = reasoning
    return u

CONTROLLER = """import 'auth_api.dart';
import 'login_state.dart';

class LoginController {
  LoginController(this._api);

  final AuthApi _api;
  bool _submitting = false;
  LoginState state = const LoginState.idle();

  Future<void> submit(String email, String password) async {
    final result = await _api.login(email, password);
    _submitting = false;
    state = result;
  }

  void reset() => state = const LoginState.idle();
}"""
CONTROLLER2 = CONTROLLER.replace("""  Future<void> submit(String email, String password) async {
    final result = await _api.login(email, password);
    _submitting = false;
    state = result;
  }""", """  Future<void> submit(String email, String password) async {
    if (_submitting) return;
    _submitting = true;
    try {
      state = await _api.login(email, password);
    } finally {
      _submitting = false;
    }
  }""")
TEST = """import 'package:flutter_test/flutter_test.dart';

import '../../lib/auth/login_controller.dart';
import 'fake_auth_api.dart';

void main() {
  test('a second tap while submitting is ignored', () async {
    final api = FakeAuthApi(delay: const Duration(milliseconds: 50));
    final controller = LoginController(api);
    final first = controller.submit('a@b.c', 'pw');
    await controller.submit('a@b.c', 'pw');
    await first;
    expect(api.calls, 1);
  });
}"""
README = """# Login demo

A tiny Flutter login demo.

## Run

flutter run"""
README2 = README.replace("## Run\n\nflutter run", "## Run\n\nflutter pub get\nflutter run\n\n## Test\n\nflutter test")

OLD_SUBMIT = """    final result = await _api.login(email, password);
    _submitting = false;
    state = result;"""
NEW_SUBMIT = """    if (_submitting) return;
    _submitting = true;
    try {
      state = await _api.login(email, password);
    } finally {
      _submitting = false;
    }"""
EDIT1 = {"file_path": f"{WS}/app/lib/auth/login_controller.dart", "old_string": OLD_SUBMIT, "new_string": NEW_SUBMIT}
EDIT2 = {"file_path": f"{WS}/README.md", "old_string": "flutter run", "new_string": "flutter pub get\nflutter run\n\n## Test\n\nflutter test"}

def read_meta(path, text):
    return {"path": path, "offset": 1, "lines": [{"number": i + 1, "text": l} for i, l in enumerate(text.split("\n"))], "lang": "dart"}

TODOS1 = [{"content": "找到重复提交的原因", "status": "completed"}, {"content": "给提交加锁", "status": "in_progress"}, {"content": "补一个连点测试", "status": "pending"}]
TODOS2 = [dict(t, status="completed") for t in TODOS1]
TODOS3 = TODOS2 + [{"content": "更新 README 的运行说明", "status": "in_progress"}, {"content": "跑一遍测试确认", "status": "pending"}]
TODOS4 = TODOS2 + [{"content": "更新 README 的运行说明", "status": "completed"}, {"content": "跑一遍测试确认", "status": "in_progress"}]

events = []
E = events.append
E(ev(-5000, "permission/preset", {"preset": "workspace-write"}))
E(ev(-5000, "approval/policy", {"policy": "ask"}))
E(ev(-4990, "model/selection", {"provider": "deepseek-official", "model": "deepseek-flash", "reasoningEffort": "high"}))
E(ev(-10, "session/title", {"title": "修复登录重复提交", "source": {"kind": "provider"}}))
# ---- turn 1
E(ev(0, "turn/start", {"turn": 1}))
E(ev(2, "user/message", {"id": "u-1", "role": "user", "content": [{"type": "text", "text": "登录按钮连点会重复提交,帮我修一下,顺便补个测试。"}], "source": {"kind": "user", "rpcId": "rpc-1"}}))
E(ev(60, "step/start", {"turn": 1, "step": 1}))
r1 = "用户说登录会重复提交。先读 login_controller.dart,再搜一下 submit 的调用点。"
E(message(3260, 1, 1, "m-1-1", "先看看登录控制器和调用点。", r1,
          [("c-read", "read", {"file_path": f"{WS}/app/lib/auth/login_controller.dart"}),
           ("c-grep", "grep", {"pattern": "submit\\(", "path": f"{WS}/app/lib"})],
          usage(4210, 8960, 286, 190), stream(60, 1100, r1, "先看看登录控制器和调用点。", 300)))
E(call(3270, 1, 1, "c-read", "read", {"file_path": f"{WS}/app/lib/auth/login_controller.dart"}))
E(result(3380, 1, 1, "c-read", "<path>app/lib/auth/login_controller.dart</path>", read_meta("app/lib/auth/login_controller.dart", CONTROLLER)))
E(call(3390, 1, 1, "c-grep", "grep", {"pattern": "submit\\(", "path": f"{WS}/app/lib"}))
E(result(3720, 1, 1, "c-grep", "lib/auth/login_page.dart:52:  onPressed: controller.submit,"))
E(ev(3730, "step/end", {"turn": 1, "step": 1}))
E(ev(3740, "step/start", {"turn": 1, "step": 2}))
r2 = "问题在 submit:请求返回前 _submitting 没有置位。进入时立刻加锁,finally 里复位。"
E(message(10140, 1, 2, "m-1-2", "", r2,
          [("c-todo1", "todo_write", {"todos": TODOS1}),
           ("c-edit", "edit", EDIT1)],
          usage(1320, 13312, 612, 380), stream(3740, 900, r2, "", 2400)))
E(call(10150, 1, 2, "c-todo1", "todo_write", {"todos": TODOS1}))
E(ev(10170, "todo/write", {"todos": TODOS1}))
E(result(10180, 1, 2, "c-todo1", "Todos updated"))
E(call(10190, 1, 2, "c-edit", "edit", EDIT1))
E(result(10290, 1, 2, "c-edit", "The file has been updated.", {"diffs": [dict(h, path=f"{WS}/app/lib/auth/login_controller.dart") for h in hunks(CONTROLLER, CONTROLLER2)]}))
E(ev(10300, "step/end", {"turn": 1, "step": 2}))
E(ev(10310, "step/start", {"turn": 1, "step": 3}))
r3 = "改完了,跑一下登录相关的测试。"
bash1 = {"command": "flutter test test/auth", "description": "运行登录相关测试", "sandbox_permissions": "danger-full-access", "justification": "需要联网下载依赖"}
E(message(14410, 1, 3, "m-1-3", "", r3, [("c-test", "bash", bash1)], usage(980, 14848, 154, 60), stream(10310, 1300, r3, "", 600)))
E(call(14420, 1, 3, "c-test", "bash", bash1))
E(ev(14425, "approval/asked", {"id": "ap-1", "toolName": "bash", "callId": "c-test", "reason": "escalate sandbox to danger-full-access"}))
E(ev(62425, "approval/decided", {"id": "ap-1", "outcome": "allowed-once"}))
E(result(74825, 1, 3, "c-test", "00:03 +6: All tests passed!"))
E(ev(74830, "step/end", {"turn": 1, "step": 3}))
E(ev(74840, "step/start", {"turn": 1, "step": 4}))
r4 = "测试都过了。再补一个连点的测试。"
E(message(77740, 1, 4, "m-1-4", "", r4,
          [("c-write", "write", {"file_path": f"{WS}/test/auth/login_controller_test.dart", "content": TEST + "\n"}),
           ("c-todo2", "todo_write", {"todos": TODOS2})],
          usage(1104, 15872, 498, 120), stream(74840, 700, r4, "", 1700)))
E(call(77750, 1, 4, "c-write", "write", {"file_path": f"{WS}/test/auth/login_controller_test.dart", "content": TEST + "\n"}))
E(result(77850, 1, 4, "c-write", "Created file test/auth/login_controller_test.dart", {"operation": "create", "diffs": []}))
E(call(77860, 1, 4, "c-todo2", "todo_write", {"todos": TODOS2}))
E(ev(77870, "todo/write", {"todos": TODOS2}))
E(result(77880, 1, 4, "c-todo2", "Todos updated"))
E(ev(77885, "step/end", {"turn": 1, "step": 4}))
E(ev(77890, "step/start", {"turn": 1, "step": 5}))
reply = ("改好了。**原因**:`submit()` 在请求返回前没有加锁,两次点击之间的 `await` 让第二次点击也进了请求。\n\n"
         "- 进入 `submit()` 时立刻置 `_submitting = true`,请求结束后在 `finally` 里复位;\n"
         "- 新增 `test/auth/login_controller_test.dart`,模拟连点,确认只发出一次请求。")
E(message(82890, 1, 5, "m-1-5", reply, "可以总结了。", [], usage(612, 16896, 420, 30), stream(77890, 800, "可以总结了。", reply, 0)))
E(ev(82895, "step/end", {"turn": 1, "step": 5}))
E(ev(82900, "turn/end", {"turn": 1, "reason": {"kind": "completed"}}))
turn1_end = seq
# ---- turn 2 (still running)
B = 140000
E(ev(B, "turn/start", {"turn": 2}))
E(ev(B + 2, "user/message", {"id": "u-2", "role": "user", "content": [{"type": "text", "text": "README 里的运行说明也更新一下,写上要先 flutter pub get。"}], "source": {"kind": "user", "rpcId": "rpc-2"}}))
E(ev(B + 60, "step/start", {"turn": 2, "step": 1}))
s = "先看看 README 现在写了什么。"
E(message(B + 2460, 2, 1, "m-2-1", "", s,
          [("c-todo3", "todo_write", {"todos": TODOS3}), ("c-readme", "read", {"file_path": f"{WS}/README.md"})],
          usage(860, 17920, 210, 80), stream(B + 60, 950, s, "", 500)))
E(call(B + 2470, 2, 1, "c-todo3", "todo_write", {"todos": TODOS3}))
E(ev(B + 2480, "todo/write", {"todos": TODOS3}))
E(result(B + 2490, 2, 1, "c-todo3", "Todos updated"))
E(call(B + 2500, 2, 1, "c-readme", "read", {"file_path": f"{WS}/README.md"}))
E(result(B + 2580, 2, 1, "c-readme", "<path>README.md</path>", dict(read_meta("README.md", README), lang="markdown")))
E(ev(B + 2590, "step/end", {"turn": 2, "step": 1}))
E(ev(B + 2600, "step/start", {"turn": 2, "step": 2}))
s = "在 Run 一节加上 flutter pub get,再加一个 Test 小节。"
E(message(B + 5700, 2, 2, "m-2-2", "", s,
          [("c-edit2", "edit", EDIT2),
           ("c-todo4", "todo_write", {"todos": TODOS4})],
          usage(540, 18944, 260, 70), stream(B + 2600, 800, s, "", 900)))
E(call(B + 5710, 2, 2, "c-edit2", "edit", EDIT2))
E(result(B + 5790, 2, 2, "c-edit2", "The file has been updated.", {"diffs": [dict(h, path=f"{WS}/README.md") for h in hunks(README, README2)]}))
E(call(B + 5800, 2, 2, "c-todo4", "todo_write", {"todos": TODOS4}))
E(ev(B + 5810, "todo/write", {"todos": TODOS4}))
E(result(B + 5820, 2, 2, "c-todo4", "Todos updated"))
E(ev(B + 5830, "step/end", {"turn": 2, "step": 2}))
E(ev(B + 5840, "step/start", {"turn": 2, "step": 3}))
s = "跑一遍全部测试确认。"
bash2 = {"command": "flutter test", "description": "运行全部测试"}
E(message(B + 7640, 2, 3, "m-2-3", "", s, [("c-test2", "bash", bash2)], usage(310, 19456, 96, 40), stream(B + 5840, 700, s, "", 300)))
E(call(B + 7650, 2, 3, "c-test2", "bash", bash2))

header = {"version": 4, "id": "session-run-info", "createdAt": T0 - 6000, "cwd": WS, "isSeeded": False, "agentPreset": "standard"}
snapshot = {"type": "snapshot", "header": header, "cursor": 3, "records": [{"type": "event", "event": e} for e in events[:4]],
            "hasMore": False, "projections": {"asOfSeq": 3, "values": {}}, "assistantStream": {"revision": 0}}
out = [json.dumps(snapshot, ensure_ascii=False)] + [json.dumps({"type": "event", "event": e}, ensure_ascii=False) for e in events[4:]]
open(sys.argv[1], "w").write("\n".join(out) + "\n")
print("events", len(events), "turn 1 ends at seq", turn1_end - 1, "last seq", seq - 1)
