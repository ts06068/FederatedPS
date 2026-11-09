-- fps-step: Set up session-local tables for the two Circe cohorts
CREATE TABLE #fps_public_cohort (
    cohort_definition_id INT NOT NULL,
    subject_id BIGINT NOT NULL,
    cohort_start_date DATE NOT NULL,
    cohort_end_date DATE NOT NULL
);
CREATE TABLE #fps_public_concepts (
    cohort_definition_id INT NOT NULL,
    concept_id INT NOT NULL,
    PRIMARY KEY (cohort_definition_id, concept_id)
);
