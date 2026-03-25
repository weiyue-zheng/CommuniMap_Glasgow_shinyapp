parse_created_at_flex <- function(x, tz = "Europe/London") {
  if (inherits(x, "POSIXct") || inherits(x, "POSIXt")) {
    return(with_tz(x, tzone = tz))
  }
  
  if (inherits(x, "Date")) {
    return(as.POSIXct(x, tz = tz))
  }
  
  if (is.numeric(x)) {
    return(suppressWarnings(as_datetime(x, origin = "1899-12-30", tz = tz)))
  }
  
  x_chr <- trimws(as.character(x))
  x_chr[x_chr %in% c("", "NA", "NaN", "NULL")] <- NA_character_
  
  suppressWarnings(parse_date_time(
    x_chr,
    orders = c(
      "Y-m-d H:M:S", "Y-m-d H:M", "Y-m-d",
      "Y/m/d H:M:S", "Y/m/d H:M", "Y/m/d",
      "d/m/Y H:M:S", "d/m/Y H:M", "d/m/Y",
      "d-m-Y H:M:S", "d-m-Y H:M", "d-m-Y",
      "m/d/Y H:M:S", "m/d/Y H:M", "m/d/Y"
    ),
    tz = tz,
    exact = FALSE
  ))
}

read_spots_file <- function(path) {
  ext <- tolower(tools::file_ext(path))
  
  if (ext == "csv") {
    df0 <- read_delim(
      path,
      delim = DATA_DELIM,
      quote = "\"",
      escape_double = TRUE,
      col_names = TRUE,
      show_col_types = FALSE,
      locale = locale(encoding = "UTF-8")
    )
  } else if (ext %in% c("xlsx", "xls")) {
    sheets <- excel_sheets(path)
    # Prefer the exported CommuniMap data sheet when helper sheets are present.
    target_sheet <- sheets[grepl("^communimap_spots_", sheets)]
    target_sheet <- if (length(target_sheet) > 0) target_sheet[[1]] else sheets[[1]]
    
    df0 <- read_excel(path, sheet = target_sheet)
  } else {
    stop("Unsupported file type. Please upload a .csv, .xlsx, or .xls file.")
  }
  
  req_cols <- c(COL_COLAB, COL_LAT, COL_LON, COL_CREATED_AT)
  missing_cols <- setdiff(req_cols, names(df0))
  if (length(missing_cols) > 0) {
    stop(paste("Missing required columns:", paste(missing_cols, collapse = ", ")))
  }
  
  df0 %>%
    mutate(
      !!COL_COLAB := trimws(as.character(.data[[COL_COLAB]])),
      !!COL_LAT := suppressWarnings(as.numeric(.data[[COL_LAT]])),
      !!COL_LON := suppressWarnings(as.numeric(.data[[COL_LON]])),
      CREATED_AT_PARSED = parse_created_at_flex(.data[[COL_CREATED_AT]]),
      CREATED_DATE = as.Date(CREATED_AT_PARSED)
    )
}

spatial_join_to_iz <- function(df0_in, iz_obj) {
  target_crs <- 27700
  # Do the point-in-polygon join in a projected CRS for more reliable geometry handling.
  iz_proj <- st_transform(iz_obj, target_crs)
  
  pts <- df0_in %>%
    filter(is.finite(.data[[COL_LAT]]), is.finite(.data[[COL_LON]])) %>%
    st_as_sf(coords = c(COL_LON, COL_LAT), crs = 4326, remove = FALSE) %>%
    st_transform(target_crs)
  
  pts_join <- st_join(
    pts,
    iz_proj %>% select(all_of(c(IZ_KEY, IZ_NAME, IZ_POP_RES, IZ_POP_TOT))),
    join = st_within,
    left = TRUE
  )
  
  pts_join %>%
    st_drop_geometry() %>%
    rename(
      IZ_CODE = all_of(IZ_KEY),
      IZ_LABEL = all_of(IZ_NAME)
    ) %>%
    mutate(!!COL_COLAB := trimws(as.character(.data[[COL_COLAB]]))) %>%
    filter(!is.na(IZ_CODE))
}

build_simd_map_data <- function(dz_sf, simd_var) {
  g <- dz_sf %>%
    mutate(metric = suppressWarnings(as.numeric(.data[[simd_var]])))
  
  # Keep the palette and labels together so the SIMD map can switch metrics cleanly.
  pal <- colorNumeric("viridis", domain = g$metric, na.color = NA_MAP_COLOR, reverse = TRUE)
  
  label <- sprintf(
    "<b>Data Zone:</b> %s<br><b>Name:</b> %s<br><b>%s:</b> %s",
    g[[DZ_KEY]],
    g[[DZ_NAME]],
    simd_var,
    ifelse(is.na(g$metric), "NA", format(g$metric, big.mark = ","))
  ) %>% lapply(HTML)
  
  list(data = g, pal = pal, label = label)
}

vars_for_colab <- function(df_all, colab_name) {
  df_all <- df_all %>%
    mutate(!!COL_COLAB := trimws(as.character(.data[[COL_COLAB]])))
  
  colab_name <- trimws(as.character(colab_name))
  df_c <- df_all %>% filter(.data[[COL_COLAB]] == colab_name)
  colab_cols <- colab_var_map[[colab_name]]
  if (is.null(colab_cols)) colab_cols <- character(0)
  
  candidates <- unique(c(COMMON_VARS, colab_cols))
  candidates <- candidates[candidates %in% names(df_all)]
  candidates <- candidates[!str_detect(candidates, EXCLUDE_PAT)]
  candidates <- candidates[!candidates %in% c(
    "ID", "ROOT_ID", "STATE", "FLAG_COUNT", "VALIDATION_SCORE",
    COL_LAT, COL_LON, COL_CREATED_AT, "CREATED_AT_PARSED", "CREATED_DATE",
    "IZ_CODE", "IZ_LABEL", IZ_POP_RES, IZ_POP_TOT
  )]
  
  candidates[vapply(candidates, function(v) {
    x <- df_c[[v]]
    # Only keep variables with enough variation to make the plot worth showing.
    n_distinct(na.omit(x)) >= 2
  }, logical(1))]
}

# Use one filter path for both views so they stay in sync.
apply_common_filters <- function(
  d,
  date_rng,
  user_role = "All",
  travel_mode = "All",
  search = "",
  selected_iz = NA_character_
) {
  d <- d %>%
    filter(!is.na(CREATED_DATE)) %>%
    filter(CREATED_DATE >= date_rng[1], CREATED_DATE <= date_rng[2])
  
  if ("USER_ROLE" %in% names(d) && !is.null(user_role) && user_role != "All") {
    d <- d %>% filter(USER_ROLE == user_role)
  }
  
  if ("TRAVEL_MODE" %in% names(d) && !is.null(travel_mode) && travel_mode != "All") {
    d <- d %>% filter(TRAVEL_MODE == travel_mode)
  }
  
  if (nzchar(trimws(search))) {
    # Search across the main free-text fields without removing them from the data.
    txt_fields <- intersect(TEXT_ANALYSIS_FIELDS, names(d))
    if (length(txt_fields) > 0) {
      needle <- tolower(search)
      d <- d %>%
        unite(col = "sb", all_of(txt_fields), sep = " ", remove = FALSE, na.rm = TRUE) %>%
        filter(str_detect(tolower(sb), fixed(needle))) %>%
        select(-sb)
    }
  }
  
  if (!is.na(selected_iz)) {
    d <- d %>% filter(IZ_CODE == selected_iz)
  }
  
  d
}
