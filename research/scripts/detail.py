# 選んだ手法を 1 件ずつ詳しく調べる (取引の一覧から 落ち込み・同時保有・資金管理)。
import json, os, sys, math
from multiprocessing import Pool
import numpy as np
import pandas as pd
import sim
from sim import SEC, START, HALF, CRASH0, CRASH1, COOLDOWN, D

EXTRA = {"fee_only": -0.001, "base": 0.0, "slip_x3": 0.002}  # 費用の上乗せ (往復)。base は手数料 0.16% + 滑り 0.1%


def trades_for(args):
    """1 銘柄ぶん。BB タッチの手法の取引候補 (建玉の規則をかける前) を返す。"""
    sym, tf, k, rsi_th, side, tp, sl, hb = args
    z = sim.load(sym, tf)
    if z is None or len(z["close"]) < sim.WARM + 200:
        return []
    ind = sim.indicators(z, tf)
    fund = sim.load_funding(sym)
    n = len(z["close"])
    t = z["time"]
    idx = np.arange(n)
    base_ok = (idx >= sim.WARM) & (idx < n - 1) & (t >= START) & (ind["amt24"] >= sim.MIN_AMT)
    i, E, sd, r = sim.touch_events(z, ind, k, side)
    keep = base_ok[i] & (sd > 0)
    if rsi_th:
        keep &= (r >= rsi_th) if side < 0 else (r <= 100 - rsi_th)
    i, E, sd = i[keep], E[keep], sd[keep]
    if len(i) == 0:
        return []
    ok, off, net = sim.outcomes(z, tf, side, i, E, sd, True, fund)
    i = i[ok]
    ci = sim.configs(tf).index((tp, sl, hb))
    off = off[:, ci].astype(int)
    net = net[:, ci].astype(float)
    out = []
    for a, o, x in zip(i, off, net):
        out.append((sym, tf, float(t[a]), float(t[a + o] + SEC[tf]), x, o))
    return out


def select(rows, cap=0):
    """全時間足をまとめて、1 銘柄 1 建玉・決済から 60 分は入らない、をかける。
    cap > 0 なら、同時に持つ数がこれに達している間は新規を見送る。"""
    rows = sorted(rows, key=lambda r: (r[2], r[0]))
    out = []
    busy = {}
    open_until = []
    for r in rows:
        sym, tf, t0, t1 = r[0], r[1], r[2], r[3]
        if t0 < busy.get(sym, -1):
            continue
        if cap:
            open_until = [x for x in open_until if x > t0]
            if len(open_until) >= cap:
                continue
            open_until.append(t1)
        busy[sym] = t1 + COOLDOWN
        out.append(r)
    return pd.DataFrame(out, columns=["sym", "tf", "t0", "t1", "net", "off"])


def metrics(df, extra=0.0):
    net = df["net"].to_numpy() - extra
    o = np.argsort(df["t1"].to_numpy())
    cum = np.cumsum(net[o])
    dd = float((np.maximum.accumulate(np.concatenate([[0], cum]))[1:] - cum).max())
    t0, t1 = df["t0"].to_numpy(), df["t1"].to_numpy()
    s0, s1 = np.sort(t0), np.sort(t1)
    conc = int((np.arange(1, len(s0) + 1) - np.searchsorted(s1, s0, side="right")).max())
    h1, h2 = net[t0 < HALF], net[t0 >= HALF]
    mon = pd.Series(net, index=pd.to_datetime(t0, unit="s")).resample("MS").sum()
    w, l = net[net > 0].sum(), -net[net <= 0].sum()
    return dict(n=len(net), win=float((net > 0).mean()), avg=float(net.mean()), pf=float(w / l) if l else np.inf,
                total=float(net.sum()), dd=dd, conc=conc, worst=float(net.min()),
                avg_h1=float(h1.mean()) if len(h1) else np.nan, avg_h2=float(h2.mean()) if len(h2) else np.nan,
                n_h1=len(h1), n_h2=len(h2), pos_months=int((mon > 0).sum()), months=int(len(mon)),
                hold_h=float(((t1 - t0) / 3600).mean()), crash=float(net[(t0 >= CRASH0) & (t0 < CRASH1)].sum()))


def portfolio(df, fracs=(0.02, 0.05, 0.1), seed=0):
    t0, t1, net = df["t0"].to_numpy(), df["t1"].to_numpy(), df["net"].to_numpy()
    out = {}
    for f in fracs:
        evs = sorted([(a, 1, j) for j, a in enumerate(t0)] + [(b, 0, j) for j, b in enumerate(t1)])
        eq, peak, mdd, used, max_used = 1.0, 1.0, 0.0, 0.0, 0.0
        size = {}
        for _, kind, j in evs:
            if kind == 1:
                size[j] = f * eq
                used += size[j]
                max_used = max(max_used, used / eq)
            else:
                eq += size[j] * net[j]
                used -= size[j]
                peak = max(peak, eq)
                mdd = max(mdd, 1 - eq / peak)
        rng = np.random.default_rng(seed)
        dds = []
        for _ in range(2000):
            e = np.cumprod(1 + f * rng.permutation(net))
            pk = np.maximum.accumulate(np.concatenate([[1], e]))[1:]
            dds.append((1 - e / pk).max())
        out[f] = dict(final=eq, mdd=mdd, mdd95=float(np.percentile(dds, 95)),
                      ruin50=float(np.mean(np.array(dds) >= 0.5)), max_used=max_used)
    return out


def run(tfs, k, rsi_th, side, tp, sl, hours, cap=0):
    rows = []
    for tf in tfs:
        hb = hours * 3600 // SEC[tf]
        syms = json.load(open(os.path.join(D, "m5_symbols.json" if tf == "m5" else "m15_symbols.json")))
        with Pool(4) as pool:
            for r in pool.imap_unordered(trades_for, [(s, tf, k, rsi_th, side, tp, sl, hb) for s in syms], chunksize=4):
                rows.extend(r)
    return select(rows, cap)


if __name__ == "__main__":
    spec = json.loads(sys.argv[1])
    df = run(**spec)
    tag = sys.argv[2]
    df.to_pickle(os.path.join(D, f"trades_{tag}.pkl"))
    res = {name: metrics(df, ex) for name, ex in EXTRA.items()}
    res["by_tf"] = {tf: metrics(g) for tf, g in df.groupby("tf")}
    res["portfolio"] = {str(k): v for k, v in portfolio(df).items()}
    json.dump(res, open(os.path.join(D, f"detail_{tag}.json"), "w"), indent=1)
    print(json.dumps(res, indent=1))
