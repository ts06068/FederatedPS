# The Windows catalog is a pinned subset of the dev assets: every public
# comparison, with its studySpecific definitions only.
.fpsStudyAssetRoot <- function() {
    system.file("studies", package = "FederatedPs", mustWork = TRUE)
}

.fpsPublicStudySettings <- function(study, scenario, root = .fpsStudyAssetRoot()) {
    entries <- jsonlite::read_json(file.path(root, "registry.json"))
    found <- Filter(function(entry) identical(entry$study, study), entries)
    if (length(found) != 1L) stop("Unknown public CDM study: ", study)
    if (scenario != "studySpecific") stop("Public CDM studies require scenario = 'studySpecific'")
    settings <- found[[1L]]
    arms <- c("target", "comparator")
    jsonPaths <- file.path(root, "cohorts", study, paste0("studySpecific_", arms, ".json"))
    sqlPaths <- file.path(root, "sql_server", study, paste0(arms, ".sql"))
    hashes <- unname(tools::md5sum(c(jsonPaths, sqlPaths)))
    if (anyNA(hashes)) stop("Missing bundled cohort definitions for ", study)
    definitions <- lapply(jsonPaths, jsonlite::read_json)
    seeds <- unique(unlist(lapply(definitions, function(definition) {
        lapply(definition$ConceptSets, function(set)
            vapply(set$expression$items, function(item) item$concept$CONCEPT_ID, numeric(1)))
    }), use.names = FALSE))
    if (!length(seeds) || any(!is.finite(seeds) | seeds <= 0 | seeds != floor(seeds))) {
        stop("Invalid vocabulary seeds in ", study)
    }
    settings$scenario <- scenario
    settings$publicCdm <- TRUE
    settings$seedConceptIds <- sort(seeds)
    settings$definitionFilesMd5 <- hashes
    settings
}
