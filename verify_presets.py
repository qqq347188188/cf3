# -*- coding: utf-8 -*-
"""校验 CFPatchLoader.m 内置预设的 old_hex 与原版 UnityFramework 字节一致"""
import os, re
WORK = r'C:\Users\Administrator\CodeBuddy\20261120115514\work'
UF = os.path.join(WORK, '222', 'UnityFramework')
SRC = os.path.join(WORK, 'hotpatch', 'CFPatchLoader.m')

b = open(UF, 'rb').read()
s = open(SRC, encoding='utf8').read()

# 匹配 {0xOFFSET, "oldhex", "newhex"}
pat = re.compile(r'\{0x([0-9A-Fa-f]+),\s*"([0-9a-fA-F]+)",\s*"([0-9a-fA-F]+)"\}')
rows = pat.findall(s)
print('找到预设条目:', len(rows))
ok = True
for off_s, old, new in rows:
    off = int(off_s, 16)
    actual = b[off:off+len(old)//2].hex()
    good = actual == old.lower()
    ok &= good
    print('  %s 0x%X old=%s actual=%s' % ('OK' if good else 'MISMATCH', off, old, actual))
    if len(old) != len(new):
        print('    !! old/new 长度不等:', len(old), len(new)); ok = False

print('\n结果:', 'ALL OK' if ok else '有不一致')
