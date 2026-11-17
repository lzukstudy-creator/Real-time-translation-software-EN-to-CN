#!/usr/bin/env python3
"""Word error rate of AccuracyProbe reports. Usage: score.py REFS_JSON REPORT_DIR"""
import json, re, sys
from pathlib import Path

def tokens(text):
    text = text.lower().replace("’", "'")
    text = re.sub(r"(\w)-(\w)", r"\1 \2", text)
    words = re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text)
    # 英式/美式拼写与口语填充词不计错
    norm = {"normalise": "normalize", "behaviour": "behavior", "flavours": "flavors", "okay": "ok"}
    return [norm.get(w, w) for w in words if w not in {"um", "uh", "er", "ah", "hmm", "mm"}]

def errors(ref, hyp):
    n, m = len(ref), len(hyp)
    prev = list(range(m + 1))
    for i in range(1, n + 1):
        cur = [i] + [0] * m
        for j in range(1, m + 1):
            cur[j] = min(prev[j - 1] + (ref[i - 1] != hyp[j - 1]), prev[j] + 1, cur[j - 1] + 1)
        prev = cur
    return prev[m]

refs = json.loads(Path(sys.argv[1]).read_text())
totals = {}
rows = []
for report in sorted(Path(sys.argv[2]).glob("*.json")):
    data = json.loads(report.read_text())
    name = report.stem + ".wav"
    ref = tokens(refs[name])
    cond = name.rsplit("-", 1)[1][:-4]
    row = [name]
    for key in ("streaming", "twoPass"):
        e = errors(ref, tokens(data[key]))
        t = totals.setdefault((cond, key), [0, 0]); t[0] += e; t[1] += len(ref)
        row.append(f"{key}={100*e/len(ref):5.1f}%")
    row.append(f"refineRTF={data['refineRTF']:.2f} streamRTF={data['streamRTF']:.2f} maxSeg={data['refineMaxSegmentSeconds']:.1f}s")
    rows.append("  ".join(row))
print("\n".join(rows))
for (cond, key), (e, n) in sorted(totals.items()):
    print(f"TOTAL {cond:9s} {key:9s} WER {100*e/n:5.2f}%  ({e}/{n})")
