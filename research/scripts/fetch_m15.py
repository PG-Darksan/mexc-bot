# 1h 足で直近 24h 売買代金が 1M 以上になった事のある銘柄だけ、15 分足を取る。
import json, os
import numpy as np
from concurrent.futures import ThreadPoolExecutor
import fetch

cand = json.load(open(os.path.join(fetch.OUT, "candidates.json")))
# 先に 1h を揃える (壊れたファイルは消して取り直す)
for s in cand:
    p = os.path.join(fetch.OUT, "h1", s + ".npz")
    if os.path.exists(p):
        try:
            np.load(p)["close"].sum()
        except Exception:
            os.remove(p)
def job1(s):
    try:
        fetch.fetch_tf(s, "h1")
    except Exception as e:
        print("ERR h1", s, e, flush=True)
with ThreadPoolExecutor(8) as ex:
    list(ex.map(job1, cand))
print("done h1", flush=True)
start = fetch.NOW - 365 * 86400
keep = []
for s in cand:
    p = os.path.join(fetch.OUT, "h1", s + ".npz")
    if not os.path.exists(p):
        continue
    z = np.load(p)
    a = z["amount"]
    ca = np.concatenate([[0], np.cumsum(a)])
    r = ca[24:] - ca[:-24]
    t = z["time"][23:]
    if ((r >= 1e6) & (t >= start)).any():
        keep.append(s)
json.dump(keep, open(os.path.join(fetch.OUT, "m15_symbols.json"), "w"))
print("m15 symbols", len(keep), flush=True)
done = [0]
def job(s):
    try:
        fetch.fetch_tf(s, "m15")
    except Exception as e:
        print("ERR m15", s, e, flush=True)
    done[0] += 1
    if done[0] % 100 == 0:
        print("m15", done[0], "/", len(keep), flush=True)
for s in keep:
    p = os.path.join(fetch.OUT, "m15", s + ".npz")
    if os.path.exists(p):
        try:
            np.load(p)["close"].sum()
        except Exception:
            os.remove(p)
with ThreadPoolExecutor(14) as ex:
    list(ex.map(job, keep))
print("done m15", flush=True)
