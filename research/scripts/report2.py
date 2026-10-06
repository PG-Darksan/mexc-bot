# レポート用の表。sel_all_*.pkl (全設定) から、前半で選んで後半で確かめた結果をまとめる。
import os, sys, math
import numpy as np
import pandas as pd
from sim import D, TP_M, SL_M, COST

TFS = ["m5", "m15", "m30", "h1", "h4"]
TFN = {"m5": "5分足", "m15": "15分足", "m30": "30分足", "h1": "1時間足", "h4": "4時間足"}
FAM = {
    "bbtouch": "BB タッチ逆張り (足の途中で ±kσ に触れたら逆へ)",
    "bbfade": "BB 逆張り (足の終値が ±kσ の外)",
    "bbbreak": "BB ブレイク順張り (終値が ±kσ を抜けた方へ)",
    "donchian": "ドンチャン・ブレイク (直近 N 本の高値・安値を抜けた方へ)",
    "rsi2": "RSI(2) 逆張り (200EMA の向きに合わせる版と合わせない版)",
    "emacross": "EMA クロス順張り (9/21, 20/50)",
    "spikefade": "急騰・急落の逆張り (1 本で ATR の m 倍動いたら逆へ)",
    "spikefollow": "急騰・急落の順張り (同じ足で、動いた方へ)",
    "fundcollect": "資金調達の受け取り側 (調達率が極端な時、清算の 1 本前に受け取る側へ)",
    "fundfollow": "資金調達の支払い側 (同じ場面で、払う側 = 勢いの側へ)",
}


def load_all():
    df = pd.read_pickle(os.path.join(D, "sel_all_" + "_".join(TFS) + ".pkl")).reset_index(drop=True)
    return df


def var_from(df, prefix):
    return df[f"var_{prefix}"]


def walk_forward(df, shift=0.0, min_is=30):
    """費用を shift だけ減らした (正なら安くした) ときの、前半で選んで後半で確かめた結果。"""
    d = df[df.nis >= min_is].copy()
    vis = var_from(d, "is")
    voos = var_from(d, "oos")
    d["avg_is"] = d.avg_is + shift
    d["avg_oos"] = d.avg_oos + shift
    d["t_is"] = d.avg_is / np.sqrt(vis / d.nis)
    d["t_oos"] = d.avg_oos / np.sqrt(voos / d.noos)
    idx = d.groupby(["tf", "name", "prm", "side"])["t_is"].idxmax()
    return d.loc[idx.dropna()]


if __name__ == "__main__":
    df = load_all()
    print("設定の総数", len(df), "手法 (時間足×手法×パラメーター×向き)", df.groupby(["tf", "name", "prm", "side"]).ngroups)
    wf = walk_forward(df)
    ok = (wf.noos >= 30) & (wf.avg_oos > 0)
    sig = ok & (wf.t_oos >= 2)
    print("\n## 手法ごと")
    rows = []
    for name, g in wf.groupby("name"):
        okg = g[(g.noos >= 30) & (g.avg_oos > 0)]
        best = g.sort_values("t_oos", ascending=False).iloc[0]
        rows.append(dict(family=name, inst=len(g), oos_pos=len(okg), t2=int((okg.t_oos >= 2).sum()),
                         best=f"{best.tf} {best.prm} {best.side} 後半 {best.avg_oos*100:+.2f}% (t={best.t_oos:.1f}, n={int(best.noos)})",
                         med_oos=g.avg_oos.median()))
    print(pd.DataFrame(rows).to_string())
    print("\n## 費用を変えたとき (後半で黒字 & t>=2 の手法の数)")
    for label, shift in (("実費用 0.26%", 0.0), ("滑りなし 0.16%", 0.001), ("費用なし 0%", COST)):
        w = walk_forward(df, shift)
        m = (w.noos >= 30) & (w.avg_oos > 0)
        print(label, "後半黒字", int(m.sum()), "/", len(w), " t>=2:", int((m & (w.t_oos >= 2)).sum()))
    print("\n## 時間足ごと (手法ごとに後半の平均の中央値)")
    print(wf.pivot_table(index="name", columns="tf", values="avg_oos", aggfunc="median").mul(100).round(2).to_string())
    print("\n## 後半で黒字の上位")
    c = ["tf", "name", "prm", "side", "tp", "sl", "hold_max_h", "nis", "avg_is", "t_is", "noos", "avg_oos", "t_oos", "pf_oos", "win_oos", "hold_h"]
    print(wf[ok].sort_values("t_oos", ascending=False).head(25).round(4)[c].to_string())
