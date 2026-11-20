"""Writes test/fixtures/follow_presented.jsonl (run from packages/dsh_client/:
`python3 test/fixtures/make_follow_presented.py test/fixtures/follow_presented.jsonl`).

A synthetic two-turn session in DSH 0.2.1 follow-frame shape around the
`present` tool (@deepseek-ai/dsh-tool-present): `files: [{path, description?}]`
in the call, `Presented <path>` per file in the result, then one durable
`deliverables/presented` event `{turn, callId, files}` per successful call.

Turn 1 declares a PDF and a chart, then declares the PDF again with a better
description plus a historical relative path and three malformed entries.
Turn 2 carries two malformed events (turn 0, empty callId) that readers must
ignore, and a failed present call that wrote no event."""
import json, sys

T0 = 1792800000000
WS = "/root/workspace"
seq = 0
out = []

def ev(t, typ, data):
    global seq
    e = {"type": typ, "seq": seq, "time": T0 + t, "data": data}
    seq += 1
    out.append({"type": "event", "event": e})
    return e

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

def call(t, turn, step, cid, name, args):
    ev(t, "tool/call", {"turn": turn, "step": step, "callId": cid, "name": name, "arguments": json.dumps(args, ensure_ascii=False)})

def result(t, turn, step, cid, text, error=False, meta=None):
    d = {"turn": turn, "step": step, "message": {"id": "r-" + cid, "role": "tool", "source": {"kind": "tool", "callId": cid},
         "toolCallId": cid, "content": [{"type": "text", "text": text}], "isError": error}}
    if meta is not None: d["meta"] = meta
    ev(t, "tool/result", d)

snapshot = {"type": "snapshot",
            "header": {"version": 4, "id": "session-presented", "createdAt": T0, "cwd": WS, "isSeeded": False, "agentPreset": "standard"},
            "cursor": -1, "records": [], "hasMore": False,
            "projections": {"asOfSeq": -1, "values": {}}}

# Turn 1 ----------------------------------------------------------------------
ev(0, "turn/start", {"turn": 1})
user(10, "做一份季度销售报告 PDF,再配一张趋势图。", "rpc-1")
message(2000, 1, 1, "m-1-1", "先写生成脚本。", [("c-script", "write", {"file_path": f"{WS}/make_report.py", "content": "import matplotlib\n"})])
call(2010, 1, 1, "c-script", "write", {"file_path": f"{WS}/make_report.py", "content": "import matplotlib\n"})
result(2100, 1, 1, "c-script", "<path>make_report.py</path>\nCreated.", meta={"operation": "create", "path": f"{WS}/make_report.py"})
message(4000, 1, 2, "m-1-2", "", [("c-run", "bash", {"command": "python3 make_report.py"})])
call(4010, 1, 2, "c-run", "bash", {"command": "python3 make_report.py"})
result(9000, 1, 2, "c-run", "wrote out/report.pdf\nwrote out/chart.png")
files1 = [{"path": f"{WS}/out/report.pdf", "description": "季度销售报告"}, {"path": f"{WS}/out/chart.png"}]
message(11000, 1, 3, "m-1-3", "", [("c-present", "present", {"files": files1})])
call(11010, 1, 3, "c-present", "present", {"files": files1})
result(11100, 1, 3, "c-present", "\n".join("Presented " + f["path"] for f in files1))
ev(11101, "deliverables/presented", {"turn": 1, "callId": "c-present", "files": files1})
files2 = [{"path": f"{WS}/out/report.pdf", "description": "季度销售报告(终版)"},
          {"path": "out/data.xlsx", "description": "原始数据"},
          {"path": "   "},
          {"path": f"{WS}/bad.txt", "description": 3},
          "not-an-object"]
message(13000, 1, 4, "m-1-4", "", [("c-present2", "present", {"files": files2})])
call(13010, 1, 4, "c-present2", "present", {"files": files2})
result(13100, 1, 4, "c-present2", "Presented " + f"{WS}/out/report.pdf\nPresented out/data.xlsx")
ev(13101, "deliverables/presented", {"turn": 1, "callId": "c-present2", "files": files2})
message(15000, 1, 5, "m-1-5", "报告和趋势图都好了,见下方文件。")
ev(15010, "turn/end", {"turn": 1, "reason": {"kind": "completed"}})

# Turn 2 ----------------------------------------------------------------------
ev(20000, "turn/start", {"turn": 2})
user(20010, "把图再导出一份 SVG。", "rpc-2")
message(22000, 2, 1, "m-2-1", "", [("c-present3", "present", {"files": [{"path": f"{WS}/out/chart.svg"}]})])
call(22010, 2, 1, "c-present3", "present", {"files": [{"path": f"{WS}/out/chart.svg"}]})
result(22100, 2, 1, "c-present3", "Error: file not found: out/chart.svg", error=True)
ev(22101, "deliverables/presented", {"turn": 0, "callId": "c-x", "files": [{"path": f"{WS}/ghost.pdf"}]})
ev(22102, "deliverables/presented", {"turn": 2, "callId": "", "files": [{"path": f"{WS}/ghost.pdf"}]})
message(24000, 2, 2, "m-2-2", "SVG 没有生成出来,稍后再试。")
ev(24010, "turn/end", {"turn": 2, "reason": {"kind": "completed"}})

snapshot["cursor"] = -1
lines = [json.dumps(snapshot, ensure_ascii=False)] + [json.dumps(o, ensure_ascii=False) for o in out]
with open(sys.argv[1], "w") as f:
    f.write("\n".join(lines) + "\n")
