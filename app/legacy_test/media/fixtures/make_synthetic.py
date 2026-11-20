#!/usr/bin/env python3
"""Writes the SYNTHETIC media fixtures (session-log JSONL, one event a line).

They follow the v1 contract of docs/design/media-generation.md §2.5 (the tool
result's meta["dsh-go/media"]) and the 2026-10-28 revision (generation mode
sends an ordinary user message with a parameter header). The event shapes copy
a real DSH 0.2.1-rc.2 log (test/plugins/view/fixtures/live_tool_card.jsonl).
They are stand-ins until Pro's live `dsh headless` transcripts arrive: replace
each `synthetic_*.jsonl` with its `live_*.jsonl` and keep the tests.

  synthetic_header_image.jsonl  generation mode: header message → generate_image (n = 2, 3:4)
  synthetic_plain_image.jsonl   「画一只猫」 → the same tool result (n = 1, 1:1)
  synthetic_video_running.jsonl a video job still running (status running, job id)
  synthetic_failed.jsonl        a refused description (status failed, policy)

Run from app/: python3 test/media/fixtures/make_synthetic.py
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
T0 = 1793000000000
WS = '/root/workspace'


def ev(seq, kind, data, dt=0):
    return {'type': kind, 'seq': seq, 'time': T0 + seq * 10 + dt, 'data': data}


def user(seq, text):
    return ev(seq, 'user/message', {
        'content': [{'type': 'text', 'text': text}],
        'source': {'kind': 'user', 'rpcId': f'rpc-{seq}'},
        'role': 'user', 'id': f'u-{seq}',
    })


def assistant(seq, turn, step, content):
    return ev(seq, 'assistant/message', {
        'turn': turn, 'step': step,
        'message': {'role': 'assistant', 'content': content,
                    'source': {'kind': 'model', 'provider': 'deepseek-official', 'model': 'deepseek-flash'},
                    'id': f'm-{turn}-{step}'},
        'usage': {'inputTokens': 120, 'outputTokens': 40, 'totalTokens': 160},
    })


def tool_call(call_id, args):
    return {'type': 'tool-call', 'id': call_id, 'name': 'generate_image', 'arguments': json.dumps(args, ensure_ascii=False)}


def result(seq, turn, step, call_id, text, meta, error=False):
    return ev(seq, 'tool/result', {
        'turn': turn, 'step': step,
        'message': {'role': 'tool', 'source': {'kind': 'tool', 'callId': call_id}, 'toolCallId': call_id,
                    'content': [{'type': 'text', 'text': text}], 'isError': error, 'id': f'r-{seq}'},
        'meta': meta,
    })


def media(rid, items, request, prompt, revised=None, cost=None, status='done', job=None, error=None, kind='image'):
    meta = {'v': 1, 'rid': rid, 'kind': kind, 'status': status, 'items': items, 'request': request, 'prompt': prompt,
            'provenance': {'visibleMark': False, 'c2pa': True, 'implicitLabel': True}}
    if revised:
        meta['revisedPrompt'] = revised
    if cost is not None:
        meta['cost'] = {'estimate': cost, 'currency': 'CNY'}
    if job:
        meta['job'] = job
    if error:
        meta['error'] = error
    return {'dsh-go/media': meta}


def picture(name, w, h, size):
    return {'path': f'{WS}/generated/2026-10-28/{name}', 'mime': 'image/png', 'width': w, 'height': h, 'bytes': size}


def turn(seq0, turn_no, prompt, call_id, args, text, meta, reply, error=False):
    s = seq0
    out = [ev(s, 'turn/start', {'turn': turn_no}), user(s + 1, prompt), ev(s + 2, 'step/start', {'turn': turn_no, 'step': 1}),
           assistant(s + 3, turn_no, 1, [tool_call(call_id, args)]),
           ev(s + 4, 'tool/call', {'turn': turn_no, 'step': 1, 'callId': call_id, 'name': 'generate_image',
                                   'arguments': json.dumps(args, ensure_ascii=False)}),
           result(s + 5, turn_no, 1, call_id, text, meta, error=error),
           ev(s + 6, 'step/end', {'turn': turn_no, 'step': 1})]
    if reply:
        out += [ev(s + 7, 'step/start', {'turn': turn_no, 'step': 2}),
                assistant(s + 8, turn_no, 2, [{'type': 'text', 'text': reply}]),
                ev(s + 9, 'step/end', {'turn': turn_no, 'step': 2})]
    out.append(ev(s + 10, 'turn/end', {'turn': turn_no, 'reason': {'kind': 'completed'}}))
    return out


def write(name, events):
    with open(os.path.join(HERE, name), 'w', encoding='utf-8') as f:
        for e in events:
            f.write(json.dumps(e, ensure_ascii=False, separators=(',', ':')) + '\n')


cats = [picture('cat-1.png', 1536, 2048, 3_100_000), picture('cat-2.png', 1536, 2048, 3_050_000)]
write('synthetic_header_image.jsonl', turn(
    0, 1,
    '〔生成图像 · 3:4 · 2 张 · Seedream 5.0〕\n画一只在窗台上打盹的橘猫',
    'call-img-1',
    {'prompt': '画一只在窗台上打盹的橘猫', 'aspect': '3:4', 'n': 2, 'model': 'doubao-seedream-5-0-pro'},
    f'Generated 2 images: {cats[0]["path"]}, {cats[1]["path"]} (1536×2048, 14 s).',
    media('m_7f3a9c', cats,
          {'provider': 'ark', 'model': 'doubao-seedream-5-0-pro', 'label': 'Seedream 5.0', 'aspect': '3:4', 'n': 2,
           'quality': '2k', 'refs': 0},
          '画一只在窗台上打盹的橘猫', revised='午后逆光，一只橘猫蜷在木窗台上打盹，窗外是模糊的绿植', cost=0.6),
    f'画好了，两张都在 `generated/2026-10-28/`。\n\n![橘猫]({cats[0]["path"]})',
))

cat = [picture('cat-3.png', 2048, 2048, 4_200_000)]
write('synthetic_plain_image.jsonl', turn(
    0, 1, '画一只猫', 'call-img-2',
    {'prompt': '一只猫', 'aspect': '1:1', 'n': 1},
    f'Generated 1 image: {cat[0]["path"]} (2048×2048, 9 s).',
    media('m_1b2c3d', cat,
          {'provider': 'ark', 'model': 'doubao-seedream-5-0-pro', 'label': 'Seedream 5.0', 'aspect': '1:1', 'n': 1,
           'quality': '2k'},
          '一只猫'),
    '画好了。要换成黄昏的光线吗？',
))

write('synthetic_video_running.jsonl', turn(
    0, 1, '〔生成视频 · 5 秒 · 720p · Seedance 2.0〕\n镜头缓慢推近，猫抬头看向窗外', 'call-vid-1',
    {'prompt': '镜头缓慢推近，猫抬头看向窗外', 'seconds': 5, 'resolution': '720p'},
    'Started video job media-1c2d.',
    media('m_9e8d7c', [], {'provider': 'ark', 'model': 'doubao-seedance-2-0', 'label': 'Seedance 2.0', 'aspect': '16:9',
                           'seconds': 5, 'resolution': '720p'},
          '镜头缓慢推近，猫抬头看向窗外', status='running', job='media-1c2d', kind='video'),
    '视频开始生成了，好了会告诉你。',
))

write('synthetic_failed.jsonl', turn(
    0, 1, '画一张不该画的图', 'call-img-3', {'prompt': '不该画的图'},
    'Refused by the provider: input moderation.',
    media('m_0f0f0f', [], {'provider': 'ark', 'label': 'Seedream 5.0', 'aspect': '1:1', 'n': 1}, '不该画的图',
          status='failed', error={'code': 'policy', 'text': 'input'}),
    None, error=True,
))
print('ok')
