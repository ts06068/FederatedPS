# Run from the repository root with the normal Windows study dependencies.
for (file in c("Progress.R","DbDiagnostics.R","CareSiteData.R","CareSiteSqlPlan.R",
               "PublicCdmStudies.R","StudySettings.R")) source(file.path("R", file))

testPublicCdm <- function(render, split, cohort) {
    root <- "inst/studies"
    registry <- jsonlite::read_json(file.path(root, "registry.json"))
    expected <- vapply(registry, function(x) x$study, "")
    stopifnot(length(expected) == 18L, !anyDuplicated(expected), nrow(listStudies()) == 13L)
    fail <- try(.fpsPublicStudySettings(expected[1], "default", root), silent = TRUE)
    stopifnot(inherits(fail, "try-error"), grepl("studySpecific", fail, fixed = TRUE))
    prepare <- function(settings, limit = 0L) .fpsPrepareCareSiteSqlPlan("CDM54.CDM", settings, 2L, limit,
        templateRoot = "inst/sql/sql_server", render = render, split = split, cohort = cohort, studyAssetRoot = root)
    for (study in expected) {
        settings <- .fpsPublicStudySettings(study, "studySpecific", root)
        stopifnot(settings$publicCdm, settings$endDays == -1L, settings$shortTermStartDays == -30L)
        plan <- prepare(settings, 200L)$batches
        stopifnot(identical(names(plan)[1:6], c("PublicCohortsInit.sql", "Public-target.sql",
            "Public-comparator.sql", "PublicSitePartition.sql", "SiteVisits.sql", "LimitPatients.sql")),
            grepl("#fps_public_concepts", plan$Covariates.sql$sql, fixed = TRUE),
            !grepl("#fps_ingredients", plan$Covariates.sql$sql, fixed = TRUE))
        for (arm in c("Public-target.sql","Public-comparator.sql")) {
            sql <- plan[[arm]]$sql
            stopifnot(length(plan[[arm]]$statements) > 15L,
                grepl("CDM54.CDM.CONCEPT", sql, fixed = TRUE),
                grepl("INSERT INTO #fps_public_cohort", sql, fixed = TRUE),
                !grepl("@|[{}]|cohort_inclusion_|cohort_summary_stats", sql))
            # All writes in the generated cohort template are local to the session.
            writePattern <- "(?i)\\b(?:INSERT\\s+INTO|SELECT\\s+INTO|DELETE\\s+FROM|TRUNCATE\\s+TABLE|DROP\\s+TABLE|CREATE\\s+TABLE|UPDATE\\s+STATISTICS)\\s+[^#[:space:]]"
            stopifnot(!grepl(writePattern, sql, perl = TRUE))
        }
    }
    for (study in listStudies()$study) for (scenario in c("default","studySpecific")) {
        legacy <- prepare(getStudySettings(study, scenario))$batches
        stopifnot(identical(names(legacy)[1:4],c("StudyConcepts.sql","SitePartition.sql","SiteVisits.sql","StudyDrugs.sql")),
            grepl("#fps_ingredients", legacy$Covariates.sql$sql, fixed = TRUE),
            !grepl("#fps_public_concepts", legacy$Covariates.sql$sql, fixed = TRUE))
    }
    cat("PASS: 18 public studySpecific plans, both arm templates, local writes, 26 unchanged preset routes\n")
}
if (sys.nframe() == 0L) {
    testPublicCdm(SqlRender::render, SqlRender::splitSql, SqlRender::loadRenderTranslateSql)
}
