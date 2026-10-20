# Surgical-Procedure Infections in Colombia — a PostgreSQL project

A relational model and SQL analysis of Colombia's national surveillance of **infections associated with medical-surgical procedures (IAPMQ)**, 2021 – June 2026, built from open data published by the national public-health surveillance system (Sivigila).

The raw file is a spreadsheet-style export: two tables stacked in one CSV, decimal commas, a legacy encoding, placeholder rows for months that haven't happened, and totals that don't add up. This project turns it into a clean, constrained schema, documents what was wrong with the source, and answers 19 questions with SQL.

![ERD](docs/erd.png)

## Data

| File | Content |
|---|---|
| `data/iapmq_monthly.csv` | Monthly detail: cases, procedures, rate, and cases by sex × life stage for 6 procedures, plus "Total año" rows |
| `data/iapmq_annual_summary.csv` | Annual rate and year-over-year % change per procedure (second table of the original CSV) |
| `data/metadata_iapmq.csv` | Publisher's data dictionary |

Procedures: Colecistectomía (gallbladder removal), Revascularización miocárdica (heart bypass), Herniorrafía (hernia repair), Cesárea, Endometritis Post-Cesárea, Endometritis Post-Parto.
**Rate** = new infections per 100 surveilled procedures. The data is national and aggregated: there is no hospital, region or patient level.

The original CSVs were cp1252 and `;`-delimited. I converted them to UTF-8, split the two tables at the blank separator row, and made no other edits.

## Set up on your computer

Works on Windows, macOS and Linux. You need **PostgreSQL 14 or newer** (running) and **Python 3.10 or newer**. Nothing else; the setup script does not need the `psql` command-line tool.

**1. Get the files.** `git clone <repository-url>`, or download the ZIP from the repository page and unzip it. Open a terminal (Windows: PowerShell) **inside the project folder**.

**2. Have a PostgreSQL server running.** If you already have one, skip this.
- Windows / macOS: install from <https://www.postgresql.org/download/> (the installer asks you to choose a password for the `postgres` user; remember it). On macOS, [Postgres.app](https://postgresapp.com) is a simpler alternative.
- Linux (Debian/Ubuntu): `sudo apt install postgresql`, then set a password: `sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'choose-a-password';"`
- With Docker: `docker run --name iapmq-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 -d postgres:16`

**3. Install the Python packages** in a virtual environment:

```bash
# macOS / Linux
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```
```powershell
# Windows (PowerShell)
py -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

**4. Tell the scripts how to reach your database** with the `DATABASE_URL` variable. Replace `YOUR_PASSWORD` with the password from step 2 (the database `iapmq` is created for you if it doesn't exist):

```bash
# macOS / Linux
export DATABASE_URL="postgresql+psycopg2://postgres:YOUR_PASSWORD@localhost:5432/iapmq"
```
```powershell
# Windows (PowerShell)
$env:DATABASE_URL = "postgresql+psycopg2://postgres:YOUR_PASSWORD@localhost:5432/iapmq"
```
```bat
:: Windows (cmd.exe)
set DATABASE_URL=postgresql+psycopg2://postgres:YOUR_PASSWORD@localhost:5432/iapmq
```

The variable lasts for the current terminal window only; set it again when you open a new one. If your password contains `@ : / # %`, URL-encode those characters (for example `@` becomes `%40`).

**5. Build the database and make the charts:**

```bash
python setup_db.py            # creates the database, schema, loads the data
python viz/make_charts.py     # writes the PNG charts to docs/charts/
```

(On Windows you can use `py` instead of `python` if `python` isn't found.) `setup_db.py` can be run from any folder and prints the row counts at the end: 396 monthly rows, 4,752 demographic rows (396 × 12) and 44 data-quality notes. Running it again is safe: it drops and rebuilds only the tables and views this project defines, so use a database dedicated to it.

**6. Explore.** Connect to the `iapmq` database with any SQL client (pgAdmin, DBeaver, DataGrip, VS Code, `psql`) and run the queries in `sql/03_queries.sql`, one at a time.

### Alternative: plain `psql`

If you prefer the command line and have `psql`, run these **from the project folder** (the `\copy` paths in `02_import.sql` are relative to it):

```bash
createdb -U postgres iapmq
psql -U postgres -d iapmq -f sql/01_schema.sql     # tables, constraints, views
psql -U postgres -d iapmq -f sql/02_import.sql     # \copy + clean + load + data-quality log
psql -U postgres -d iapmq -f sql/03_queries.sql    # the 19 analysis queries
```

### Troubleshooting

| Message or symptom | Likely cause and fix |
|---|---|
| `password authentication failed` | Wrong user or password in `DATABASE_URL`. |
| `connection refused` / `could not connect to server` | The PostgreSQL server isn't running, or it uses another port (some installs use 5433). Start it, or change `5432` in the URL. |
| `permission denied to create database` | Your user can't create databases. Create `iapmq` yourself (or ask an admin), then run `setup_db.py` again; it only creates the database when it is missing. |
| `ModuleNotFoundError` | The virtual environment isn't active, or step 3 was skipped. |
| `pip` fails while installing `psycopg2-binary` | Use Python 3.10 to 3.13; very new Python versions sometimes have no prebuilt package yet. |
| `DATABASE_URL` seems ignored | It was set in a different terminal window. Set it again in the one you are running from. |
| Accented letters look broken in the Windows console | Cosmetic only; the data is stored correctly as UTF-8. |

## Design

| Layer | Tables | Purpose |
|---|---|---|
| Staging | `stg_monthly`, `stg_annual` | Raw CSV as text, loaded with `COPY` |
| Dimensions | `surgical_procedure`, `life_stage` | Procedure list with a surgical/obstetric category; the six Colombian "curso de vida" age bands |
| Facts | `monthly_surveillance`, `monthly_cases_demographic` | One row per procedure-month; sex × age counts in tidy (long) form |
| As published | `reported_year_total`, `reported_annual_summary` | Kept only to reconcile against figures recomputed from the months |
| Quality log | `data_quality_notes` | Every anomaly found while loading |
| Views | `v_annual_rate`, `v_yoy_change`, `v_annual_reconciliation`, `v_annual_rate_by_sex` | Annual rates recomputed from months, year-over-year change, published-vs-recomputed comparison, each sex's contribution to the rate |

Choices worth noting:
- `rate_per_100` is a **generated column** (`cases * 100.0 / procedures_done`), so it can't drift from its inputs.
- Constraints enforce what the data should satisfy: `UNIQUE (year, month, procedure)`, `cases <= procedures_done`, `procedures_done > 0`, and a three-column primary key on the demographic table.
- The 12 sex/age columns are unpivoted into 12 rows per month so grouping by sex or age band is a plain `GROUP BY`.
- "Total año" rows and empty future months are **not** loaded into the fact table.

## Problems found in the source data

1. **"Total año" rows are unreliable.** In 35 of 36 procedure-years they don't equal the sum of the months. In 2026 the totals match the monthly sums but sit on the wrong procedure labels (five of six are rotated). The cause for 2021–2025 is unknown. All annual figures here are recomputed from the months.
2. **The annual summary inherits that problem.** 14 of 30 full-year rates differ from the recomputed ones by more than 0.05 points; the largest gap is Revascularización miocárdica (4.34 published vs 3.80 recomputed for 2021).
3. **One sign error** in the published year-over-year column: Colecistectomía 2022 shows +21.7 %, but the rate fell from 0.23 to 0.18 (−21.7 %).
4. **Placeholder rows:** Endometritis Post-Parto has 5 empty rows for Aug–Dec 2026. Other procedures stop at June 2026. These are skipped.
5. **Four months where the sex/age counts exceed the case count by 1 to 2** (Colecistectomía 2021-08, 2023-02, 2023-06; Endometritis Post-Parto 2024-05). They are kept and logged.
6. **Cesárea and Endometritis Post-Cesárea share a denominator** every month, so procedure counts must not be summed across procedures.
7. **The publisher's metadata is partly copied from another indicator.** The definition, target and formula describe device-associated infections per 1,000 device-days, while the column descriptions and the data describe IAPMQ per 100 procedures. I followed the column descriptions and the data.

## What the queries show

Full list with the question for each in [`sql/03_queries.sql`](sql/03_queries.sql). A few results (full years 2021–2025 unless noted):

- **Heart bypass has by far the highest rate**: about 4 infections per 100 procedures overall, against 0.3 – 0.7 for the others (Q7). Its cases fall almost entirely in the 60+ group (80 %, Q16).
- **Rates rose from 2021 to 2024 for most procedures** (Cesárea 0.44 → 1.07, Herniorrafía 0.26 → 0.64; Q6), and the fitted monthly trend is positive for all six (Q9), though weak for Revascularización miocárdica and Endometritis Post-Cesárea (R² below 0.05). The jump in Herniorrafía's denominator between 2021 and 2022 (17,867 → 27,611) suggests that part of this may be changing hospital participation rather than real incidence. The data can't separate the two.
- **No seasonal pattern**: the pooled rate varies only between 0.44 and 0.52 across calendar months (Q10).
- **Volume and rate are mostly unrelated**, except Herniorrafía, where busier months have higher rates (r = 0.54; Q13).
- **Sex is consistent with the procedures**: all three obstetric procedures are 100 % women, so the demographic data passes a basic plausibility check (Q15).
- **Heart bypass infections are mostly in men** (68 % of cases), while gallbladder and hernia cases are close to an even split (Q15, Q19). Because the source has no procedure counts by sex, this can't say whether men are at higher risk or simply have more heart bypasses.
- **January–June 2026 vs 2025**: Revascularización miocárdica is down from 5.83 to 3.57 and Colecistectomía up from 0.41 to 0.59 (Q8). These are small monthly counts, so expect noise.

## Charts (Python)

`viz/make_charts.py` reads straight from the PostgreSQL tables and views (all aggregation is SQL; pandas and matplotlib only draw) and writes six PNGs to `docs/charts/`. Setup instructions are in [Set up on your computer](#set-up-on-your-computer).

| Chart | Question |
|---|---|
| `01_monthly_rate_by_procedure.png` | How did each procedure's monthly rate move over time? |
| `02_pooled_rate_by_procedure.png` | Which procedures have the highest infection rate? |
| `03_age_profile.png` | In which life stages do the cases fall? |
| `04_sex_split.png` | Does the sex split make sense for each procedure? |
| `06_rate_contribution_by_sex.png` | How much of each procedure's infection rate comes from women and from men, by year? |
| `05_published_vs_recomputed.png` | How far do the publisher's annual rates drift from its own monthly data? |

![Monthly rates](docs/charts/01_monthly_rate_by_procedure.png)
![Contribution by sex](docs/charts/06_rate_contribution_by_sex.png)
![Published vs recomputed](docs/charts/05_published_vs_recomputed.png)

Colors come from a validated categorical palette (blue and orange pass the color-blindness and contrast checks); single-series charts use one blue and de-emphasize context in gray.

## Limitations

- Aggregated national data: no inference about hospitals, regions or individual risk.
- **No infection rate by sex.** Cases are reported by sex, but the number of procedures is not, so a sex-specific rate can't be computed. Chart 06 shows each sex's *contribution* to the overall rate instead.
- Surveillance coverage may have changed over the period (see above), so trends are indicative.
- 2026 covers January – June only.
- Small monthly counts (often 10–40 cases) make single-month outliers fragile.

## Repository layout

```
data/   UTF-8 CSVs and the publisher's data dictionary
setup_db.py        one-command database setup (any OS)
requirements.txt   Python packages
sql/    01_schema.sql · 02_import.sql · 03_queries.sql
viz/    make_charts.py
docs/   erd.png (rendered from erd.mmd), charts/ (PNG output)
```

## Source

Vigilancia Epidemiológica de Infecciones Asociadas a la Atención en Salud (IAAS), evento Infecciones Asociadas a Procedimientos Médico-quirúrgicos (IAPMQ), Colombian open-data portal; underlying source: Sivigila.
