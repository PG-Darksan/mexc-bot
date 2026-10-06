# MEXC 先物の 1 年分のローソク足を集める。
# 1) 全 USDT 無期限の日足を取り、過去 1 年で日次売買代金が 0.5M 以上の日がある銘柄を候補にする
# 2) 候補について 4h / 1h / 15m を取る
import json, os, sys, time, threading, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
import numpy as np

BASE = "https://api.mexc.com"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
NOW = int(time.time())
DAYS = 365
WARM_BARS = 80  # 指標の助走ぶん
TF = {"d1": ("Day1", 86400), "h4": ("Hour4", 14400), "h1": ("Min60", 3600), "m15": ("Min15", 900)}

_lock = threading.Lock()
_last = [0.0]
RATE = 1 / 4.5  # 実測の上限 (1 秒 4 回強) に合わせる


def get(path):
    for attempt in range(8):
        with _lock:
            wait = _last[0] + RATE - time.time()
            if wait > 0:
                time.sleep(wait)
            _last[0] = time.time()
        try:
            req = urllib.request.Request(BASE + path, headers={"User-Agent": "research"})
            with urllib.request.urlopen(req, timeout=30) as r:
                j = json.load(r)
            if j.get("success") is False or j.get("code") not in (0, None):
                raise RuntimeError(f"api {j.get('code')} {j.get('message')}")
            return j["data"]
        except Exception as e:
            print("RETRY", path[:60], e, flush=True)
            time.sleep(min(30, 2 ** attempt))
            last_err = e
    raise RuntimeError(f"failed {path}: {last_err}")


def fetch_tf(symbol, tf):
    iv, sec = TF[tf]
    path = os.path.join(OUT, tf, symbol + ".npz")
    if os.path.exists(path):
        return path
    target = NOW - DAYS * 86400 - WARM_BARS * sec
    end = NOW
    cols = {k: [] for k in ("time", "open", "high", "low", "close", "amount")}
    while end > target:
        start = max(target, end - 2000 * sec)
        d = get(f"/api/v1/contract/kline/{symbol}?interval={iv}&start={start}&end={end}")
        t = d.get("time") or []
        if not t:
            break
        for k in cols:
            cols[k].insert(0, d.get(k) or [0] * len(t))
        if t[0] <= start + sec:
            end = start - 1
        else:
            break  # 上場前まで来た
        if len(t) < 2:
            break
    arr = {k: np.array([x for chunk in v for x in chunk], dtype=float) for k, v in cols.items()}
    if len(arr["time"]):
        t, idx = np.unique(arr["time"], return_index=True)
        arr = {k: v[idx] for k, v in arr.items()}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    np.savez_compressed(path, **arr)
    return path


def main():
    detail = get("/api/v1/contract/detail")
    perps = [c for c in detail if c.get("quoteCoin") == "USDT" and c.get("settleCoin") == "USDT"]
    fees = {c["symbol"]: (c.get("takerFeeRate", 0.0002), c.get("makerFeeRate", 0.0)) for c in perps}
    tick = {t["symbol"]: t.get("amount24", 0) for t in get("/api/v1/contract/ticker")}
    os.makedirs(OUT, exist_ok=True)
    json.dump({"now": NOW, "fees": fees, "amount24": {s: tick.get(s, 0) for s in fees},
               "state": {c["symbol"]: c.get("state") for c in perps}},
              open(os.path.join(OUT, "meta.json"), "w"))
    syms = [c["symbol"] for c in perps]
    print("perps", len(syms), flush=True)

    with ThreadPoolExecutor(4) as ex:
        list(ex.map(lambda s: fetch_tf(s, "d1"), syms))
    cand = []
    for s in syms:
        z = np.load(os.path.join(OUT, "d1", s + ".npz"))
        m = z["time"] >= NOW - DAYS * 86400
        if len(z["amount"]) and (z["amount"][m] >= 5e5).any():
            cand.append(s)
    json.dump(cand, open(os.path.join(OUT, "candidates.json"), "w"))
    print("candidates", len(cand), flush=True)

    for tf in ("h4", "h1", "m15"):
        done = [0]
        def job(s):
            try:
                fetch_tf(s, tf)
            except Exception as e:
                print("ERR", tf, s, e, flush=True)
            done[0] += 1
            if done[0] % 50 == 0:
                print(tf, done[0], "/", len(cand), flush=True)
        with ThreadPoolExecutor(4) as ex:
            list(ex.map(job, cand))
        print("done", tf, flush=True)


if __name__ == "__main__":
    main()
