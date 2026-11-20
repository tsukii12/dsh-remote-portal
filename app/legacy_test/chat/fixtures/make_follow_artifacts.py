"""Writes test/chat/fixtures/follow_artifacts.jsonl (run from app/:
`python3 test/chat/fixtures/make_follow_artifacts.py test/chat/fixtures/follow_artifacts.jsonl`).

A synthetic four-turn session in DSH 0.2.1 follow-frame shape for the chat's
artifact cards (lib/state/artifacts.dart):

1. Deliverables: a PDF and a chart declared with `present`
   (`deliverables/presented`), plus a created script (code: not an artifact).
2. No deliverables: a created web page (artifact), a created Markdown note
   and an edited script (not artifacts), a failed CSV write, and a final reply
   linking a workbook its bash run named (artifact), an image nothing named,
   a web URL and a code file (all ignored).
3. Copies the workbook to /sdcard/Download/DSH (the test supplies the phone
   folder listing).
4. Still running, with a declaration that must not show yet."""
import json, sys

T0 = 1792900000000
WS = "/root/workspace"
seq = 0
out = []

def ev(t, typ, data):
    global seq
    e = {"type": typ, "seq": seq, "time": T0 + t, "data": data}
    seq += 1
    out.append({"type": "event", "event": e})

def user(t, text, rpc):
    ev(t, "user/message", {"id": "u-" + rpc, "role": "user", "content": [{"type": "text", "text": text}],
                           "source": {"kind": "user", "rpcId": rpc}})

def message(t, turn, step, mid, text, calls=()):
    content = []
    if text: content.append({"type": "text", "text": text})
    for cid, name, args in calls:
        content.append({"type": "tool-call", "id": cid, "name": name, "arguments": json.dumps(args, ensure_ascii=False)})
    ev(t, "assistant/message", {"turn": turn, "step": step, "message": {
        "id": mid, "role": "assistant", "content": content,
        "source": {"kind": "llm", "provider": "deepseek-official", "model": "deepseek-flash"}},
        "usage": {"inputTokens": 900, "outputTokens": 60, "cacheReadTokens": 0, "cacheWriteTokens": 0, "totalTokens": 960}})

def tool(t, turn, step, mid, cid, name, args, result, error=False, meta=None, text=""):
    message(t, turn, step, mid, text, [(cid, name, args)])
    ev(t + 10, "tool/call", {"turn": turn, "step": step, "callId": cid, "name": name, "arguments": json.dumps(args, ensure_ascii=False)})
    d = {"turn": turn, "step": step, "message": {"id": "r-" + cid, "role": "tool", "source": {"kind": "tool", "callId": cid},
         "toolCallId": cid, "content": [{"type": "text", "text": result}], "isError": error}}
    if meta is not None: d["meta"] = meta
    ev(t + 500, "tool/result", d)

def created(path):
    return {"operation": "create", "path": path}

snapshot = {"type": "snapshot",
            "header": {"version": 4, "id": "session-artifacts", "createdAt": T0, "cwd": WS, "isSeeded": False, "agentPreset": "standard"},
            "cursor": -1, "records": [], "hasMore": False, "projections": {"asOfSeq": -1, "values": {}}}

# Turn 1: deliverables ---------------------------------------------------------
ev(0, "turn/start", {"turn": 1})
user(10, "做一份季度销售报告 PDF,配一张趋势图。", "rpc-1")
tool(2000, 1, 1, "m-1-1", "c-script", "write", {"file_path": f"{WS}/make_report.py", "content": "import matplotlib\n"},
     "<path>make_report.py</path>\nCreated.", meta=created(f"{WS}/make_report.py"), text="先写生成脚本。")
tool(4000, 1, 2, "m-1-2", "c-run", "bash", {"command": "python3 make_report.py"}, "wrote out/report.pdf\nwrote out/chart.png")
files = [{"path": f"{WS}/out/report.pdf", "description": "2026 Q3 销售汇总"}, {"path": f"{WS}/out/chart.png"}]
tool(9000, 1, 3, "m-1-3", "c-present", "present", {"files": files}, "\n".join("Presented " + f["path"] for f in files))
ev(9501, "deliverables/presented", {"turn": 1, "callId": "c-present", "files": files})
message(11000, 1, 4, "m-1-4", "报告和趋势图都好了。![趋势](<out/chart.png>)")
ev(11010, "turn/end", {"turn": 1, "reason": {"kind": "completed"}})

# Turn 2: fallback rules -------------------------------------------------------
ev(20000, "turn/start", {"turn": 2})
user(20010, "顺便做个展示网页,数据导出成表格。", "rpc-2")
tool(22000, 2, 1, "m-2-1", "c-html", "write", {"file_path": "site/index.html", "content": "<h1>Q3</h1>\n"},
     "<path>site/index.html</path>\nCreated.", meta=created(f"{WS}/site/index.html"))
tool(23000, 2, 2, "m-2-2", "c-note", "write", {"file_path": f"{WS}/notes.md", "content": "# 备忘\n"},
     "<path>notes.md</path>\nCreated.", meta=created(f"{WS}/notes.md"))
tool(24000, 2, 3, "m-2-3", "c-edit", "edit", {"file_path": f"{WS}/make_report.py", "old_string": "import matplotlib", "new_string": "import matplotlib\nimport pandas"},
     "The file make_report.py has been updated.", meta={"diffs": [{"oldText": "import matplotlib", "newText": "import matplotlib\nimport pandas"}]})
tool(25000, 2, 4, "m-2-4", "c-csv", "write", {"file_path": f"{WS}/data/sales.csv", "content": "a,b\n"},
     "Error: directory data does not exist", error=True)
tool(26000, 2, 5, "m-2-5", "c-export", "bash", {"command": "python3 export.py"}, "exported out/summary.xlsx (3 sheets)")
message(30000, 2, 6, "m-2-6",
        "网页在 [index.html](<site/index.html>),表格见 [summary](<out/summary.xlsx>)。"
        "参考图 ![趋势](out/trend.png),官网 [年报](https://example.com/annual.pdf),脚本见 [make_report.py](<make_report.py#L2>)。")
ev(30010, "turn/end", {"turn": 2, "reason": {"kind": "completed"}})

# Turn 3: phone output folder --------------------------------------------------
ev(40000, "turn/start", {"turn": 3})
user(40010, "把表格存到手机上。", "rpc-3")
tool(42000, 3, 1, "m-3-1", "c-cp", "bash", {"command": "mkdir -p /sdcard/Download/DSH && cp out/summary.xlsx /sdcard/Download/DSH/"}, "")
message(44000, 3, 2, "m-3-2", "已经放到手机的「下载/DSH」里了。")
ev(44010, "turn/end", {"turn": 3, "reason": {"kind": "completed"}})

# Turn 4: still running --------------------------------------------------------
ev(50000, "turn/start", {"turn": 4})
user(50010, "再出一版英文的。", "rpc-4")
files4 = [{"path": f"{WS}/out/report-en.pdf"}]
tool(52000, 4, 1, "m-4-1", "c-present4", "present", {"files": files4}, "Presented " + files4[0]["path"])
ev(52501, "deliverables/presented", {"turn": 4, "callId": "c-present4", "files": files4})

lines = [json.dumps(snapshot, ensure_ascii=False)] + [json.dumps(o, ensure_ascii=False) for o in out]
with open(sys.argv[1], "w") as f:
    f.write("\n".join(lines) + "\n")
