# Regenerate the SQL Server cohort templates from the pinned dev Circe JSON.
# Requires CirceR 1.3.3 and SqlRender 1.19.7 at build time only.
buildWindowsStudySql <- function(root = "inst/studies",
        expression = CirceR::cohortExpressionFromJson,
        options = CirceR::createGenerateOptions,
        build = CirceR::buildCohortQuery, render = SqlRender::render) {
    registry <- jsonlite::read_json(file.path(root, "registry.json"))
    for (entry in registry) {
        for (arm in c("target", "comparator")) {
            id <- if (arm == "target") 1L else 2L
            jsonPath <- file.path(root, "cohorts", entry$study, paste0("studySpecific_", arm, ".json"))
            json <- paste(readLines(jsonPath, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
            definition <- jsonlite::fromJSON(json, simplifyVector = FALSE)
            criteria <- definition$PrimaryCriteria$CriteriaList
            stopifnot(length(criteria) == 1L, names(criteria[[1]]) %in% c("DrugExposure", "DrugEra"))
            entryCodeSet <- criteria[[1]][[1]]$CodesetId
            stopifnot(length(entryCodeSet) == 1L, is.numeric(entryCodeSet))
            sql <- build(expression(json), options(cohortId = id, generateStats = FALSE,
                cdmSchema = "@cdm_database_schema", vocabularySchema = "@cdm_database_schema",
                targetTable = "#fps_public_cohort", resultSchema = "@target_database_schema"))
            # CirceR 1.3.3 leaves the impact-analysis blocks behind as SqlRender
            # conditions. Resolve them with stats disabled, preserving the CDM token.
            sql <- render(sql, cdm_database_schema = "@cdm_database_schema",
                warnOnMissingParameters = FALSE)
            sql <- gsub("\r\n?", "\n", sql)
            sql <- gsub("[ \t]+(?=\n|$)", "", sql, perl = TRUE)
            # YUHS expects the canonical uppercase OMOP table names.
            pieces <- gregexpr("@cdm_database_schema[.][A-Za-z_]+", sql, perl = TRUE)
            regmatches(sql, pieces) <- lapply(regmatches(sql, pieces), function(xs)
                paste0("@cdm_database_schema.", toupper(sub("^@cdm_database_schema[.]", "", xs))))
            anchor <- "UPDATE STATISTICS #Codesets;"
            stopifnot(length(strsplit(sql, anchor, fixed = TRUE)[[1]]) == 2L,
                grepl("INSERT INTO #fps_public_cohort", sql, fixed = TRUE),
                !grepl("@target_|cohort_inclusion_|cohort_summary_stats|[{}]", sql))
            # Keep Circe's resolved index codes for the institution attribution
            # and feature-exclusion steps after its private #Codesets is dropped.
            copies <- sprintf(paste0("INSERT INTO #fps_public_concepts (cohort_definition_id, concept_id)\n",
                "SELECT DISTINCT %d, concept_id FROM #Codesets WHERE codeset_id = %d;"),
                id, entryCodeSet)
            sql <- sub(anchor, paste(anchor, copies, sep = "\n"), sql, fixed = TRUE)
            out <- file.path(root, "sql_server", entry$study, paste0(arm, ".sql"))
            dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
            provenance <- paste("-- CirceR 1.3.3 from pinned FederatedPS dev studySpecific JSON.",
                "-- Cohort output and resolved index concepts are session-local.", sep = "\n")
            writeLines(enc2utf8(paste(provenance, trimws(sql), sep = "\n")), out, useBytes = TRUE)
        }
    }
}
if (sys.nframe() == 0L) {
    stopifnot(as.character(packageVersion("CirceR")) == "1.3.3",
              as.character(packageVersion("SqlRender")) == "1.19.7")
    buildWindowsStudySql()
}
