if (!requireNamespace("rsconnect", quietly = TRUE)) {
  install.packages("rsconnect")
}

required_vars <- c("RSCONNECT_ACCOUNT", "RSCONNECT_TOKEN", "RSCONNECT_SECRET")
missing_vars <- required_vars[Sys.getenv(required_vars) == ""]

if (length(missing_vars) > 0) {
  stop(
    paste(
      "Missing deployment environment variables:",
      paste(missing_vars, collapse = ", ")
    )
  )
}

rsconnect::setAccountInfo(
  name = Sys.getenv("RSCONNECT_ACCOUNT"),
  token = Sys.getenv("RSCONNECT_TOKEN"),
  secret = Sys.getenv("RSCONNECT_SECRET")
)

rsconnect::deployApp()
