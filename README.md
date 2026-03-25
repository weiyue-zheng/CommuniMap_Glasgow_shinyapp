# CommuniMap Glasgow Shiny App

This folder contains a Shiny dashboard for exploring CommuniMap reports across Glasgow.

The app links report locations to Intermediate Zones, adds SIMD context from Data Zones, and provides a set of CoLab dashboards for filtering, mapping, and summarising the data.

The app can start without a bundled CommuniMap report file. In that case, users can upload their own export from the Data Summary tab.

## What the app does

- loads a CommuniMap export from `.xlsx`, `.xls`, or `.csv`
- parses report dates and coordinates
- joins report points to Glasgow Intermediate Zones
- summarises report counts, rates, and sentence-level sentiment
- adds SIMD deprivation context using Data Zone data and a lookup to Intermediate Zones
- shows separate tabs for the CoLabs present in the current dataset

## Files needed to start the app

To launch the app, these files need to be present:

- `data/simd2020_withinds.csv`
- `data/datazone_to_intermediatezone_lookup_2011.xlsx`
- `shapes/glasgow_intermediate_zones/Glasgow_City_Only.shp` and its matching sidecar files
- `shapes/data_zones/sc_dz_11.shp` and its matching sidecar files

If any of these files are missing, the app will stop at startup.

## Optional report data files

The app can also use either of these report files if you want a bundled default dataset:

- `data/communimap_spots_20251107170112.csv`
- `data/spots 16_01_2026.xlsx` (optional local file)

If no bundled report file is present, the app still starts and waits for the user to upload a valid CommuniMap export.

## Folder layout

```text
communimap_app/
  app.R
  README.md
  .gitignore
  data/
    communimap_spots_20251107170112.csv
    simd2020_withinds.csv
    simd2020_withinds.xlsx
    datazone_to_intermediatezone_lookup_2011.xlsx
    spots 16_01_2026.xlsx  # optional local file, not tracked
  shapes/
    glasgow_intermediate_zones/
      Glasgow_City_Only.shp/.shx/.dbf/.prj
    data_zones/
      sc_dz_11.shp/.shx/.dbf/.prj/.qpj
  R/
    app_config.R
    data_helpers.R
    sentiment_helpers.R
  reports/
    colab_report.Rmd
```

## Expected report data fields

At minimum, the uploaded or default CommuniMap export must contain these columns:

- `CATEGORY`
- `LATITUDE`
- `LONGITUDE`
- `CREATED_AT`

The app also expects many other fields used in the CoLab dashboards, including text fields such as:

- `DESCRIPTION`
- `ISSUE_DESCRIPTION`
- `SUCCESS_DETAILS`

If an uploaded file is missing important fields, the upload may fail or some parts of the dashboard may be empty.

## CoLab variable selection

The app does not guess CoLab fields from column prefixes anymore. Instead, `app.R` uses an explicit `colab_var_map`, which makes it easier to control which variables appear in each CoLab dashboard.

Shared fields such as user role, travel mode, and description are kept separately in `COMMON_VARS`.

## Sentiment analysis

Sentiment is calculated from the report text using sentence-level scoring:

- text is combined from the main free-text fields
- repeated boilerplate phrases are stripped out
- text is split into sentences
- words are matched against the Bing sentiment lexicon from `tidytext`
- sentence scores are averaged to the report level
- report scores are then averaged by Intermediate Zone for mapping

This is meant as a simple descriptive indicator rather than a full linguistic analysis.

## Packages used

The app uses these main R packages:

- `shiny`
- `bslib`
- `readr`
- `readxl`
- `lubridate`
- `stringr`
- `sf`
- `leaflet`
- `DT`
- `tidyr`
- `rmarkdown`
- `ggplot2`
- `dplyr`
- `htmltools`
- `tidytext`

If needed, you can install them with:

```r
install.packages(c(
  "shiny", "bslib", "readr", "readxl", "lubridate", "stringr",
  "sf", "leaflet", "DT", "tidyr", "rmarkdown", "ggplot2",
  "dplyr", "htmltools", "tidytext"
))
```

## How to run the app

Open R in this folder and run:

```r
shiny::runApp()
```

Or, if you are already inside the app folder:

```r
source("app.R")
```

If a bundled report file is present, the app will use it by default. If not, the app still opens and prompts the user to upload a CommuniMap export from the Data Summary tab.

## Deployment

If contributors also need deployment access, do not store real `rsconnect` tokens in the repository.

This repo includes [deploy_app_template.R](/c:/Users/2452200Z/OneDrive%20-%20University%20of%20Glasgow/Desktop/Communimap_data/communimap_app/deploy_app_template.R), which reads deployment credentials from environment variables instead of hard-coding them in the script.

Each contributor should set these environment variables locally on their own machine:

- `RSCONNECT_ACCOUNT`
- `RSCONNECT_TOKEN`
- `RSCONNECT_SECRET`

Then they can deploy with:

```r
source("deploy_app_template.R")
```

Or by running the same steps directly:

```r
install.packages("rsconnect")

rsconnect::setAccountInfo(
  name = Sys.getenv("RSCONNECT_ACCOUNT"),
  token = Sys.getenv("RSCONNECT_TOKEN"),
  secret = Sys.getenv("RSCONNECT_SECRET")
)

rsconnect::deployApp()
```

If you already have an older local deploy script with real credentials in it, do not commit it to GitHub. Rotate those credentials before sharing the project.

## App structure

Very roughly, the app is organised like this:

- `app.R` handles app startup, data loading, UI, and server logic
- `R/app_config.R` stores shared paths and constants
- `R/data_helpers.R` stores data-loading, spatial, and filtering helpers
- `R/sentiment_helpers.R` stores the sentiment helper functions
- `reports/colab_report.Rmd` is the downloadable report template
- `deploy_app_template.R` is a safe deployment script template that uses environment variables
- `data/` holds the report data, SIMD file, and lookup table
- `shapes/` holds the Intermediate Zone and Data Zone shapefiles

## Notes

- The default data file can be changed by editing `DATA_FILE` in `R/app_config.R`.
- If `DATA_FILE` does not exist, the app now starts in upload-only mode instead of failing at startup.
- Uploaded files are joined to Intermediate Zones in the same way as the default dataset.
- If an upload cannot be read, the app falls back to a friendly status message instead of crashing.
- The map supports both area summaries and individual report points.
- `.gitignore` excludes the January workbook, local R history, deployment metadata, and generated HTML files.
