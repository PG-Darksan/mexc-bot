# 資金調達率の履歴 (1 年分) を取る。
import json, os
import numpy as np
from concurrent.futures import ThreadPoolExecutor
import fetch
meta = json.load(open(os.path.join(fetch.OUT, "meta.json")))
start_ms = (meta["now"] - 370 * 86400) * 1000
syms = json.load(open(os.path.join(fetch.OUT, "m15_symbols.json")))
out_dir = os.path.join(fetch.OUT, "funding")
os.makedirs(out_dir, exist_ok=True)
def job(s):
    p = os.path.join(out_dir, s + ".npz")
    if os.path.exists(p):
        return
    t, r = [], []
    page = 1
    try:
        while True:
            d = fetch.get(f"/api/v1/contract/funding_rate/history?symbol={s}&page_num={page}&page_size=1000")
            lst = d.get("resultList") or []
            for x in lst:
                t.append(x["settleTime"] // 1000)
                r.append(x["fundingRate"])
            if not lst or lst[-1]["settleTime"] < start_ms or page >= d.get("totalPage", 1):
                break
            page += 1
        o = np.argsort(t)
        np.savez_compressed(p, time=np.array(t, float)[o], rate=np.array(r, float)[o])
    except Exception as e:
        print("ERR funding", s, e, flush=True)
with ThreadPoolExecutor(8) as ex:
    list(ex.map(job, syms))
print("done funding", len(os.listdir(out_dir)), flush=True)
