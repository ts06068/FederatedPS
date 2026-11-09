# Run with the same offline R installation that ran FederatedPS.
# Usage: Rscript --vanilla Export-StudySmd.R <run-directory> [install-root]
# RStudio: source("Export-StudySmd.R"); export_study_smd("<run-directory>")
# The two output CSVs contain covariate summaries, not patient records.

smd_align_scores <- function(population, scores, site) {
    scores <- scores[as.character(scores$site) == site, , drop = FALSE]
    target_ids <- as.character(population$rowId)
    score_ids <- as.character(scores$rowId)
    index <- match(target_ids, score_ids)
    if (nrow(scores) != nrow(population) || anyNA(index) ||
        anyDuplicated(score_ids) || anyDuplicated(target_ids) ||
        !identical(as.character(scores$personId[index]), as.character(population$personId)) ||
        !identical(as.integer(scores$treatment[index]), as.integer(population$treatment))) {
        stop("Score rows differ from the saved design for site ", site, call. = FALSE)
    }
    ps <- scores$propensityScore[index]
    if (!is.numeric(ps) || any(!is.finite(ps) | ps <= 0 | ps >= 1)) {
        stop("Invalid saved propensity scores for site ", site, call. = FALSE)
    }
    ps
}

smd_match_rows <- function(treatment, ps) {
    matching <- CohortMethod::matchOnPs(
        data.frame(rowId = seq_along(treatment), treatment = treatment,
                   propensityScore = ps),
        matchOnPsArgs = CohortMethod::createMatchOnPsArgs(
            caliper = 0.2, caliperScale = "standardized logit", maxRatio = 1))
    rows <- matching$rowId
    treated <- rows[matching$treatment == 1L]
    control <- rows[matching$treatment == 0L]
    if (anyNA(rows) || anyDuplicated(rows) ||
        any(rows < 1L | rows > length(treatment)) ||
        length(treated) != length(control) ||
        any(treatment[treated] != 1L) || any(treatment[control] != 0L)) {
        stop("Invalid 1:1 matching result", call. = FALSE)
    }
    list(treated = treated, comparator = control)
}

smd_site <- function(x, treatment, matched, block_size = 128L) {
    treated <- which(treatment == 1L)
    comparator <- which(treatment == 0L)
    if (min(length(treated), length(comparator)) < 2L) {
        stop("Each original arm needs at least two patients", call. = FALSE)
    }
    sample_var <- function(m, mean) {
        centered <- Matrix::colSums(m^2) - nrow(m) * mean^2
        pmax(0, centered) / (nrow(m) - 1L)
    }
    before <- rep(NA_real_, ncol(x))
    after <- setNames(lapply(matched, function(m) before), names(matched))
    for (first in seq.int(1L, ncol(x), by = block_size)) {
        cols <- seq.int(first, min(first + block_size - 1L, ncol(x)))
        tx <- x[treated, cols, drop = FALSE]
        cx <- x[comparator, cols, drop = FALSE]
        tm <- Matrix::colMeans(tx)
        cm <- Matrix::colMeans(cx)
        sd_ref <- sqrt((sample_var(tx, tm) + sample_var(cx, cm)) / 2)
        sd_ref[sd_ref == 0] <- NA_real_
        before[cols] <- (tm - cm) / sd_ref
        for (model in names(matched)) {
            m <- matched[[model]]
            if (length(m$treated)) {
                after[[model]][cols] <- (
                    Matrix::colMeans(x[m$treated, cols, drop = FALSE]) -
                    Matrix::colMeans(x[m$comparator, cols, drop = FALSE])
                ) / sd_ref
            }
        }
    }
    list(before = before, after = after)
}

export_study_smd <- function(run_dir, install_root = "C:/FederatedPS") {
    .libPaths(c(file.path(install_root, "RLibrary", "windows-block"),
                file.path(install_root, "RLibrary", "4.6"), .libPaths()))
    for (pkg in c("Matrix", "jsonlite", "CohortMethod")) {
        if (!requireNamespace(pkg, quietly = TRUE)) {
            stop("Cannot load offline R package: ", pkg, call. = FALSE)
        }
    }
    run_dir <- normalizePath(run_dir, winslash = "/", mustWork = TRUE)
    if (!file.exists(file.path(run_dir, "SUCCESS.txt"))) {
        stop("Use the original completed RUN.ps1 results directory.", call. = FALSE)
    }
    config <- jsonlite::fromJSON(file.path(run_dir, "run.json"), simplifyVector = FALSE)
    cache <- jsonlite::fromJSON(file.path(run_dir, "data-cache.json"), simplifyVector = FALSE)
    sites <- as.character(unlist(config$sites))
    models <- c("local-only", "pooled")
    if (!all(models %in% unlist(config$methods)) ||
        !length(sites) || anyDuplicated(sites) || !all(sites %in% names(cache))) {
        stop("Expected a completed run with local-only and pooled results.", call. = FALSE)
    }
    pooled <- readRDS(file.path(run_dir, "pooled", "result.rds"))
    details <- summaries <- list()
    mean_abs <- function(v) if (any(is.finite(v))) mean(abs(v[is.finite(v)])) else NA_real_
    for (site in sites) {
        message("Calculating SMD for site_id=", site)
        design_path <- file.path(cache[[site]]$path, "design.rds")
        receipt_path <- file.path(cache[[site]]$path, "complete.rds")
        if (!file.exists(design_path) || !file.exists(receipt_path)) {
            stop("Extraction cache is missing for site ", site, ": ", design_path, call. = FALSE)
        }
        receipt <- readRDS(receipt_path)
        if (!identical(as.character(receipt$site), site) ||
            !identical(receipt$md5, unname(tools::md5sum(design_path)))) {
            stop("Extraction cache verification failed for site ", site, call. = FALSE)
        }
        design <- readRDS(design_path)
        x <- design$x
        population <- design$population
        treatment <- population$treatment
        if (!identical(as.character(design$site), site) ||
            !inherits(x, "sparseMatrix") || !ncol(x) || is.null(colnames(x)) ||
            anyDuplicated(colnames(x)) || nrow(x) != nrow(population) ||
            nrow(population) != cache[[site]]$patients || anyNA(treatment) ||
            !setequal(treatment, c(0, 1)) ||
            !identical(rownames(x), paste(site, population$rowId, sep = ":"))) {
            stop("Design differs from the run cache record for site ", site, call. = FALSE)
        }
        local_scores <- readRDS(file.path(run_dir, "local", site, "result.rds"))
        matched <- list(
            "local-only" = smd_match_rows(treatment, smd_align_scores(population, local_scores, site)),
            "pooled" = smd_match_rows(treatment, smd_align_scores(population, pooled, site))
        )
        smd <- smd_site(x, treatment, matched)
        reference <- design$reference
        reference <- reference[match(colnames(x), as.character(reference$covariateId)), , drop = FALSE]
        label <- config$siteLabels[[site]]
        if (is.null(label)) label <- site
        for (model in models) {
            post <- smd$after[[model]]
            pairs <- length(matched[[model]]$treated)
            key <- paste(site, model)
            details[[key]] <- data.frame(
                study = config$study, scenario = config$scenario, site_id = site, site = label, model = model,
                covariate_id = colnames(x), analysis = reference$analysisName,
                domain = reference$domainId, concept_id = reference$conceptId,
                matched_pairs = pairs, smd_before = smd$before,
                smd_after = post, abs_smd_after = abs(post))
            summaries[[key]] <- data.frame(
                study = config$study, scenario = config$scenario, site_id = site, site = label, model = model,
                treated_before = sum(treatment == 1L), comparator_before = sum(treatment == 0L),
                matched_pairs = pairs, covariates = ncol(x),
                n_smd_before = sum(is.finite(smd$before)), n_smd_after = sum(is.finite(post)),
                mean_abs_smd_before = mean_abs(smd$before), mean_abs_smd_after = mean_abs(post),
                n_abs_smd_before_gt_0_1 = if (any(is.finite(smd$before))) sum(abs(smd$before) > 0.1, na.rm = TRUE) else NA_integer_,
                n_abs_smd_after_gt_0_1 = if (any(is.finite(post))) sum(abs(post) > 0.1, na.rm = TRUE) else NA_integer_)
        }
        rm(design, x, population, local_scores)
        invisible(gc())
    }
    detail <- do.call(rbind, details)
    detail <- detail[order(detail$site_id, detail$model, -detail$abs_smd_after), ]
    summary <- do.call(rbind, summaries)
    utils::write.csv(detail, file.path(run_dir, "smd_covariates.csv"), row.names = FALSE)
    utils::write.csv(summary, file.path(run_dir, "smd_summary.csv"), row.names = FALSE)
    print(summary, row.names = FALSE)
    invisible(summary)
}

if (sys.nframe() == 0L) {
    args <- commandArgs(trailingOnly = TRUE)
    if (!length(args) || length(args) > 2L) {
        stop("Usage: Rscript --vanilla Export-StudySmd.R <run-directory> [install-root]", call. = FALSE)
    }
    if (length(args) == 1L) export_study_smd(args[1L])
    else export_study_smd(args[1L], args[2L])
}
