-- =====================================================================
-- Analysis queries -- IAPMQ surveillance, Colombia (Sivigila 2021-2026)
-- Each query is headed by the question it answers.
-- Rate = new infections per 100 surveilled procedures.
-- NOTE: 2026 only covers January-June; avoid comparing it with full years.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. SANITY AND DATA QUALITY
-- ---------------------------------------------------------------------

-- Q1. Is every procedure covered for every month from 2021-01 to 2026-06?
--     (expected: 66 months for each of the 6 procedures)
SELECT p.name_es, COUNT(*) AS months_loaded
FROM monthly_surveillance ms
JOIN surgical_procedure p ON p.procedure_id = ms.procedure_id
GROUP BY p.name_es
ORDER BY p.name_es;

-- Q2. Do Cesárea and Endometritis Post-Cesárea always share the same
--     denominator? (Rows returned = months where they differ; expect 0.)
SELECT c.report_year, c.report_month, c.procedures_done AS cesarea, e.procedures_done AS endometritis_pc
FROM monthly_surveillance c
JOIN surgical_procedure pc ON pc.procedure_id = c.procedure_id AND pc.name_es = 'Cesárea'
JOIN monthly_surveillance e ON e.report_year = c.report_year AND e.report_month = c.report_month
JOIN surgical_procedure pe ON pe.procedure_id = e.procedure_id AND pe.name_es = 'Endometritis Post-Cesárea'
WHERE c.procedures_done <> e.procedures_done;

-- Q3. Which months have sex/age counts that do not add up to the reported cases?
SELECT n.issue_type, p.name_es, ms.report_year, ms.report_month, n.description
FROM data_quality_notes n
JOIN monthly_surveillance ms ON ms.surveillance_id = n.surveillance_id
JOIN surgical_procedure p    ON p.procedure_id = ms.procedure_id
WHERE n.issue_type = 'demographics_sum_mismatch'
ORDER BY ms.report_year, ms.report_month;

-- Q4. How far off are the published annual figures from what the months add up to?
--     (only rows where the published annual rate differs by more than 0.05 points)
SELECT report_year, procedure_name,
       rate_from_months, rate_in_annual_summary,
       ROUND(rate_in_annual_summary - rate_from_months, 3) AS difference
FROM v_annual_reconciliation
WHERE rate_in_annual_summary IS NOT NULL
  AND ABS(rate_in_annual_summary - rate_from_months) > 0.05
ORDER BY ABS(rate_in_annual_summary - rate_from_months) DESC;

-- Q5. Is the published year-over-year change consistent with the published annual rates?
--     Returns rows whose sign or size is off by more than 1 percentage point.
SELECT cur.report_year, cur.procedure_name,
       cur.yoy_pct_diff AS published_change,
       ROUND((cur.annual_rate - prev.annual_rate) * 100.0 / prev.annual_rate, 1) AS recomputed_change
FROM reported_annual_summary cur
JOIN reported_annual_summary prev
  ON prev.procedure_name = cur.procedure_name AND prev.report_year = cur.report_year - 1
WHERE ABS(cur.yoy_pct_diff - (cur.annual_rate - prev.annual_rate) * 100.0 / prev.annual_rate) > 1;

-- ---------------------------------------------------------------------
-- B. LEVELS AND TRENDS
-- ---------------------------------------------------------------------

-- Q6. What was the infection rate of each procedure in each full year (2021-2025)?
SELECT procedure_name, report_year, cases, procedures_done, annual_rate
FROM v_annual_rate
WHERE report_year <= 2025
ORDER BY procedure_name, report_year;

-- Q7. Which procedures carry the highest infection rate overall?
--     (pooled over the whole period, not an average of monthly rates)
SELECT p.name_es, p.category,
       SUM(ms.cases)           AS cases,
       SUM(ms.procedures_done) AS procedures,
       ROUND(SUM(ms.cases) * 100.0 / SUM(ms.procedures_done), 3) AS pooled_rate
FROM monthly_surveillance ms
JOIN surgical_procedure p ON p.procedure_id = ms.procedure_id
GROUP BY p.name_es, p.category
ORDER BY pooled_rate DESC;

-- Q8. Like-for-like: how did January-June 2026 compare with January-June of each
--     earlier year, procedure by procedure?
SELECT p.name_es,
       ROUND(SUM(ms.cases) FILTER (WHERE ms.report_year = 2025) * 100.0 /
             SUM(ms.procedures_done) FILTER (WHERE ms.report_year = 2025), 3) AS rate_h1_2025,
       ROUND(SUM(ms.cases) FILTER (WHERE ms.report_year = 2026) * 100.0 /
             SUM(ms.procedures_done) FILTER (WHERE ms.report_year = 2026), 3) AS rate_h1_2026
FROM monthly_surveillance ms
JOIN surgical_procedure p ON p.procedure_id = ms.procedure_id
WHERE ms.report_month <= 6 AND ms.report_year IN (2025, 2026)
GROUP BY p.name_es
ORDER BY p.name_es;

-- Q9. Is each procedure's monthly rate trending up or down?
--     regr_slope = change in rate (points per 100 procedures) per month; r2 shows fit.
SELECT p.name_es,
       ROUND(regr_slope(ms.rate_per_100, (ms.report_year - 2021) * 12 + ms.report_month)::NUMERIC, 4) AS slope_per_month,
       ROUND(regr_r2(ms.rate_per_100,    (ms.report_year - 2021) * 12 + ms.report_month)::NUMERIC, 3) AS r_squared
FROM monthly_surveillance ms
JOIN surgical_procedure p ON p.procedure_id = ms.procedure_id
GROUP BY p.name_es
ORDER BY slope_per_month DESC;

-- Q10. Is there a seasonal pattern? Average monthly rate by calendar month, all procedures pooled.
SELECT report_month,
       ROUND(SUM(cases) * 100.0 / SUM(procedures_done), 3) AS pooled_rate
FROM monthly_surveillance
GROUP BY report_month
ORDER BY report_month;

-- ---------------------------------------------------------------------
-- C. VARIABILITY AND OUTLIERS
-- ---------------------------------------------------------------------

-- Q11. Which procedure's monthly rate is the most volatile relative to its level?
--      (coefficient of variation = sample standard deviation / mean)
SELECT p.name_es,
       ROUND(AVG(ms.rate_per_100), 3)         AS mean_rate,
       ROUND(stddev_samp(ms.rate_per_100), 3) AS stddev_rate,
       ROUND(stddev_samp(ms.rate_per_100) / AVG(ms.rate_per_100), 2) AS coef_variation
FROM monthly_surveillance ms
JOIN surgical_procedure p ON p.procedure_id = ms.procedure_id
GROUP BY p.name_es
HAVING COUNT(*) >= 24
ORDER BY coef_variation DESC;

-- Q12. Which months were unusually bad -- above the 90th percentile of that
--      procedure's own monthly rates?
SELECT p.name_es, ms.report_year, ms.report_month,
       ms.cases, ms.procedures_done, ROUND(ms.rate_per_100, 3) AS rate
FROM monthly_surveillance ms
JOIN surgical_procedure p ON p.procedure_id = ms.procedure_id
JOIN (SELECT procedure_id,
             percentile_cont(0.9) WITHIN GROUP (ORDER BY rate_per_100) AS p90
      FROM monthly_surveillance
      GROUP BY procedure_id) t ON t.procedure_id = ms.procedure_id
WHERE ms.rate_per_100 > t.p90
ORDER BY p.name_es, ms.rate_per_100 DESC;

-- Q13. Does a busier month mean a higher rate? Correlation between procedure
--      volume and rate, per procedure.
SELECT p.name_es,
       ROUND(corr(ms.procedures_done, ms.rate_per_100)::NUMERIC, 3) AS corr_volume_rate
FROM monthly_surveillance ms
JOIN surgical_procedure p ON p.procedure_id = ms.procedure_id
GROUP BY p.name_es
ORDER BY corr_volume_rate;

-- Q14. How many months had zero infections, per procedure?
SELECT p.name_es,
       COUNT(*) FILTER (WHERE ms.cases = 0) AS zero_months,
       COUNT(*)                             AS months
FROM monthly_surveillance ms
JOIN surgical_procedure p ON p.procedure_id = ms.procedure_id
GROUP BY p.name_es
ORDER BY zero_months DESC;

-- ---------------------------------------------------------------------
-- D. WHO GETS INFECTED (sex and life stage)
-- ---------------------------------------------------------------------

-- Q15. Sex split of cases by procedure. Do the obstetric procedures show any male cases?
SELECT p.name_es, p.category,
       SUM(d.cases) FILTER (WHERE d.sex = 'F') AS women,
       SUM(d.cases) FILTER (WHERE d.sex = 'M') AS men,
       ROUND(100.0 * SUM(d.cases) FILTER (WHERE d.sex = 'F') / SUM(d.cases), 1) AS pct_women
FROM monthly_cases_demographic d
JOIN monthly_surveillance ms ON ms.surveillance_id = d.surveillance_id
JOIN surgical_procedure p    ON p.procedure_id = ms.procedure_id
GROUP BY p.name_es, p.category
ORDER BY p.category, p.name_es;

-- Q16. Age profile: what share of each procedure's cases falls in each life stage?
SELECT p.name_es, l.name_es AS life_stage,
       SUM(d.cases) AS cases,
       ROUND(100.0 * SUM(d.cases) / SUM(SUM(d.cases)) OVER (PARTITION BY p.name_es), 1) AS pct_of_procedure
FROM monthly_cases_demographic d
JOIN monthly_surveillance ms ON ms.surveillance_id = d.surveillance_id
JOIN surgical_procedure p    ON p.procedure_id = ms.procedure_id
JOIN life_stage l            ON l.life_stage_id = d.life_stage_id
GROUP BY p.name_es, l.name_es, l.life_stage_id
HAVING SUM(d.cases) > 0
ORDER BY p.name_es, l.life_stage_id;

-- Q17. Which life stages never appear for a given procedure?
--      (all procedure x life-stage combinations EXCEPT those with at least one case)
SELECT p.name_es, l.name_es AS life_stage
FROM surgical_procedure p CROSS JOIN life_stage l
EXCEPT
SELECT p.name_es, l.name_es
FROM monthly_cases_demographic d
JOIN monthly_surveillance ms ON ms.surveillance_id = d.surveillance_id
JOIN surgical_procedure p    ON p.procedure_id = ms.procedure_id
JOIN life_stage l            ON l.life_stage_id = d.life_stage_id
WHERE d.cases > 0
ORDER BY 1, 2;

-- Q18. Is endometritis more common after a cesarean or after a vaginal/other delivery?
--      Annual rates side by side. (Caution: the two procedures have different
--      denominators, so this compares surveillance rates, not matched risk.)
SELECT report_year,
       MAX(annual_rate) FILTER (WHERE procedure_name = 'Endometritis Post-Cesárea') AS post_cesarea,
       MAX(annual_rate) FILTER (WHERE procedure_name = 'Endometritis Post-Parto')   AS post_parto,
       MAX(annual_rate) FILTER (WHERE procedure_name = 'Endometritis Post-Cesárea')
     - MAX(annual_rate) FILTER (WHERE procedure_name = 'Endometritis Post-Parto')   AS difference
FROM v_annual_rate
WHERE report_year <= 2025
GROUP BY report_year
ORDER BY report_year;

-- Q19. How much of each procedure's infection rate comes from women and from men, by year?
--      The source has no procedure counts by sex, so a sex-specific rate cannot be computed.
--      This splits the OVERALL rate into each sex's contribution (the two add up to the total).
SELECT procedure_name, report_year,
       MAX(rate_contribution) FILTER (WHERE sex = 'F') AS women,
       MAX(rate_contribution) FILTER (WHERE sex = 'M') AS men,
       SUM(rate_contribution)                          AS total
FROM v_annual_rate_by_sex
GROUP BY procedure_name, report_year
ORDER BY procedure_name, report_year;
