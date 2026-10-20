-- =====================================================================
-- Import: CSV -> staging (raw text) -> clean tables
-- Run from the repository root (paths below are relative to it):
--   psql -d iapmq -f sql/02_import.sql
-- \copy runs on the client, so no server file permissions are needed.
-- =====================================================================

-- 1) Raw load. Files are UTF-8, ';'-delimited; empty cells become NULL.
\copy stg_monthly FROM 'data/iapmq_monthly.csv'         WITH (FORMAT csv, HEADER true, DELIMITER ';', ENCODING 'UTF8')
\copy stg_annual  FROM 'data/iapmq_annual_summary.csv'  WITH (FORMAT csv, HEADER true, DELIMITER ';', ENCODING 'UTF8')

-- 2) Dimension: procedures (category is our own classification).
INSERT INTO surgical_procedure (name_es, category)
SELECT DISTINCT procedimiento,
       CASE WHEN procedimiento IN ('Cesárea', 'Endometritis Post-Parto', 'Endometritis Post-Cesárea')
            THEN 'obstetric' ELSE 'surgical' END
FROM stg_monthly
ORDER BY procedimiento;

-- 3) Facts: real monthly rows only.
--    Excluded on purpose: 'Total año' rows (ordenador_mes = 13) and the empty
--    placeholder months at the end of 2026 (no numerador/denominador yet).
--    Decimal commas are irrelevant here: the rate is recomputed, not copied.
INSERT INTO monthly_surveillance (report_year, report_month, procedure_id, cases, procedures_done)
SELECT s.ano::SMALLINT, s.ordenador_mes::SMALLINT, p.procedure_id,
       s.numerador::INT, s.denominador::INT
FROM stg_monthly s
JOIN surgical_procedure p ON p.name_es = s.procedimiento
WHERE s.ordenador_mes::INT BETWEEN 1 AND 12
  AND s.numerador IS NOT NULL
  AND s.denominador IS NOT NULL;

-- 4) Unpivot the 12 sex x age-band columns into 12 rows per month.
INSERT INTO monthly_cases_demographic (surveillance_id, sex, life_stage_id, cases)
SELECT ms.surveillance_id, v.sex, v.life_stage_id, COALESCE(v.cases::INT, 0)
FROM stg_monthly s
JOIN surgical_procedure p      ON p.name_es = s.procedimiento
JOIN monthly_surveillance ms   ON ms.report_year   = s.ano::SMALLINT
                              AND ms.report_month  = s.ordenador_mes::SMALLINT
                              AND ms.procedure_id  = p.procedure_id
CROSS JOIN LATERAL (VALUES
    ('M'::CHAR(1), 1::SMALLINT, s.hombre_primera_infancia),
    ('M', 2, s.hombre_infancia),
    ('M', 3, s.hombre_adolescencia),
    ('M', 4, s.hombre_juventud),
    ('M', 5, s.hombre_adultez),
    ('M', 6, s.hombre_vejez),
    ('F', 1, s.mujer_primera_infancia),
    ('F', 2, s.mujer_infancia),
    ('F', 3, s.mujer_adolescencia),
    ('F', 4, s.mujer_juventud),
    ('F', 5, s.mujer_adultez),
    ('F', 6, s.mujer_vejez)
) AS v (sex, life_stage_id, cases)
WHERE s.ordenador_mes::INT BETWEEN 1 AND 12;

-- 5) "As published" tables (kept only for reconciliation).
INSERT INTO reported_year_total (report_year, procedure_name, cases, procedures_done, rate_per_100)
SELECT ano::SMALLINT, procedimiento, numerador::INT, denominador::INT,
       REPLACE(tasa, ',', '.')::NUMERIC
FROM stg_monthly
WHERE ordenador_mes::INT = 13;

INSERT INTO reported_annual_summary (report_year, procedure_name, annual_rate, yoy_pct_diff)
SELECT ano::SMALLINT, procedimiento,
       REPLACE(tasa, ',', '.')::NUMERIC,
       REPLACE(diferencia_porcentual, ',', '.')::NUMERIC
FROM stg_annual;

-- 6) Data-quality log.
-- 6a) sex/age counts that do not add up to the month's case count
INSERT INTO data_quality_notes (surveillance_id, issue_type, description)
SELECT ms.surveillance_id, 'demographics_sum_mismatch',
       'cases = ' || ms.cases || ' but sex/age counts add up to ' || d.total
FROM monthly_surveillance ms
JOIN (SELECT surveillance_id, SUM(cases) AS total
      FROM monthly_cases_demographic GROUP BY surveillance_id) d USING (surveillance_id)
WHERE d.total <> ms.cases;

-- 6b) published 'Total año' rows that disagree with the sum of the months
INSERT INTO data_quality_notes (issue_type, description)
SELECT 'total_row_mismatch',
       a.report_year || ' ' || a.procedure_name || ': published total row has ' ||
       t.cases || ' cases / ' || t.procedures_done || ' procedures; months add up to ' ||
       a.cases || ' / ' || a.procedures_done
FROM v_annual_rate a
JOIN reported_year_total t ON t.report_year = a.report_year AND t.procedure_name = a.procedure_name
WHERE t.cases <> a.cases OR t.procedures_done <> a.procedures_done;

-- 6c) rows we deliberately skipped
INSERT INTO data_quality_notes (issue_type, description)
SELECT 'placeholder_month_skipped',
       ano || '-' || ordenador_mes || ' ' || procedimiento || ': empty placeholder row, not loaded'
FROM stg_monthly
WHERE ordenador_mes::INT BETWEEN 1 AND 12 AND numerador IS NULL;

-- 7) Quick sanity output
SELECT 'surgical_procedure' AS tbl, COUNT(*) FROM surgical_procedure
UNION ALL SELECT 'monthly_surveillance',      COUNT(*) FROM monthly_surveillance
UNION ALL SELECT 'monthly_cases_demographic', COUNT(*) FROM monthly_cases_demographic
UNION ALL SELECT 'reported_year_total',       COUNT(*) FROM reported_year_total
UNION ALL SELECT 'reported_annual_summary',   COUNT(*) FROM reported_annual_summary
UNION ALL SELECT 'data_quality_notes',        COUNT(*) FROM data_quality_notes;
