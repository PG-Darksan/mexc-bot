# sim_*.pkl から、前半で決済の設定を選び、後半で確かめる。
import os, sys, math, pickle
import numpy as np
import pandas as pd
from sim import VARIANTS, configs, SEC, D, TP_M, SL_M

pd.set_option("display.width", 250)
pd.set_option("display.max_columns", 40)
pd.set_option("display.max_rows", 400)


def table(tf):
    tot = pickle.load(open(os.path.join(D, f"sim_{tf}.pkl"), "rb"))
    cfgs = configs(tf)
    rows = []
    for (vi, side), a in tot.items():
        name, unit, kind, prm = VARIANTS[vi]
        for ci, (tp, sl, hb) in enumerate(cfgs):
            n = a["n"][ci]
            if n == 0:
                continue
            nis, noos = a["nis"][ci], a["noos"][ci]
            ais = a["sis"][ci] / nis if nis else np.nan
            aoos = a["soos"][ci] / noos if noos else np.nan
            var_oos = a["ssoos"][ci] / noos - aoos ** 2 if noos else np.nan
            var_is = a["ssis"][ci] / nis - ais ** 2 if nis else np.nan
            rows.append(dict(
                tf=tf, name=name, prm=",".join(f"{k}={v:g}" for k, v in prm), side="L" if side > 0 else "S",
                vi=vi, unit=unit, tp=tp, sl=sl, hb=hb, hold_max_h=hb * SEC[tf] / 3600,
                n=n, avg=a["s"][ci] / n, win=a["w"][ci] / n,
                pf=a["sw"][ci] / -a["sl_"][ci] if a["sl_"][ci] < 0 else np.inf,
                nis=nis, avg_is=ais, t_is=ais / math.sqrt(var_is / nis) if nis > 1 and var_is > 0 else np.nan,
                noos=noos, avg_oos=aoos, t_oos=aoos / math.sqrt(var_oos / noos) if noos > 1 and var_oos > 0 else np.nan,
                pf_oos=a["swo"][ci] / -a["slo"][ci] if a["slo"][ci] < 0 else np.inf,
                win_oos=a["wo"][ci] / noos if noos else np.nan,
                mon_pos=int((a["mon"][ci] > 0).sum()), mon_pos_oos=int((a["mon"][ci, 7:] > 0).sum()),
                hold_h=a["hold"][ci] / n * SEC[tf] / 3600, ncr=a["ncr"][ci], scr=a["scr"][ci],
                total=a["s"][ci], var_is=var_is, var_oos=var_oos,
            ))
    return pd.DataFrame(rows)


def walk_forward(df, min_is=30, min_oos=30):
    """手法 (時間足・手法・パラメーター・方向) ごとに、前半の t 値が一番高い決済を選ぶ。"""
    out = []
    for key, g in df.groupby(["tf", "name", "prm", "side"]):
        g = g[(g.nis >= min_is)]
        if g.empty:
            continue
        best = g.sort_values("t_is", ascending=False).iloc[0]
        # 近くの設定 (利確・損切りが 1 段ずつ隣、同じ最長保有) の後半の平均
        ti, si = TP_M.index(best.tp), SL_M.index(best.sl)
        nb = g[(g.hb == best.hb) & g.tp.isin(TP_M[max(0, ti - 1):ti + 2]) & g.sl.isin(SL_M[max(0, si - 1):si + 2])]
        row = best.to_dict()
        row["nb_oos_med"] = float(nb.avg_oos.median())
        out.append(row)
    return pd.DataFrame(out)


if __name__ == "__main__":
    tfs = sys.argv[1:]
    df = pd.concat([table(tf) for tf in tfs])
    df.to_pickle(os.path.join(D, "sel_all_" + "_".join(tfs) + ".pkl"))
    wf = walk_forward(df)
    wf.to_pickle(os.path.join(D, "sel_wf_" + "_".join(tfs) + ".pkl"))
    c = ["tf", "name", "prm", "side", "tp", "sl", "hold_max_h", "nis", "avg_is", "t_is", "noos", "avg_oos", "t_oos", "pf_oos", "win_oos", "mon_pos_oos", "nb_oos_med", "hold_h"]
    ok = wf[(wf.noos >= 30) & (wf.avg_oos > 0)].sort_values("t_oos", ascending=False)
    print("strategies", len(wf), "OOS positive", len(ok), "t_oos>=2", int((ok.t_oos >= 2).sum()))
    print(ok.head(40).round(4)[c].to_string())
