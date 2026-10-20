-- =====================================================================
-- IAPMQ surveillance database (Colombia, Sivigila) -- PostgreSQL schema
-- Run from the repository root:  psql -d iapmq -f sql/01_schema.sql
-- Re-runnable: drops everything it creates first.
-- =====================================================================

DROP VIEW  IF EXISTS v_annual_rate_by_sex, v_annual_reconciliation, v_yoy_change, v_annual_rate CASCADE;
DROP TABLE IF EXISTS data_quality_notes, monthly_cases_demographic,
                     monthly_surveillance, reported_annual_summary,
                     reported_year_total, life_stage, surgical_procedure,
                     stg_monthly, stg_annual CASCADE;

-- ---------------------------------------------------------------------
-- RAW / STAGING LAYER
-- Everything is TEXT so the CSV loads exactly as published (decimal
-- commas, blanks, etc.). Cleaning happens in 02_import.sql.
-- ---------------------------------------------------------------------
CREATE TABLE stg_monthly (
    ano                  TEXT,
    ordenador_mes        TEXT,
    mes                  TEXT,
    procedimiento        TEXT,
    numerador            TEXT,
    denominador          TEXT,
    tasa                 TEXT,
    hombre_primera_infancia TEXT,
    hombre_infancia      TEXT,
    hombre_adolescencia  TEXT,
    hombre_juventud      TEXT,
    hombre_adultez       TEXT,
    hombre_vejez         TEXT,
    mujer_primera_infancia  TEXT,
    mujer_infancia       TEXT,
    mujer_adolescencia   TEXT,
    mujer_juventud       TEXT,
    mujer_adultez        TEXT,
    mujer_vejez          TEXT,
    diferencia_porcentual TEXT
);

-- Same shape for the annual-summary block of the CSV.
CREATE TABLE stg_annual (LIKE stg_monthly);

-- ---------------------------------------------------------------------
-- DIMENSION TABLES
-- ---------------------------------------------------------------------
CREATE TABLE surgical_procedure (
    procedure_id  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name_es       VARCHAR(60) NOT NULL UNIQUE,
    category      VARCHAR(10) NOT NULL
                  CHECK (category IN ('surgical', 'obstetric'))
);

-- Colombian "curso de vida" age bands used by the source.
CREATE TABLE life_stage (
    life_stage_id SMALLINT PRIMARY KEY,
    code          VARCHAR(20) NOT NULL UNIQUE,
    name_es       VARCHAR(30) NOT NULL,
    age_min       SMALLINT NOT NULL,
    age_max       SMALLINT,                       -- NULL = no upper limit (60+)
    CHECK (age_max IS NULL OR age_max >= age_min)
);

INSERT INTO life_stage (life_stage_id, code, name_es, age_min, age_max) VALUES
    (1, 'PRIMERA_INFANCIA', 'Primera infancia',  0,  5),
    (2, 'INFANCIA',         'Infancia',          6, 12),
    (3, 'ADOLESCENCIA',     'Adolescencia',     13, 17),
    (4, 'JUVENTUD',         'Juventud',         18, 28),
    (5, 'ADULTEZ',          'Adultez',          29, 59),
    (6, 'VEJEZ',            'Vejez',            60, NULL);

-- ---------------------------------------------------------------------
-- FACT TABLES (clean, trusted layer)
-- ---------------------------------------------------------------------
-- One row per procedure per month that actually has reported data.
CREATE TABLE monthly_surveillance (
    surveillance_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_year      SMALLINT NOT NULL CHECK (report_year BETWEEN 2021 AND 2100),
    report_month     SMALLINT NOT NULL CHECK (report_month BETWEEN 1 AND 12),
    procedure_id     SMALLINT NOT NULL REFERENCES surgical_procedure (procedure_id),
    cases            INT NOT NULL CHECK (cases >= 0),
    procedures_done  INT NOT NULL CHECK (procedures_done > 0),
    -- New IAPMQ cases per 100 procedures; derived, never typed in.
    rate_per_100     NUMERIC GENERATED ALWAYS AS (cases * 100.0 / procedures_done) STORED,
    CONSTRAINT uq_month_proc UNIQUE (report_year, report_month, procedure_id),
    CONSTRAINT cases_not_above_procedures CHECK (cases <= procedures_done)
);

-- Long (tidy) version of the 12 sex x age-band columns: 12 rows per month.
CREATE TABLE monthly_cases_demographic (
    surveillance_id  INT NOT NULL
                     REFERENCES monthly_surveillance (surveillance_id) ON DELETE CASCADE,
    sex              CHAR(1) NOT NULL CHECK (sex IN ('M', 'F')),
    life_stage_id    SMALLINT NOT NULL REFERENCES life_stage (life_stage_id),
    cases            INT NOT NULL CHECK (cases >= 0),
    PRIMARY KEY (surveillance_id, sex, life_stage_id)
);

-- ---------------------------------------------------------------------
-- "AS PUBLISHED" TABLES -- kept only to reconcile against our own numbers
-- ---------------------------------------------------------------------
-- The "Total año" rows from the monthly block.
CREATE TABLE reported_year_total (
    report_year      SMALLINT NOT NULL,
    procedure_name   VARCHAR(60) NOT NULL,        -- label exactly as published
    cases            INT,
    procedures_done  INT,
    rate_per_100     NUMERIC,
    PRIMARY KEY (report_year, procedure_name)
);

-- The second table of the CSV: annual rate and year-over-year % change.
CREATE TABLE reported_annual_summary (
    report_year      SMALLINT NOT NULL,
    procedure_name   VARCHAR(60) NOT NULL,        -- includes 'Total procedimientos'
    annual_rate      NUMERIC,
    yoy_pct_diff     NUMERIC,
    PRIMARY KEY (report_year, procedure_name)
);

-- Free-form log of data problems found during the import.
CREATE TABLE data_quality_notes (
    note_id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    surveillance_id  INT REFERENCES monthly_surveillance (surveillance_id) ON DELETE CASCADE,
    issue_type       VARCHAR(40) NOT NULL,
    description      TEXT NOT NULL
);

-- ---------------------------------------------------------------------
-- VIEWS
-- ---------------------------------------------------------------------
-- Annual rate recomputed from the months (pooled: sum of cases / sum of procedures).
CREATE VIEW v_annual_rate AS
SELECT ms.report_year,
       p.procedure_id,
       p.name_es                                        AS procedure_name,
       COUNT(*)                                         AS months_reported,
       SUM(ms.cases)                                    AS cases,
       SUM(ms.procedures_done)                          AS procedures_done,
       ROUND(SUM(ms.cases) * 100.0 / SUM(ms.procedures_done), 4) AS annual_rate
FROM monthly_surveillance ms
JOIN surgical_procedure p ON p.procedure_id = ms.procedure_id
GROUP BY ms.report_year, p.procedure_id, p.name_es;

-- Year-over-year % change of the recomputed annual rate (self-join on year + 1).
-- NOTE: 2026 only has Jan-Jun, so its change vs a full year is not like-for-like.
CREATE VIEW v_yoy_change AS
SELECT cur.report_year,
       cur.procedure_name,
       prev.annual_rate AS previous_rate,
       cur.annual_rate  AS current_rate,
       ROUND((cur.annual_rate - prev.annual_rate) * 100.0 / prev.annual_rate, 1) AS pct_change,
       cur.months_reported
FROM v_annual_rate cur
JOIN v_annual_rate prev
  ON prev.procedure_id = cur.procedure_id
 AND prev.report_year  = cur.report_year - 1;

-- Our recomputed annual figures next to the two "as published" versions.
CREATE VIEW v_annual_reconciliation AS
SELECT a.report_year,
       a.procedure_name,
       a.cases                  AS cases_from_months,
       t.cases                  AS cases_in_total_row,
       a.procedures_done        AS procedures_from_months,
       t.procedures_done        AS procedures_in_total_row,
       a.annual_rate            AS rate_from_months,
       s.annual_rate            AS rate_in_annual_summary
FROM v_annual_rate a
LEFT JOIN reported_year_total      t ON t.report_year = a.report_year AND t.procedure_name = a.procedure_name
LEFT JOIN reported_annual_summary  s ON s.report_year = a.report_year AND s.procedure_name = a.procedure_name;

-- Each sex's contribution to the annual rate: cases in that sex per 100 procedures
-- (procedures of ALL patients). The source does not report procedures by sex, so
-- this is NOT a sex-specific rate; the two contributions add up to the overall rate
-- (up to the few months where sex/age counts exceed reported cases).
CREATE VIEW v_annual_rate_by_sex AS
SELECT a.report_year,
       a.procedure_name,
       s.sex,
       s.cases,
       a.procedures_done,
       ROUND(s.cases * 100.0 / a.procedures_done, 4) AS rate_contribution
FROM v_annual_rate a
JOIN (SELECT ms.report_year, ms.procedure_id, d.sex, SUM(d.cases) AS cases
      FROM monthly_cases_demographic d
      JOIN monthly_surveillance ms ON ms.surveillance_id = d.surveillance_id
      GROUP BY ms.report_year, ms.procedure_id, d.sex) s
  ON s.report_year = a.report_year AND s.procedure_id = a.procedure_id;
