# 5 分足を 1 年分取る (m5_symbols.json の銘柄だけ)。
import json, os
import numpy as np
from concurrent.futures import ThreadPoolExecutor
import fetch
fetch.TF["m5"] = ("Min5", 300)
keep = json.load(open(os.path.join(fetch.OUT, "m5_symbols.json")))
for s in keep:
    p = os.path.join(fetch.OUT, "m5", s + ".npz")
    if os.path.exists(p):
        try:
            np.load(p)["close"].sum()
        except Exception:
            os.remove(p)
done = [0]
def job(s):
    try:
        fetch.fetch_tf(s, "m5")
    except Exception as e:
        print("ERR m5", s, e, flush=True)
    done[0] += 1
    if done[0] % 50 == 0:
        print("m5", done[0], "/", len(keep), flush=True)
with ThreadPoolExecutor(8) as ex:
    list(ex.map(job, keep))
print("done m5", flush=True)
