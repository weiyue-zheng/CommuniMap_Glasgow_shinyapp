run_ask_map_query <- function(query,
                              prefix,
                              k = ASK_MAP_DEFAULT_K,
                              threshold = ASK_MAP_DEFAULT_THRESHOLD) {

  out_json <- tempfile(fileext = ".json")

  args <- c(
    ASK_MAP_SCRIPT,
    "--prefix", prefix,
    "--query", query,
    "--k", as.character(k),
    "--threshold", as.character(threshold),
    "--out", out_json
  )

  res <- system2(
    command = PYTHON_BIN,
    args = args,
    stdout = TRUE,
    stderr = TRUE
  )

  if (!file.exists(out_json)) {
    stop(
      paste(
        "Ask the Map query failed.",
        paste(res, collapse = "\n")
      )
    )
  }

  jsonlite::fromJSON(out_json, simplifyDataFrame = TRUE)
}