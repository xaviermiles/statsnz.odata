#' Basic GET request to Stats NZ OData API, with paging when required.
#'
#' @description Derived from https://github.com/StatisticsNZ/open-data-api/
#'
#' @param endpoint API endpoint. Required.
#' @param entity Data entity.
#' @param query Query URL character (not URL-encoded).
#' @param timeout Timeout for the GET request(s), in seconds.
#'
#' @return A data frame containing the requested data.
#'
#' @export
basic_get <- function(endpoint, entity = "", query = "", timeout = 10) {
  # TODO: could query be more R style? list of query types rather than just string?
  detailed_get(endpoint, entity, query, timeout)$value
}


#' "Detailed" version of basic_get in that it returns a list with both the
#' requested data and the initial request url.
#' @include utils_odata_get.R
#' @noRd
detailed_get <- function(endpoint, entity = "", query = "", timeout = 10) {
  initial_url <- build_basic_url(endpoint, entity, query)
  top_query <- grepl("$top", query, fixed = TRUE)

  result <- data.frame()
  url <- initial_url
  while (!is.null(url)) {
    content <- send_get(url, timeout)
    result <- rbind(result, content$value)
    if (top_query)
      break
    url <- content$"@odata.nextLink"
  }

  return(list(value = result, initial_url = initial_url))
}


#' Parallelised version of basic_get, for requesting larger amounts of data.
#'
#' @description This uses multiples cores to make concurrent API requests, and
#' then merges the individual results. There is some upfront work required to
#' determine the series of smaller requests, so this function shouldn't be used
#' for "small" requests.
#'
#' FIXME: support `query` that include $filter, this would require merging it
#'        with the $filter generated with the `splitting_col`.
#'
#' @inheritParams basic_get
#' @param splitting_col The column on which to split the overall request into
#'   bite-size portions.
#' @param max_cores Maximum number of cores. This will be overruled if there is
#'   less cores available.
#' @param rows_per_query The approx. number of rows per individual request.
#'   This can be used to tune performance.
#'
#' @return A data frame containing the requested data.
#'
#' @export
parallel_get <- function(endpoint, entity = "", query = "", timeout = 10,
                         splitting_col = "ResourceID",
                         max_cores = 4,
                         rows_per_query = 10000) {
  detailed_parallel_get()$value
}


#' Parallelised version of detailed_get
#' @inherit parallel_get
#' @noRd
detailed_parallel_get <- function(endpoint, entity = "", query = "", timeout = 10,
                                  splitting_col = "ResourceID",
                                  max_cores = 4,
                                  rows_per_query = 10000) {
  n_cores <- future::availableCores()
  future::plan("multisession", workers = min(n_cores, max_cores))
  queries <- get_bucketed_queries(splitting_col, rows_per_query,
                                  endpoint, entity, timeout)
  if (query != "") {
    if (stringr::str_detect(query, "\\$filter=.*&+")) {
      stop("This function is not smart enough for a `query` with a $filter.")
    } else {
      queries <- glue("{queries}&{query}")
    }
  }
  merged <- furrr::future_map_dfr(
    queries,
    ~ basic_get(endpoint, entity = entity, query = .x, timeout = timeout)
  )
  initial_url <- build_basic_url(endpoint, entity, query)
  return(list(value = merged, initial_url = initial_url))
}


#' Splits GET request into collection of smaller queries, along a given
#' column. It splits the distinct values of this column into buckets such that
#' each bucket has relatively similar total row count.
#'
#' @param splitting_col Column to split into buckets.
#' @param rows_per_query Approx. number of rows per query.
#' + typical params
#' @noRd
get_bucketed_queries <- function(splitting_col, rows_per_query, endpoint, entity, timeout) {
  counter <- glue(
    "&$apply=groupby(({splitting_col}),aggregate($count as count))"
  )
  rows <- basic_get(endpoint, entity, query = counter, timeout = timeout) %>%
    dplyr::arrange(count) %>%
    dplyr::mutate(cumul_weight = cumsum(count))

  # cut() requires breaks >=2, hence the max()
  n_buckets <- max(ceiling(sum(rows$count) / rows_per_query), 2)
  rows$bucket_num <- as.numeric(cut(rows$cumul_weight, n_buckets))
  bucket_num_to_vals <- split(rows$ResourceID, rows$bucket)

  purrr::map_chr(
    unname(bucket_num_to_vals),
    function(vals) {
      quoted_vals <- glue_collapse(sQuote(vals, q = FALSE), sep  = ",")
      glue("{splitting_col} in ({quoted_vals})")
    }
  )
}


#' Constructs request URLs.
#'
#' @param endpoint API endpoint. Required.
#' @param entity Data entity.
#' @param query Query URL character (not URL-encoded).
#'
#' @noRd
build_basic_url <- function(endpoint, entity = "", query = "") {
  # TODO: check for NULL service. Here or somewhere else?
  service <- get_golem_config("service_prd")
  url <- glue("{service}/{endpoint}")
  if (entity != "")
    url <- glue("{url}/{entity}")
  if (query != "")
    url <- glue("{url}?{query}")

  return(utils::URLencode(url))
}


#' GET the catalogue of Stats NZ OData API.
#'
#' @description Derived from https://github.com/StatisticsNZ/open-data-api/
#'
#' The returned data is generally not a "tidy dataset" so the R data frame
#' will use prefixes to represent the nested content.
#'
#' @param timeout Timeout for the GET request, in seconds.
#'
#' @return A data frame containing the requested catalogue data.
#'
#' @export
get_catalogue <- function(timeout = 10) {
  # TODO: would this ever need to page??
  url <- build_basic_url("data.json")
  content <- send_get(url, timeout)

  if (!"dataset" %in% names(content))
    stop("Response doesn't contain 'dataset'.")

  catalogue <- tidyr::unnest_longer(content$dataset, distribution)
  return(catalogue)
}
