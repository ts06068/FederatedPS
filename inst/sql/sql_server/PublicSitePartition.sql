-- Resolve the pair before imposing the YUHS site restriction. The same-day
-- cross-arm tie policy and earliest eligible index follow the dev registry.
-- fps-step: Index the generated cohort and retain the first untied entry
CREATE INDEX ix_public_cohort_subject ON #fps_public_cohort(subject_id, cohort_start_date, cohort_definition_id);
WITH untied AS (
    SELECT DISTINCT c.subject_id, c.cohort_definition_id, c.cohort_start_date, c.cohort_end_date
    FROM #fps_public_cohort c
    WHERE NOT EXISTS (
        SELECT 1 FROM #fps_public_cohort d
        WHERE d.subject_id = c.subject_id AND d.cohort_start_date = c.cohort_start_date
          AND d.cohort_definition_id <> c.cohort_definition_id
    )
), ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY subject_id
        ORDER BY cohort_start_date, cohort_definition_id, cohort_end_date) AS rn
    FROM untied
)
SELECT subject_id, cohort_definition_id, cohort_start_date, cohort_end_date
INTO #fps_public_first FROM ranked WHERE rn = 1;
CREATE UNIQUE CLUSTERED INDEX ix_public_first ON #fps_public_first(subject_id);

-- For both DrugExposure and DrugEra definitions, attribute only an index
-- with a same-person, same-date, arm-specific exposure linked to this site.
-- fps-step: Link the selected index exposure to the institution
SELECT c.subject_id AS person_id INTO #fps_candidate
FROM #fps_public_first c
WHERE EXISTS (
    SELECT 1 FROM @cdm_database_schema.DRUG_EXPOSURE d
    JOIN #fps_public_concepts a ON a.concept_id = d.drug_concept_id
      AND a.cohort_definition_id = c.cohort_definition_id
    JOIN @cdm_database_schema.VISIT_OCCURRENCE v
      ON v.visit_occurrence_id = d.visit_occurrence_id AND v.person_id = d.person_id
    WHERE d.person_id = c.subject_id AND d.drug_exposure_start_date = c.cohort_start_date
      AND v.care_site_id = @care_site_id
);
CREATE UNIQUE CLUSTERED INDEX ix_candidate ON #fps_candidate(person_id);

-- fps-step: Exclude people with visits to any other positive care_site_id
SELECT c.person_id INTO #fps_person FROM #fps_candidate c
WHERE NOT EXISTS (
    SELECT 1 FROM @cdm_database_schema.VISIT_OCCURRENCE v
    WHERE v.person_id = c.person_id AND v.care_site_id > 0 AND v.care_site_id <> @care_site_id
);
CREATE UNIQUE CLUSTERED INDEX ix_person ON #fps_person(person_id);

-- fps-step: Carry the accepted Circe index and end date into CohortMethod
SELECT c.subject_id, c.cohort_definition_id, c.cohort_start_date, c.cohort_end_date,
       c.cohort_start_date AS covariate_cutoff
INTO #fps_exposure FROM #fps_public_first c
JOIN #fps_person p ON p.person_id = c.subject_id;
CREATE UNIQUE CLUSTERED INDEX ix_exposure_subject ON #fps_exposure(subject_id);
