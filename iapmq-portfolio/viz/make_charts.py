"""
Charts for the IAPMQ PostgreSQL project.

Every number is pulled from the database with SQL (tables and views from
sql/01_schema.sql); pandas/matplotlib only reshape and draw.

Usage (from the repository root):
    pip install -r requirements.txt
    export DATABASE_URL="postgresql+psycopg2://USER:PASSWORD@localhost:5432/iapmq"
    python viz/make_charts.py            # writes PNGs to docs/charts/
"""
import os
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.colors import LinearSegmentedColormap
from sqlalchemy import create_engine, text
from sqlalchemy.exc import OperationalError

OUT = Path(__file__).resolve().parent.parent / "docs" / "charts"
OUT.mkdir(parents=True, exist_ok=True)
engine = create_engine(os.environ.get("DATABASE_URL", "postgresql+psycopg2://postgres@localhost:5432/iapmq"))

# ---- design tokens (validated light-mode palette; see README) -------------
SURFACE, INK, INK2, MUTED = "#fcfcfb", "#0b0b0b", "#52514e", "#898781"
GRID, BASE = "#e1e0d9", "#c3c2b7"
BLUE, ORANGE, GRAY = "#2a78d6", "#eb6834", "#c3c2b7"
BLUE_RAMP = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]
SEQ = LinearSegmentedColormap.from_list("blue_seq", BLUE_RAMP)

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "font.family": "sans-serif", "font.sans-serif": ["Segoe UI", "Helvetica", "Arial", "DejaVu Sans"],
    "text.color": INK, "axes.labelcolor": INK2, "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.edgecolor": BASE, "axes.linewidth": 1, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": False, "xtick.labelsize": 9, "ytick.labelsize": 9,
})

EN = {  # English labels for the Spanish procedure / life-stage names
    "Cesárea": "Cesarean section", "Colecistectomía": "Gallbladder removal",
    "Endometritis Post-Cesárea": "Endometritis after cesarean", "Endometritis Post-Parto": "Endometritis after delivery",
    "Herniorrafía": "Hernia repair", "Revascularización miocárdica": "Heart bypass",
}
STAGE_EN = {"Primera infancia": "Early childhood\n0-5", "Infancia": "Childhood\n6-12",
            "Adolescencia": "Adolescence\n13-17", "Juventud": "Youth\n18-28",
            "Adultez": "Adulthood\n29-59", "Vejez": "Older adults\n60+"}


def q(sql):
    try:
        with engine.connect() as c:
            return pd.read_sql(text(sql), c)
    except OperationalError as e:
        raise SystemExit(f"Could not connect to PostgreSQL:\n{e}\nRun `python setup_db.py` first and set "
                         "DATABASE_URL (see the README, section 'Set up on your computer').")


def title(fig, main, sub, y=0.985):
    fig.text(0.02, y, main, fontsize=15, fontweight="bold", color=INK, ha="left", va="top")
    fig.text(0.02, y - 0.055, sub, fontsize=10, color=INK2, ha="left", va="top")


def style_axes(ax, ygrid=True):
    ax.spines["left"].set_visible(False)
    ax.tick_params(length=0)
    if ygrid:
        ax.yaxis.grid(True, color=GRID, linewidth=1)
        ax.set_axisbelow(True)


# ===========================================================================
# 1. Monthly rate per procedure (small multiples, own y-scale each)
# ===========================================================================
def chart_monthly():
    df = q("""SELECT p.name_es AS procedure, ms.report_year, ms.report_month,
                     ms.rate_per_100::float AS rate
              FROM monthly_surveillance ms JOIN surgical_procedure p USING (procedure_id)
              ORDER BY p.name_es, ms.report_year, ms.report_month""")
    df["date"] = pd.to_datetime(dict(year=df.report_year, month=df.report_month, day=1))
    order = (df.groupby("procedure").rate.mean().sort_values(ascending=False).index)
    fig, axes = plt.subplots(2, 3, figsize=(12, 6.6))
    fig.subplots_adjust(top=0.82, bottom=0.07, left=0.06, right=0.97, hspace=0.42, wspace=0.28)
    for ax, proc in zip(axes.flat, order):
        d = df[df.procedure == proc].copy()
        d["roll"] = d.rate.rolling(6, min_periods=6).mean()
        ax.plot(d.date, d.rate, color=GRAY, lw=1, solid_capstyle="round")
        ax.plot(d.date, d.roll, color=BLUE, lw=2, solid_capstyle="round", solid_joinstyle="round")
        last = d.dropna(subset=["roll"]).iloc[-1]
        ax.scatter([last.date], [last.roll], s=50, color=BLUE, edgecolor=SURFACE, linewidth=2, zorder=5)
        ax.set_ylim(0, d.rate.max() * 1.15)
        ax.set_title(EN[proc], loc="left", fontsize=10.5, fontweight="bold", color=INK, pad=6)
        style_axes(ax)
        ax.xaxis.set_major_locator(matplotlib.dates.YearLocator())
        ax.xaxis.set_major_formatter(matplotlib.dates.DateFormatter("%Y"))
        ax.spines["bottom"].set_color(BASE)
        ax.set_xlim(d.date.min() - pd.Timedelta(days=20), d.date.max() + pd.Timedelta(days=170))
        ax.annotate(f"{last.roll:.2f}", (last.date, last.roll), xytext=(8, 0), textcoords="offset points",
                    ha="left", va="center", fontsize=9, color=INK, fontweight="bold")
    title(fig, "Most procedures show rising infection rates since 2021, with heavy month-to-month noise",
          "New infections per 100 procedures, by month. Grey: monthly rate. Blue: 6-month average. "
          "Each panel has its own scale. Data: Jan 2021 - Jun 2026.")
    fig.savefig(OUT / "01_monthly_rate_by_procedure.png", dpi=170)
    plt.close(fig)


# ===========================================================================
# 2. Pooled rate per procedure (bars)
# ===========================================================================
def chart_pooled():
    df = q("""SELECT p.name_es AS procedure, SUM(ms.cases) AS cases, SUM(ms.procedures_done) AS procs,
                     SUM(ms.cases) * 100.0 / SUM(ms.procedures_done) AS rate
              FROM monthly_surveillance ms JOIN surgical_procedure p USING (procedure_id)
              GROUP BY p.name_es ORDER BY rate""")
    fig, ax = plt.subplots(figsize=(10, 4.6))
    fig.subplots_adjust(top=0.78, bottom=0.1, left=0.27, right=0.93)
    y = np.arange(len(df))
    ax.barh(y, df.rate, height=0.5, color=BLUE)
    ax.set_yticks(y, [EN[p] for p in df.procedure], fontsize=10, color=INK)
    for yi, r, c, n in zip(y, df.rate, df.cases, df.procs):
        ax.text(r + 0.06, yi, f"{r:.2f}", va="center", fontsize=10, color=INK, fontweight="bold")
        ax.text(4.9, yi, f"{int(c):,} cases / {int(n):,} procedures", va="center", fontsize=8.5, color=INK2)
    ax.set_xlim(0, 7.4)
    ax.set_xticks(range(0, 5))
    ax.xaxis.grid(True, color=GRID, linewidth=1); ax.set_axisbelow(True)
    ax.spines["left"].set_color(BASE); ax.spines["bottom"].set_visible(False)
    ax.tick_params(length=0)
    ax.set_xlabel("Infections per 100 procedures, Jan 2021 - Jun 2026 pooled")
    title(fig, "Heart bypass has 5 to 14 times the infection rate of the other procedures",
          "Pooled over the whole period: total cases / total procedures x 100.", y=0.97)
    fig.savefig(OUT / "02_pooled_rate_by_procedure.png", dpi=170)
    plt.close(fig)


# ===========================================================================
# 3. Age profile heatmap (share of each procedure's cases by life stage)
# ===========================================================================
def chart_age():
    df = q("""SELECT p.name_es AS procedure, l.name_es AS stage, l.life_stage_id, SUM(d.cases) AS cases
              FROM monthly_cases_demographic d
              JOIN monthly_surveillance ms USING (surveillance_id)
              JOIN surgical_procedure p USING (procedure_id)
              JOIN life_stage l USING (life_stage_id)
              GROUP BY p.name_es, l.name_es, l.life_stage_id""")
    piv = df.pivot(index="procedure", columns="life_stage_id", values="cases").fillna(0)
    pct = piv.div(piv.sum(axis=1), axis=0) * 100
    stages = df.drop_duplicates("life_stage_id").sort_values("life_stage_id").stage.tolist()
    order = ["Revascularización miocárdica", "Colecistectomía", "Herniorrafía",
             "Cesárea", "Endometritis Post-Cesárea", "Endometritis Post-Parto"]
    pct = pct.loc[order]
    fig, ax = plt.subplots(figsize=(10.5, 5.2))
    fig.subplots_adjust(top=0.76, bottom=0.04, left=0.25, right=0.97)
    vmax = 100
    ax.imshow(pct.values, cmap=SEQ, vmin=0, vmax=vmax, aspect="auto")
    for i in range(pct.shape[0]):
        for j in range(pct.shape[1]):
            v = pct.values[i, j]
            ax.text(j, i, "-" if v == 0 else f"{v:.0f}%", ha="center", va="center", fontsize=10,
                    color="#ffffff" if v > 55 else INK)
    ax.set_xticks(range(6), [STAGE_EN[s] for s in stages], fontsize=9, color=INK2)
    ax.set_yticks(range(len(order)), [EN[p] for p in order], fontsize=10, color=INK)
    ax.xaxis.tick_top()
    ax.set_xticks(np.arange(-0.5, 6, 1), minor=True); ax.set_yticks(np.arange(-0.5, len(order), 1), minor=True)
    ax.grid(which="minor", color=SURFACE, linewidth=2); ax.tick_params(which="both", length=0)
    for s in ax.spines.values():
        s.set_visible(False)
    title(fig, "Surgical infections skew to older adults; obstetric ones to ages 18-59",
          "Share of each procedure's cases by life stage (rows add to 100%; '-' = no cases).", y=0.97)
    fig.savefig(OUT / "03_age_profile.png", dpi=170)
    plt.close(fig)


# ===========================================================================
# 4. Sex split (100% stacked)
# ===========================================================================
def chart_sex():
    df = q("""SELECT p.name_es AS procedure,
                     SUM(d.cases) FILTER (WHERE d.sex = 'F') AS women,
                     SUM(d.cases) FILTER (WHERE d.sex = 'M') AS men
              FROM monthly_cases_demographic d
              JOIN monthly_surveillance ms USING (surveillance_id)
              JOIN surgical_procedure p USING (procedure_id)
              GROUP BY p.name_es""")
    df["pf"] = df.women * 100.0 / (df.women + df.men)
    df = df.sort_values("pf").reset_index(drop=True)
    fig, ax = plt.subplots(figsize=(10, 4.4))
    fig.subplots_adjust(top=0.76, bottom=0.14, left=0.27, right=0.97)
    y = np.arange(len(df))
    ax.barh(y, df.pf, height=0.5, color=BLUE, edgecolor=SURFACE, linewidth=2, label="Women")
    ax.barh(y, 100 - df.pf, left=df.pf, height=0.5, color=ORANGE, edgecolor=SURFACE, linewidth=2, label="Men")
    for yi, pf in zip(y, df.pf):
        ax.text(pf / 2, yi, f"{pf:.0f}%", ha="center", va="center", color="#ffffff", fontsize=10, fontweight="bold")
        if 100 - pf >= 10:
            ax.text(pf + (100 - pf) / 2, yi, f"{100 - pf:.0f}%", ha="center", va="center", color="#ffffff",
                    fontsize=10, fontweight="bold")
    ax.set_yticks(y, [EN[p] for p in df.procedure], fontsize=10, color=INK)
    ax.set_xlim(0, 100); ax.set_xticks([])
    for s in ax.spines.values():
        s.set_visible(False)
    ax.tick_params(length=0)
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, -0.12), ncol=2, frameon=False, fontsize=10)
    title(fig, "The sex split matches the procedures: obstetric cases are 100% women",
          "Share of cases by sex, Jan 2021 - Jun 2026. A basic plausibility check on the demographic columns.", y=0.97)
    fig.savefig(OUT / "04_sex_split.png", dpi=170)
    plt.close(fig)


# ===========================================================================
# 5. Published vs recomputed annual rates (data-quality finding)
# ===========================================================================
def chart_reconciliation():
    df = q("""SELECT procedure_name AS procedure, report_year AS yr, rate_from_months::float AS mine,
                     rate_in_annual_summary::float AS published
              FROM v_annual_reconciliation
              WHERE report_year <= 2025 AND rate_in_annual_summary IS NOT NULL
                AND procedure_name <> 'Total procedimientos'""")
    df["gap"] = (df.published - df.mine) / df.mine * 100
    order = df.groupby("procedure").gap.apply(lambda s: s.abs().max()).sort_values().index.tolist()
    fig, ax = plt.subplots(figsize=(10, 5))
    fig.subplots_adjust(top=0.77, bottom=0.12, left=0.27, right=0.95)
    ax.axvline(0, color=BASE, lw=1.5, zorder=1)
    for i, proc in enumerate(order):
        d = df[df.procedure == proc]
        ax.scatter(d.gap, [i] * len(d), s=64, color=BLUE, edgecolor=SURFACE, linewidth=2, zorder=3)
    worst = df.loc[df.gap.abs().nlargest(2).index]
    for _, r in worst.iterrows():
        i = order.index(r.procedure)
        ax.annotate(f"{int(r.yr)}: {r.gap:+.0f}%", (r.gap, i), xytext=(0, 11), textcoords="offset points",
                    ha="center", fontsize=9, color=INK2)
    ax.set_yticks(range(len(order)), [EN[p] for p in order], fontsize=10, color=INK)
    ax.xaxis.grid(True, color=GRID, linewidth=1); ax.set_axisbelow(True)
    for s in ax.spines.values():
        s.set_visible(False)
    ax.tick_params(length=0)
    ax.xaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(decimals=0))
    ax.set_xlabel("Published annual rate vs rate recomputed from the months (each dot = one year, 2021-2025)")
    title(fig, "Published annual rates drift from what the monthly data adds up to",
          "Gap between the publisher's annual rate and the pooled rate recomputed from its own monthly rows. 0% = they agree.", y=0.97)
    fig.savefig(OUT / "05_published_vs_recomputed.png", dpi=170)
    plt.close(fig)


# ===========================================================================
# 6. Contribution to the infection rate by sex (stacked columns per year)
# ===========================================================================
def chart_sex_contribution():
    df = q("""SELECT procedure_name AS procedure, report_year AS yr, sex, rate_contribution::float AS r
              FROM v_annual_rate_by_sex""")
    piv = df.pivot_table(index=["procedure", "yr"], columns="sex", values="r", fill_value=0).reset_index()
    order = (piv.assign(t=piv.F + piv.M).groupby("procedure").t.mean().sort_values(ascending=False).index)
    years = sorted(piv.yr.unique())
    labels = [str(y) if y < 2026 else "2026\n(Jan-Jun)" for y in years]
    fig, axes = plt.subplots(2, 3, figsize=(12, 6.9))
    fig.subplots_adjust(top=0.80, bottom=0.08, left=0.06, right=0.97, hspace=0.5, wspace=0.28)
    for ax, proc in zip(axes.flat, order):
        d = piv[piv.procedure == proc].set_index("yr").reindex(years)
        x = np.arange(len(years))
        ax.bar(x, d.F, width=0.34, color=BLUE, edgecolor=SURFACE, linewidth=2)
        ax.bar(x, d.M, width=0.34, bottom=d.F, color=ORANGE, edgecolor=SURFACE, linewidth=2)
        ax.set_xticks(x, labels, fontsize=8)
        ax.set_ylim(0, (d.F + d.M).max() * 1.12)
        ax.set_title(EN[proc], loc="left", fontsize=10.5, fontweight="bold", color=INK, pad=6)
        style_axes(ax)
        ax.spines["bottom"].set_color(BASE)
    handles = [plt.Rectangle((0, 0), 1, 1, color=BLUE), plt.Rectangle((0, 0), 1, 1, color=ORANGE)]
    fig.legend(handles, ["Women", "Men"], loc="upper right", bbox_to_anchor=(0.97, 0.995), ncol=2,
               frameon=False, fontsize=10)
    title(fig, "Who contributes to each procedure's infection rate: women vs men",
          "Infections per 100 procedures, split by the sex of the infected patient. Each column adds up to the procedure's "
          "overall rate.\nThe source does not report procedures by sex, so this is each group's contribution, not a sex-specific risk. "
          "Each panel has its own scale.")
    fig.savefig(OUT / "06_rate_contribution_by_sex.png", dpi=170)
    plt.close(fig)


if __name__ == "__main__":
    for fn in (chart_monthly, chart_pooled, chart_age, chart_sex, chart_sex_contribution, chart_reconciliation):
        fn()
        print("done:", fn.__name__)
