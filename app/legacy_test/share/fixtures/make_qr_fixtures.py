import subprocess, sys, json
cases = [
  ('hello', 'L'),
  ('https://github.com/ccch1mneyyy/dsh-go', 'M'),
  ('https://github.com/ccch1mneyyy/dsh-go', 'H'),
  ('https://qm.qq.com/q/dshgo?from=app', 'Q'),
  ('把 DSH 装进口袋：dsh-go 社区交流群', 'M'),
  ('https://www.npmjs.com/package/@deepseek-ai/dsh-plugin-example-with-a-longer-name?activeTab=readme', 'M'),
  ('x' * 180, 'M'),
  ('https://example.com/' + 'a1b2c3d4' * 30, 'L'),
  ('dsh-go ' * 60, 'Q'),
  ('0123456789abcdef' * 40, 'M'),
  ('Q' * 1000, 'L'),
  ('Z' * 1800, 'L'),
  ('m' * 1500, 'M'),
  ('k' * 1250, 'H'),
  ('https://t.me/dshgo', 'H'),
]
out = []
for text, level in cases:
  raw = subprocess.run(['qrencode', '-8', '-l', level, '-m', '0', '-t', 'ASCII', text], capture_output=True, text=True, check=True).stdout
  rows = [r for r in raw.split('\n') if r]
  bits = [''.join('1' if r[i:i+2] == '##' else '0' for i in range(0, len(r), 2)) for r in rows]
  size = len(bits)
  assert all(len(b) == size for b in bits), (size, [len(b) for b in bits])
  hexrows = []
  for b in bits:
    pad = b + '0' * ((-len(b)) % 4)
    hexrows.append('%0*x' % (len(pad)//4, int(pad, 2)))
  out.append({'text': text, 'level': level, 'size': size, 'rows': hexrows})
json.dump(out, sys.stdout)
