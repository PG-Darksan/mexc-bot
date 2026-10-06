# いろいろな手法を 1 年分まとめて検証する。
#
# * 足確定の手法は、足 i の終値で判定して、次の足 i+1 の始値で成行で入る。
# * bbtouch だけは今のボットと同じく、足の途中で BB の線に触れた瞬間に入る。
# * 決済は 利確 / 損切り / 最長保有 (12 時間以内) のどれか早いもの。
#   同じ足で利確と損切りの両方に届いたら損切りが先 (不利な方) とする。
# * 費用は API の Taker 0.08% × 2 + 滑り 0.05% × 2。資金調達料は実際の履歴で足し引きする。
# * 1 銘柄 1 建玉、決済から 60 分は入らない (ボットと同じ)。
import json, os, sys, math, pickle
from multiprocessing import Pool
import numpy as np
import pandas as pd

D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
META = json.load(open(os.path.join(D, "meta.json")))
NOW = META["now"]
START = NOW - 365 * 86400
HALF = START + int(182.5 * 86400)
CRASH0, CRASH1 = 1760054400, 1760227200
SEC = {"m5": 300, "m15": 900, "m30": 1800, "h1": 3600, "h4": 14400}
FEE = 0.0008      # API の Taker (片道)
SLIP = 0.0005     # 滑り (片道)
COST = 2 * (FEE + SLIP)
MIN_AMT = 1e6
WARM = 210
COOLDOWN = 3600
TP_M = (0.5, 1.0, 2.0, 3.0, 4.0, 6.0)
SL_M = (0.5, 1.0, 2.0, 3.0, 4.0, 6.0)
H_HOURS = (1, 3, 6, 12)
NMON = 13


def h_bars(tf):
    out = []
    for h in H_HOURS:
        b = h * 3600 // SEC[tf]
        if b >= 1 and b not in out:
            out.append(b)
    return out


def configs(tf):
    return [(tp, sl, hb) for hb in h_bars(tf) for tp in TP_M for sl in SL_M]


def variants():
    v = []
    for k in (2.0, 2.5, 3.0):
        for r in (0, 80, 90):
            v.append(("bbfade", "sig", "close", (("k", k), ("rsi", r))))
    for k in (2.0, 2.5, 3.0):
        for vol in (0, 2):
            v.append(("bbbreak", "sig", "close", (("k", k), ("vol", vol))))
    for n in (20, 55):
        for vol in (0, 2):
            v.append(("donchian", "atr", "close", (("n", n), ("vol", vol))))
    for th in (5, 10):
        for trend in (1, 0):
            v.append(("rsi2", "atr", "close", (("th", th), ("trend", trend))))
    for f, s in ((9, 21), (20, 50)):
        v.append(("emacross", "atr", "close", (("fast", f), ("slow", s))))
    for m in (2, 3):
        for vol in (0, 3):
            v.append(("spikefade", "atr", "close", (("m", m), ("vol", vol))))
            v.append(("spikefollow", "atr", "close", (("m", m), ("vol", vol))))
    for k in (3.0, 3.5, 4.0):
        for r in (0, 90, 95):
            v.append(("bbtouch", "sig", "touch", (("k", k), ("rsi", r))))
    # 資金調達率が極端な時、清算の 1 本前に入る。collect は受け取る側、follow は払う側。
    for th in (0.0005, 0.001, 0.002):
        v.append(("fundcollect", "atr", "close", (("th", th),)))
        v.append(("fundfollow", "atr", "close", (("th", th),)))
    return v


VARIANTS = variants()


# ── データ ───────────────────────────────────────────────────

def load(sym, tf):
    if tf == "m30":
        z = load(sym, "m15")
        if z is None:
            return None
        t = z["time"]
        g = (t // 1800).astype(np.int64)
        u, start_idx, counts = np.unique(g, return_index=True, return_counts=True)
        end_idx = start_idx + counts - 1
        hi = np.maximum.reduceat(z["high"], start_idx)
        lo = np.minimum.reduceat(z["low"], start_idx)
        am = np.add.reduceat(z["amount"], start_idx)
        return dict(time=u.astype(float) * 1800, open=z["open"][start_idx], high=hi, low=lo,
                    close=z["close"][end_idx], amount=am)
    p = os.path.join(D, tf, sym + ".npz")
    if not os.path.exists(p):
        return None
    z = np.load(p)
    return {k: z[k] for k in ("time", "open", "high", "low", "close", "amount")}


def load_funding(sym):
    p = os.path.join(D, "funding", sym + ".npz")
    if not os.path.exists(p):
        return np.zeros(0), np.zeros(1)
    z = np.load(p)
    t = z["time"]
    cr = np.concatenate([[0.0], np.cumsum(z["rate"])])
    return t, cr


# ── 指標 (ボットと同じ定義: EMA/RMA は先頭 period 本の SMA を種にする) ──

def seeded_ewm(x, period, alpha):
    out = np.full(len(x), np.nan)
    if len(x) < period:
        return out
    seed = np.nanmean(x[:period])
    s = pd.Series(np.concatenate([[seed], x[period:]]))
    out[period - 1:] = s.ewm(alpha=alpha, adjust=False).mean().to_numpy()
    return out


def ema(x, p):
    return seeded_ewm(x, p, 2 / (p + 1))


def rsi(c, p):
    d = np.diff(c)
    g = np.maximum(d, 0)
    l = np.maximum(-d, 0)
    ag = np.full(len(c), np.nan)
    al = np.full(len(c), np.nan)
    ag[1:] = seeded_ewm(g, p, 1 / p)
    al[1:] = seeded_ewm(l, p, 1 / p)
    with np.errstate(divide="ignore", invalid="ignore"):
        rs = ag / al
        r = 100 - 100 / (1 + rs)
    r = np.where(al == 0, np.where(ag == 0, 50.0, 100.0), r)
    return r, ag, al


def atr(h, l, c, p=14):
    pc = np.concatenate([[c[0]], c[:-1]])
    tr = np.maximum(h - l, np.maximum(np.abs(h - pc), np.abs(l - pc)))
    tr[0] = h[0] - l[0]
    return seeded_ewm(tr, p, 1 / p)


def indicators(z, tf):
    c, h, l, o, a = z["close"], z["high"], z["low"], z["open"], z["amount"]
    cs = pd.Series(c)
    mid = cs.rolling(20).mean().to_numpy()
    sd = cs.rolling(20).std(ddof=0).to_numpy()
    r7, ag7, al7 = rsi(c, 7)
    r2, _, _ = rsi(c, 2)
    at = atr(h, l, c, 14)
    n24 = 86400 // SEC[tf]
    ca = np.concatenate([[0], np.cumsum(a)])
    idx = np.arange(len(c))
    amt24 = ca[idx + 1] - ca[np.maximum(0, idx + 1 - n24)]
    amtavg = pd.Series(a).rolling(20).mean().to_numpy()
    ind = dict(mid=mid, sd=sd, rsi7=r7, ag7=ag7, al7=al7, rsi2=r2, atr=at, amt24=amt24, amtavg=amtavg,
               ema200=ema(c, 200))
    for p in (9, 21, 20, 50):
        ind[f"ema{p}"] = ema(c, p)
    for n in (20, 55):
        ind[f"dhi{n}"] = pd.Series(h).rolling(n).max().shift(1).to_numpy()
        ind[f"dlo{n}"] = pd.Series(l).rolling(n).min().shift(1).to_numpy()
    return ind


def prev(x):
    return np.concatenate([[np.nan], x[:-1]])


def fresh(sig):
    return sig & ~np.concatenate([[False], sig[:-1]])


def fund_signal(name, prm, side, z, tf, fund):
    """清算時刻 S の 1 本前の足 (S - sec から始まる足) で入るよう、その前の足 i に印を付ける。"""
    n = len(z["close"])
    sig = np.zeros(n, bool)
    ft, cr = fund
    if len(ft) == 0:
        return sig
    # 判定に使うのは 1 つ前の清算で確定した調達率 (入る時点で分かっている値)。
    # その回の調達率は清算までの値動きで決まるので、使うと先読みになる。
    rates = np.concatenate([[0.0], np.diff(cr)[:-1]])
    sec = SEC[tf]
    target = ft - 2 * sec
    idx = np.searchsorted(z["time"], target)
    ok = idx < n
    ok[ok] &= z["time"][idx[ok]] == target[ok]
    th = dict(prm)["th"]
    receive = (rates <= -th) if side > 0 else (rates >= th)
    pay = (rates >= th) if side > 0 else (rates <= -th)
    want = receive if name == "fundcollect" else pay
    sig[idx[ok & want]] = True
    return sig


def signal(name, prm, side, z, ind):
    """side: +1 = ロング, -1 = ショート。足 i の終値で判定した bool 配列。"""
    c, o = z["close"], z["open"]
    p = dict(prm)
    with np.errstate(invalid="ignore"):
        if name == "bbfade":
            if side < 0:
                s = c > ind["mid"] + p["k"] * ind["sd"]
                if p["rsi"]:
                    s &= ind["rsi7"] >= p["rsi"]
            else:
                s = c < ind["mid"] - p["k"] * ind["sd"]
                if p["rsi"]:
                    s &= ind["rsi7"] <= 100 - p["rsi"]
            return s
        if name == "bbbreak":
            s = (c > ind["mid"] + p["k"] * ind["sd"]) if side > 0 else (c < ind["mid"] - p["k"] * ind["sd"])
            s = fresh(s)
            if p["vol"]:
                s &= z["amount"] > p["vol"] * prev(ind["amtavg"])
            return s
        if name == "donchian":
            n = p["n"]
            s = (c > ind[f"dhi{n}"]) if side > 0 else (c < ind[f"dlo{n}"])
            s = fresh(s)
            if p["vol"]:
                s &= z["amount"] > p["vol"] * prev(ind["amtavg"])
            return s
        if name == "rsi2":
            if side > 0:
                s = ind["rsi2"] < p["th"]
                if p["trend"]:
                    s &= c > ind["ema200"]
            else:
                s = ind["rsi2"] > 100 - p["th"]
                if p["trend"]:
                    s &= c < ind["ema200"]
            return s
        if name == "emacross":
            f, sl = ind[f"ema{p['fast']}"], ind[f"ema{p['slow']}"]
            above = f > sl
            pa = np.concatenate([[False], above[:-1]])
            return (above & ~pa) if side > 0 else (~above & pa)
        if name in ("spikefade", "spikefollow"):
            body = (c - o) / prev(ind["atr"])
            up = body > p["m"]
            dn = body < -p["m"]
            if p["vol"]:
                vok = z["amount"] > p["vol"] * prev(ind["amtavg"])
                up &= vok
                dn &= vok
            if name == "spikefade":
                return dn if side > 0 else up
            return up if side > 0 else dn
    raise ValueError(name)


# ── 決済の計算 ───────────────────────────────────────────────

def first_hit(run, thr):
    """run: (n, L) の累積最大。thr: (n,)。初めて thr 以上になる位置、無ければ L。"""
    hit = run >= thr[:, None]
    any_ = hit.any(axis=1)
    return np.where(any_, hit.argmax(axis=1), run.shape[1])


def outcomes(z, tf, side, j0, E, unit, touch, fund, chunk=3000):
    """メモリを抑えるため、イベントを小分けにして [_outcomes] を呼ぶ。"""
    if len(j0) <= chunk:
        return _outcomes(z, tf, side, j0, E, unit, touch, fund)
    oks, offs, nets = [], [], []
    for a in range(0, len(j0), chunk):
        ok, off, net = _outcomes(z, tf, side, j0[a:a + chunk], E[a:a + chunk], unit[a:a + chunk], touch, fund)
        oks.append(ok)
        offs.append(off)
        nets.append(net)
    return np.concatenate(oks), np.concatenate(offs), np.concatenate(nets)


def _outcomes(z, tf, side, j0, E, unit, touch, fund):
    """入る足 j0・入値 E・単位 unit の各イベントについて、全設定の (決済まで本数, 純損益) を返す。"""
    cfgs = configs(tf)
    hbs = h_bars(tf)
    L = max(hbs)
    n = len(z["close"])
    ok = j0 + L - 1 < n
    j0, E, unit = j0[ok], E[ok], unit[ok]
    ne = len(j0)
    C = len(cfgs)
    if ne == 0:
        return ok, np.zeros((0, C), np.int16), np.zeros((0, C), np.float32)
    P = j0[:, None] + np.arange(L)[None, :]
    hh, ll, cc, oo = z["high"][P], z["low"][P], z["close"][P], z["open"][P]
    Ec = E[:, None]
    if side < 0:
        A = hh / Ec - 1
        F = 1 - ll / Ec
        OA = oo / Ec - 1
        R = 1 - cc / Ec
    else:
        A = 1 - ll / Ec
        F = hh / Ec - 1
        OA = 1 - oo / Ec
        R = cc / Ec - 1
    OA[:, 0] = 0
    if touch:
        # 入った足の中は、利確は終値でしか判定しない (安値が入る前だった可能性があるので)
        F[:, 0] = R[:, 0]
    rA = np.maximum.accumulate(A, axis=1)
    rF = np.maximum.accumulate(F, axis=1)
    u = unit / E
    hitS = {m: first_hit(rA, np.minimum(m * u, 0.99)) for m in SL_M}
    hitT = {m: first_hit(rF, m * u) for m in TP_M}
    off = np.empty((ne, C), np.int16)
    ret = np.empty((ne, C), np.float64)
    rows = np.arange(ne)
    for ci, (tp, sl, hb) in enumerate(cfgs):
        s, t = hitS[sl], hitT[tp]
        is_sl = (s <= t) & (s < hb)
        is_tp = (t < s) & (t < hb)
        y = np.minimum(sl * u, 0.99)
        gap = OA[rows, np.minimum(s, L - 1)]
        r = np.where(is_sl, -np.maximum(y, gap), np.where(is_tp, tp * u, R[:, hb - 1]))
        off[:, ci] = np.where(is_sl, s, np.where(is_tp, t, hb - 1))
        ret[:, ci] = r
    # 資金調達料。ショートは調達率が正なら受け取り、ロングは払う。
    ft, cr = fund
    t_in = z["time"][j0]
    t_out = z["time"][j0[:, None] + off.astype(np.int64)] + SEC[tf]
    if len(ft):
        fsum = cr[np.searchsorted(ft, t_out, side="right")] - cr[np.searchsorted(ft, t_in, side="right")][:, None]
        ret = ret + (fsum if side < 0 else -fsum)
    net = np.maximum(ret - COST, -1.0).astype(np.float32)
    return ok, off, net


def touch_events(z, ind, k, side):
    """BB の線に足の途中で触れた足と、その時の入値・σ・RSI。"""
    c, h, l, o = z["close"], z["high"], z["low"], z["open"]
    n = len(c)
    win = np.lib.stride_tricks.sliding_window_view(c, 19)
    mu0 = np.full(n, np.nan)
    sd0 = np.full(n, np.nan)
    mu0[19:] = win[:-1].mean(axis=1)
    sd0[19:] = win[:-1].std(axis=1)
    m = math.sqrt(380 * k * k / (361 - 19 * k * k))
    with np.errstate(invalid="ignore"):
        if side < 0:
            band = mu0 + m * sd0
            hit = (h >= band) & (sd0 > 0)
            E = np.maximum(band, o)
        else:
            band = mu0 - m * sd0
            hit = (l <= band) & (sd0 > 0) & (band > 0)
            E = np.minimum(band, o)
    i = np.nonzero(hit)[0]
    i = i[i >= WARM]
    E = E[i]
    # 触れた瞬間の σ (E を 20 本目に入れたもの)
    vals = np.concatenate([win[i - 19], E[:, None]], axis=1)
    sd = vals.std(axis=1)
    # RSI(7) を E で 1 本進める
    d = E - c[i - 1]
    ag = (ind["ag7"][i - 1] * 6 + np.maximum(d, 0)) / 7
    al = (ind["al7"][i - 1] * 6 + np.maximum(-d, 0)) / 7
    with np.errstate(divide="ignore", invalid="ignore"):
        r = np.where(al == 0, 100.0, 100 - 100 / (1 + ag / al))
    return i, E, sd, r


# ── 1 銘柄ぶんの集計 ─────────────────────────────────────────

FIELDS = ("n", "s", "ss", "w", "sw", "sl_", "nis", "sis", "ssis", "noos", "soos", "ssoos", "ncr", "scr",
          "hold", "ntp", "nsl", "swo", "slo", "wo")


def empty_acc(C):
    a = {f: np.zeros(C) for f in FIELDS}
    a["mon"] = np.zeros((C, NMON))
    a["mon_oos_pos"] = np.zeros(C)
    return a


def accumulate(acc, entry_bar, t_in, off, net, tf):
    """1 銘柄 1 手法ぶんのイベントに建玉の規則をかけ、集計に足す。"""
    ne, C = net.shape
    if ne == 0:
        return
    cd = max(1, math.ceil(COOLDOWN / SEC[tf]))
    take = np.zeros((ne, C), bool)
    nxt = np.full(C, -1, np.int64)
    o64 = off.astype(np.int64)
    for r in range(ne):
        tk = entry_bar[r] >= nxt
        take[r] = tk
        nxt = np.where(tk, entry_bar[r] + o64[r] + cd, nxt)
    x = np.where(take, net, 0.0).astype(np.float64)
    tk = take.astype(np.float64)
    is_ = (t_in < HALF)[:, None]
    cr = ((t_in >= CRASH0) & (t_in < CRASH1))[:, None]
    acc["n"] += tk.sum(0)
    acc["s"] += x.sum(0)
    acc["ss"] += (x * x).sum(0)
    acc["w"] += (take & (net > 0)).sum(0)
    acc["sw"] += np.where(take & (net > 0), net, 0).sum(0)
    acc["sl_"] += np.where(take & (net <= 0), net, 0).sum(0)
    isn = take & is_ & ~cr
    oos = take & ~is_
    acc["nis"] += isn.sum(0)
    acc["sis"] += np.where(isn, net, 0).sum(0)
    acc["ssis"] += np.where(isn, net.astype(np.float64) ** 2, 0).sum(0)
    acc["noos"] += oos.sum(0)
    acc["soos"] += np.where(oos, net, 0).sum(0)
    acc["ssoos"] += np.where(oos, net.astype(np.float64) ** 2, 0).sum(0)
    acc["swo"] += np.where(oos & (net > 0), net, 0).sum(0)
    acc["slo"] += np.where(oos & (net <= 0), net, 0).sum(0)
    acc["wo"] += (oos & (net > 0)).sum(0)
    acc["ncr"] += (take & cr).sum(0)
    acc["scr"] += np.where(take & cr, net, 0).sum(0)
    acc["hold"] += np.where(take, off + 1, 0).sum(0)
    mon = np.clip(((t_in - START) // (86400 * 28.08)).astype(int), 0, NMON - 1)
    for mth in np.unique(mon):
        sel = (mon == mth)[:, None] & take
        acc["mon"][:, mth] += np.where(sel, net, 0).sum(0)


def process(args):
    sym, tf = args
    z = load(sym, tf)
    if z is None or len(z["close"]) < WARM + 200:
        return None
    ind = indicators(z, tf)
    fund = load_funding(sym)
    n = len(z["close"])
    t = z["time"]
    C = len(configs(tf))
    idx = np.arange(n)
    base_ok = (idx >= WARM) & (idx < n - 1) & (t >= START) & (ind["amt24"] >= MIN_AMT)
    res = {}
    # 足確定の手法: 単位ごと・方向ごとに、入る足の和集合で一度だけ決済を計算する
    for side in (1, -1):
        sigs = {}
        for vi, (name, unit, kind, prm) in enumerate(VARIANTS):
            if kind != "close":
                continue
            if name.startswith("fund"):
                s = fund_signal(name, prm, side, z, tf, fund) & base_ok
            else:
                s = signal(name, prm, side, z, ind) & base_ok
            u = ind["sd"] if unit == "sig" else ind["atr"]
            with np.errstate(invalid="ignore"):
                s &= u > 0
            sigs[vi] = s
        for unit in ("sig", "atr"):
            vis = [vi for vi in sigs if VARIANTS[vi][1] == unit]
            if not vis:
                continue
            union = np.zeros(n, bool)
            for vi in vis:
                union |= sigs[vi]
            ib = np.nonzero(union)[0]
            if len(ib) == 0:
                continue
            u = (ind["sd"] if unit == "sig" else ind["atr"])[ib]
            j0 = ib + 1
            ok, off, net = outcomes(z, tf, side, j0, z["open"][j0], u, False, fund)
            ib = ib[ok]
            pos = np.full(n, -1)
            pos[ib] = np.arange(len(ib))
            for vi in vis:
                ev = np.nonzero(sigs[vi])[0]
                ev = ev[pos[ev] >= 0]
                if len(ev) == 0:
                    continue
                rows = pos[ev]
                acc = empty_acc(C)
                accumulate(acc, ev + 1, t[ev + 1], off[rows], net[rows], tf)
                res[(vi, side)] = acc
        # BB タッチ (足の途中で入る)
        for k in (3.0, 3.5, 4.0):
            i, E, sd, r = touch_events(z, ind, k, side)
            keep = base_ok[i] & (sd > 0)
            i, E, sd, r = i[keep], E[keep], sd[keep], r[keep]
            if len(i) == 0:
                continue
            ok, off, net = outcomes(z, tf, side, i, E, sd, True, fund)
            i, r = i[ok], r[ok]
            for vi, (name, unit, kind, prm) in enumerate(VARIANTS):
                if name != "bbtouch" or dict(prm)["k"] != k:
                    continue
                th = dict(prm)["rsi"]
                m = np.ones(len(i), bool) if th == 0 else ((r >= th) if side < 0 else (r <= 100 - th))
                if not m.any():
                    continue
                acc = empty_acc(C)
                accumulate(acc, i[m], t[i[m]], off[m], net[m], tf)
                res[(vi, side)] = acc
    return res


def run(tf, symbols, procs=4):
    C = len(configs(tf))
    total = {}
    with Pool(procs) as pool:
        for k, res in enumerate(pool.imap_unordered(process, [(s, tf) for s in symbols], chunksize=2)):
            if res:
                for key, acc in res.items():
                    if key not in total:
                        total[key] = empty_acc(C)
                    for f, v in acc.items():
                        total[key][f] += v
            if (k + 1) % 100 == 0:
                print(tf, k + 1, "/", len(symbols), flush=True)
    pickle.dump(total, open(os.path.join(D, f"sim_{tf}.pkl"), "wb"))
    return total


if __name__ == "__main__":
    tfs = sys.argv[1:]
    for tf in tfs:
        syms = json.load(open(os.path.join(D, "m5_symbols.json" if tf == "m5" else "m15_symbols.json")))
        run(tf, syms)
        print("done", tf, flush=True)
