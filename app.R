library(shiny)
library(bslib)
library(readr)
library(readxl)
library(lubridate)
library(stringr)
library(sf)
library(leaflet)
library(DT)
library(tidyr)
library(rmarkdown)
library(ggplot2)
library(dplyr)
library(htmltools)
library(tidytext)

# =========================
# APP SETUP
# =========================
source("R/app_config.R", local = TRUE)
source("R/data_helpers.R", local = TRUE)
source("R/sentiment_helpers.R", local = TRUE)

# =========================
# LOAD BASE FILES
# =========================
if (!file.exists(IZ_SHP)) stop(paste("Shapefile not found:", IZ_SHP))
if (!file.exists(DZ_SHP)) stop(paste("Data Zone shapefile not found:", DZ_SHP))
if (!file.exists(SIMD_FILE)) stop(paste("SIMD file not found:", SIMD_FILE))
if (!file.exists(LOOKUP_FILE)) stop(paste("Lookup file not found:", LOOKUP_FILE))

default_data_available <- file.exists(DATA_FILE)
df0_default <- if (default_data_available) read_spots_file(DATA_FILE) else NULL

iz <- st_read(IZ_SHP, quiet = TRUE) %>%
  st_make_valid() %>%
  st_transform(4326)

glw_bbox <- st_bbox(iz)

df_default <- if (default_data_available) spatial_join_to_iz(df0_default, iz) else NULL

# =========================
# SIMD DATA + IZ-LEVEL SUMMARY
# =========================
dz <- st_read(DZ_SHP, quiet = TRUE) %>%
  st_make_valid() %>%
  st_transform(4326)

simd_raw <- read_csv(SIMD_FILE, show_col_types = FALSE)

if (!("Data_Zone" %in% names(simd_raw))) {
  stop("SIMD file must contain column 'Data_Zone'.")
}

simd_glw <- simd_raw %>%
  rename(DataZone = Data_Zone) %>%
  filter(Council_area == "Glasgow City") %>%
  mutate(
    SIMD2020v2_Decile = suppressWarnings(as.numeric(SIMD2020v2_Decile)),
    SIMD2020v2_Rank = suppressWarnings(as.numeric(SIMD2020v2_Rank)),
    deprived20 = if_else(!is.na(SIMD2020v2_Decile) & SIMD2020v2_Decile <= 2, 1, 0),
    deprived10 = if_else(!is.na(SIMD2020v2_Decile) & SIMD2020v2_Decile == 1, 1, 0)
  )

dz_glw <- dz %>%
  inner_join(simd_glw, by = "DataZone")

dz_glw_bbox <- st_bbox(dz_glw)
# Union the Glasgow boundary in a projected CRS, then transform back for leaflet.
glasgow_outline <- iz %>%
  st_transform(27700) %>%
  st_union() %>%
  st_transform(4326)

dz_iz_lookup <- read_excel(LOOKUP_FILE, sheet = "OA_DZ_IZ_2011 Lookup") %>%
  distinct(DataZone2011Code, IntermediateZone2011Code) %>%
  rename(
    DataZone = DataZone2011Code,
    InterZone = IntermediateZone2011Code
  )

# Aggregate Data Zone deprivation values up to Intermediate Zone level for the map.
iz_names_tbl <- iz %>%
  st_drop_geometry() %>%
  select(all_of(c(IZ_KEY, IZ_NAME))) %>%
  distinct()

dz_simd_lookup <- simd_glw %>%
  inner_join(dz_iz_lookup, by = "DataZone") %>%
  left_join(iz_names_tbl, by = c("InterZone" = IZ_KEY))

iz_simd <- dz_simd_lookup %>%
  group_by(InterZone, .data[[IZ_NAME]]) %>%
  summarise(
    n_datazones = n(),
    n_deprived20 = sum(deprived20, na.rm = TRUE),
    n_deprived10 = sum(deprived10, na.rm = TRUE),
    pct_deprived20 = 100 * mean(deprived20, na.rm = TRUE),
    pct_deprived10 = 100 * mean(deprived10, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  rename(
    IZ_CODE = InterZone,
    IZ_LABEL = all_of(IZ_NAME)
  )

# =========================
# MODULE
# =========================
colabUI <- function(id, colab_name) {
  ns <- NS(id)
  tagList(
    layout_sidebar(
      sidebar = sidebar(
        width = 360,
        tags$h5(colab_name),
        tags$p(
          class = "text-muted small",
          "This dashboard brings together reports submitted to the selected CoLab across Glasgow. ",
          "You can use the filters below to explore the data by date, user role, travel mode, or keywords in the report text."
        ),
        tags$p(
          class = "text-muted small",
          "The map shows where reports are coming from. ",
          "If you click on an Intermediate Zone, the charts below will focus on that area so you can explore patterns locally."
        ),
        uiOutput(ns("date_ui")),
        uiOutput(ns("role_ui")),
        uiOutput(ns("travel_ui")),
        textInput(ns("search"), "Search text contains", value = ""),
        selectInput(ns("var"), "Summarise by", choices = c("None" = "")),
        radioButtons(
          ns("metric"), "Map metric",
          choices = c(
            "Count" = "count",
            "Rate per 1,000 residents" = "rate",
            "Average sentence sentiment" = "sentiment",
            "% of Data Zones in most deprived 20%" = "simd_pct20",
            "% of Data Zones in most deprived 10%" = "simd_pct10",
            "Number of Data Zones in most deprived 20%" = "simd_n20"
          ),
          selected = "count"
        ),
        radioButtons(
          ns("denom"), "Rate denominator",
          choices = setNames(
            c("res", "tot"),
            c(paste("Resident:", IZ_POP_RES), paste("Total:", IZ_POP_TOT))
          ),
          selected = "res"
        ),
        checkboxInput(ns("only_selected_iz"), "Filter to clicked Intermediate Zone", FALSE),
        actionButton(ns("clear_iz"), "Clear selected zone"),
        hr(),
        tags$p(
          class = "text-muted small",
          "Metric guide:",
          tags$br(),
          "• Count shows the number of reports submitted in each area.",
          tags$br(),
          "• Rate adjusts the count by population so areas can be compared more fairly.",
          tags$br(),
          "• Sentiment summarises sentence-level tone in the report text and then averages it by area.",
          tags$br(),
          "• SIMD indicators add background information about deprivation in each area."
        ),
        tags$p(
          class = "text-muted small",
          "SIMD is originally published for Data Zones. ",
          "In this dashboard, Data Zone SIMD values are linked to Intermediate Zones using the 2011 lookup and then summarised for descriptive mapping. ",
          "The most useful measures here are the percentage or number of Data Zones in the most deprived groups."
        ),
        hr(),
        downloadButton(ns("dl_report"), "Download Report", class = "btn-primary w-100")
      ),
      card(
        card_header("Intermediate Zone"),
        tags$p(
          class = "text-muted small",
          "The map highlights how activity is distributed across Glasgow. ",
          "You can switch between different metrics such as report counts, population-adjusted rates, sentiment from report text, and deprivation context using SIMD indicators."
        ),
        uiOutput(ns("summary_var_label")),
        uiOutput(ns("selected_iz_label")),
        uiOutput(ns("reset_btn_ui")),
        leafletOutput(ns("map"), height = 560)
      ),
      br(),
      card(
        card_header("Counts over time (daily)"),
        tags$p(
          class = "text-muted small",
          "This chart shows how many reports were submitted each day within the current selection. ",
          "It can help identify periods when activity increased or when particular issues may have been reported more frequently."
        ),
        plotOutput(ns("ts"), height = 360)
      ),
      br(),
      card(
        card_header("Distribution / top categories"),
        tags$p(
          class = "text-muted small",
          "Use the dropdown in the sidebar to explore the distribution of different variables collected in the reports. ",
          "If no variable is selected, the chart shows the Intermediate Zones with the highest number of submissions."
        ),
        uiOutput(ns("dist_plot_ui"))
      ),
      br(),
      card(
        card_header("Sentiment: Example Sentences"),
        tags$p(
          class = "text-muted small",
          "This table shows example sentences with the strongest positive and negative sentiment scores. ",
          "It helps you inspect the actual report language driving the sentiment metric."
        ),
        DTOutput(ns("sentiment_examples"))
      ),
      br(),
      card(
        card_header("Top Intermediate Zones"),
        tags$p(
          class = "text-muted small",
          "This table lists the areas with the highest number of reports under the current filters. ",
          "It provides a quick way to see where activity is most concentrated."
        ),
        DTOutput(ns("top_iz"))
      )
    )
  )
}

colabServer <- function(id, colab_name, data_r) {
  moduleServer(id, function(input, output, session) {
    
    colab_df <- reactive({
      req(data_r())
      data_r() %>%
        mutate(!!COL_COLAB := trimws(as.character(.data[[COL_COLAB]]))) %>%
        filter(.data[[COL_COLAB]] == trimws(colab_name))
    })
    
    output$date_ui <- renderUI({
      d <- colab_df()
      if (nrow(d) == 0 || all(is.na(d$CREATED_DATE))) {
        return(
          dateRangeInput(
            session$ns("date_rng"), "Created date range",
            start = Sys.Date() - 30,
            end = Sys.Date()
          )
        )
      }
      
      dateRangeInput(
        session$ns("date_rng"), "Created date range",
        start = min(d$CREATED_DATE, na.rm = TRUE),
        end   = max(d$CREATED_DATE, na.rm = TRUE)
      )
    })
    
    output$role_ui <- renderUI({
      d <- colab_df()
      if (!("USER_ROLE" %in% names(d))) return(NULL)
      roles <- sort(unique(na.omit(d$USER_ROLE)))
      selectInput(session$ns("user_role"), "User role", choices = c("All", roles))
    })
    
    output$travel_ui <- renderUI({
      d <- colab_df()
      if (!("TRAVEL_MODE" %in% names(d))) return(NULL)
      modes <- sort(unique(na.omit(d$TRAVEL_MODE)))
      selectInput(session$ns("travel_mode"), "Travel mode", choices = c("All", modes))
    })
    
    observe({
      req(data_r())
      v <- vars_for_colab(data_r(), colab_name)
      # Pick the first available variable so the chart is not blank on load.
      updateSelectInput(
        session, "var",
        choices = c("None" = "", v),
        selected = if (length(v) > 0) v[[1]] else ""
      )
    })
    
    selected_iz <- reactiveVal(NA_character_)
    
    observeEvent(input$map_shape_click, {
      if (!is.null(input$map_shape_click$id)) selected_iz(as.character(input$map_shape_click$id))
    })
    
    observeEvent(input$clear_iz, {
      selected_iz(NA_character_)
    })
    
    observeEvent(input$reset_selection, {
      selected_iz(NA_character_)
    })
    
    output$reset_btn_ui <- renderUI({
      if (is.na(selected_iz())) return(NULL)
      actionButton(
        session$ns("reset_selection"),
        "Reset to Global View",
        icon = icon("refresh"),
        class = "btn-outline-danger btn-sm",
        style = "margin-bottom:10px;"
      )
    })
    
    output$summary_var_label <- renderUI({
      v <- input$var
      txt <- if (is.null(v) || !nzchar(v)) DEFAULT_SUMMARY_LABEL else v
      tags$div(style = "margin-bottom:8px;", tags$b("Summarising variable: "), txt)
    })
    
    output$selected_iz_label <- renderUI({
      if (is.na(selected_iz())) {
        return(tags$div(style = "margin-bottom:8px;", tags$em("No zone selected. Click map to focus charts.")))
      }
      d <- data_r()
      lab <- d %>% filter(IZ_CODE == selected_iz()) %>% distinct(IZ_CODE, IZ_LABEL) %>% slice(1)
      tags$div(style = "margin-bottom:8px;", tags$b("Focused Zone: "), paste0(lab$IZ_CODE, " — ", lab$IZ_LABEL))
    })
    
    filtered <- reactive({
      req(input$date_rng)
      # Zone-focused view used after the user clicks an Intermediate Zone.
      apply_common_filters(
        colab_df(),
        date_rng = input$date_rng,
        user_role = input$user_role,
        travel_mode = input$travel_mode,
        search = input$search,
        selected_iz = selected_iz()
      )
    })
    
    global_filtered <- reactive({
      req(input$date_rng)
      # City-wide view for map summaries: same filters, but no zone restriction.
      apply_common_filters(
        colab_df(),
        date_rng = input$date_rng,
        user_role = input$user_role,
        travel_mode = input$travel_mode,
        search = input$search
      )
    })
    
    iz_sentiment_agg <- reactive({
      d <- global_filtered()
      sent <- compute_report_sentiment(d)
      if (nrow(sent) == 0) return(NULL)
      
      # Average the report scores within each Intermediate Zone.
      sent %>%
        filter(!is.na(IZ_CODE)) %>%
        group_by(IZ_CODE) %>%
        summarise(
          sentiment_score = round(mean(sentiment_score, na.rm = TRUE), 2),
          .groups = "drop"
        )
    })
    
    output$sentiment_examples <- renderDT({
      d <- filtered()
      sent_data <- compute_sentiment_examples(d)
      
      validate(need(nrow(sent_data) > 0, "No sentiment-bearing sentences found."))
      
      display_df <- sent_data %>%
        transmute(
          Sentiment = str_to_title(sentiment),
          Score = round(sentence_score, 2),
          Sentence = sentence
        )
      
      datatable(
        display_df,
        rownames = FALSE,
        escape = TRUE,
        options = list(
          dom = "tip",
          paging = FALSE,
          searching = FALSE,
          info = FALSE,
          ordering = FALSE,
          autoWidth = TRUE,
          columnDefs = list(
            list(width = "12%", targets = 0),
            list(width = "10%", targets = 1),
            list(width = "78%", targets = 2)
          )
        )
      ) %>%
        formatStyle(
          "Sentence",
          `white-space` = "normal",
          `word-break` = "break-word",
          `line-height` = "1.4"
        ) %>%
        formatStyle(
          "Sentiment",
          target = "row",
          backgroundColor = styleEqual(
            c("Negative", "Positive"),
            c("#fff1ee", "#eef9f0")
          )
        )
    })

    output$dist_plot_ui <- renderUI({
      d <- global_filtered()
      v <- input$var

      height_px <- 400

      if (!is.null(v) && nzchar(v) && v %in% names(d) && !is.numeric(d[[v]])) {
        n_cats <- d %>%
          transmute(vv = as.character(.data[[v]])) %>%
          filter(!is.na(vv) & vv != "") %>%
          distinct(vv) %>%
          nrow()

        # Give long category labels more vertical room in narrower layouts.
        height_px <- max(420, min(700, 52 * min(n_cats, 12)))
      }

      plotOutput(session$ns("dist"), height = paste0(height_px, "px"))
    })
    
    iz_agg <- reactive({
      # Report counts by Intermediate Zone after the city-wide filters are applied.
      global_filtered() %>%
        filter(!is.na(IZ_CODE)) %>%
        count(IZ_CODE, IZ_LABEL, name = "n")
    })

    map_points <- reactive({
      d <- if (isTRUE(input$only_selected_iz)) filtered() else global_filtered()

      d %>%
        filter(is.finite(.data[[COL_LAT]]), is.finite(.data[[COL_LON]])) %>%
        mutate(
          map_lat = .data[[COL_LAT]],
          map_lng = .data[[COL_LON]],
          popup_text = sprintf(
            paste0(
              "<b>CoLab:</b> %s<br>",
              "<b>Created:</b> %s<br>",
              "<b>Intermediate Zone:</b> %s<br>",
              "<b>Description:</b> %s"
            ),
            htmlEscape(coalesce(as.character(.data[[COL_COLAB]]), "Not provided")),
            htmlEscape(coalesce(as.character(CREATED_DATE), "Not provided")),
            htmlEscape(coalesce(as.character(IZ_LABEL), "Not provided")),
            htmlEscape(coalesce(as.character(DESCRIPTION), "Not provided"))
          )
        )
    })
    
    output$map <- renderLeaflet({
      leaflet(iz) %>%
        addProviderTiles(providers$CartoDB.Positron) %>%
        fitBounds(
          as.numeric(glw_bbox$xmin), as.numeric(glw_bbox$ymin),
          as.numeric(glw_bbox$xmax), as.numeric(glw_bbox$ymax)
        )
    })
    
    observe({
      a <- iz_agg()
      s <- iz_sentiment_agg()
      pts <- map_points()
      
      # Pull counts, sentiment, and SIMD context together before drawing the map.
      g <- iz %>%
        left_join(a, by = setNames("IZ_CODE", IZ_KEY)) %>%
        left_join(s, by = setNames("IZ_CODE", IZ_KEY)) %>%
        left_join(iz_simd, by = setNames("IZ_CODE", IZ_KEY)) %>%
        mutate(
          n = coalesce(n, 0L),
          sentiment_score = coalesce(sentiment_score, 0),
          n_datazones = coalesce(n_datazones, 0L),
          n_deprived20 = coalesce(n_deprived20, 0L),
          n_deprived10 = coalesce(n_deprived10, 0L),
          pct_deprived20 = coalesce(pct_deprived20, 0),
          pct_deprived10 = coalesce(pct_deprived10, 0),
          rate = case_when(
            input$denom == "tot" & as.numeric(.data[[IZ_POP_TOT]]) > 0 ~ 1000 * n / as.numeric(.data[[IZ_POP_TOT]]),
            as.numeric(.data[[IZ_POP_RES]]) > 0 ~ 1000 * n / as.numeric(.data[[IZ_POP_RES]]),
            TRUE ~ 0
          ),
          metric = case_when(
            input$metric == "count" ~ ifelse(n == 0, NA_real_, as.numeric(n)),
            input$metric == "rate" ~ as.numeric(rate),
            input$metric == "sentiment" ~ as.numeric(sentiment_score),
            input$metric == "simd_pct20" ~ as.numeric(pct_deprived20),
            input$metric == "simd_pct10" ~ as.numeric(pct_deprived10),
            input$metric == "simd_n20" ~ as.numeric(n_deprived20),
            TRUE ~ as.numeric(n)
          )
        )
      
      # Use different palettes for sentiment, deprivation, and count-based views.
      pal <- if (input$metric == "sentiment") {
        colorNumeric("RdYlGn", domain = c(-1, 1), na.color = NA_MAP_COLOR)
      } else if (input$metric %in% c("simd_pct20", "simd_pct10")) {
        colorNumeric("magma", domain = c(0, 100), na.color = NA_MAP_COLOR)
      } else {
        colorNumeric("viridis", domain = g$metric, na.color = NA_MAP_COLOR)
      }
      
      label <- sprintf(
        paste0(
          "<b>IZ:</b> %s<br>",
          "<b>Name:</b> %s<br>",
          "<b>Count:</b> %s<br>",
          "<b>Rate/1k:</b> %s<br>",
          "<b>Sentiment:</b> %s<br>",
          "<b>No. of Data Zones:</b> %s<br>",
          "<b>%% in most deprived 20%%:</b> %s<br>",
          "<b>%% in most deprived 10%%:</b> %s<br>",
          "<b>No. in most deprived 20%%:</b> %s"
        ),
        g[[IZ_KEY]],
        g[[IZ_NAME]],
        g$n,
        round(g$rate, 2),
        round(g$sentiment_score, 2),
        g$n_datazones,
        round(g$pct_deprived20, 1),
        round(g$pct_deprived10, 1),
        g$n_deprived20
      ) %>% lapply(HTML)
      
      legend_title <- dplyr::case_when(
        input$metric == "count" ~ "Count",
        input$metric == "rate" ~ "Rate per 1,000",
        input$metric == "sentiment" ~ "Average sentence sentiment",
        input$metric == "simd_pct20" ~ "% of Data Zones in most deprived 20%",
        input$metric == "simd_pct10" ~ "% of Data Zones in most deprived 10%",
        input$metric == "simd_n20" ~ "Number of Data Zones in most deprived 20%",
        TRUE ~ input$metric
      )
      
      leafletProxy("map", data = g) %>%
        clearShapes() %>%
        clearGroup("report_points") %>%
        clearControls() %>%
        addPolygons(
          layerId = ~get(IZ_KEY),
          fillColor = ~pal(metric),
          fillOpacity = 0.7,
          weight = 1,
          color = "white",
          label = label,
          highlightOptions = highlightOptions(weight = 2, color = "#222", bringToFront = TRUE)
        ) %>%
        addCircleMarkers(
          data = pts,
          lng = ~map_lng,
          lat = ~map_lat,
          radius = 4,
          stroke = TRUE,
          weight = 1,
          color = "#0f172a",
          fillColor = "#f97316",
          fillOpacity = 0.75,
          opacity = 0.9,
          popup = ~popup_text,
          group = "report_points"
        ) %>%
        addLegend(
          "bottomright",
          pal = pal,
          values = if (input$metric == "sentiment") c(-1, 1) else ~metric,
          title = legend_title
        )
    })
    
    output$ts <- renderPlot({
      d <- filtered()
      validate(need(nrow(d) > 0, "No data."))
      d %>%
        count(CREATED_DATE) %>%
        ggplot(aes(CREATED_DATE, n)) +
        geom_col(fill = "#2c3e50") +
        scale_x_date(date_breaks = "2 months", date_labels = "%b\n%Y") +
        scale_y_continuous(expand = expansion(mult = c(0, 0.05))) +
        theme_minimal(base_size = 17) +
        theme(
          plot.title = element_text(size = 20, face = "bold"),
          axis.title = element_text(size = 15),
          axis.text = element_text(size = 13, colour = "#2f2f2f"),
          axis.text.x = element_text(size = 13, lineheight = 0.9),
          panel.grid.minor = element_blank(),
          plot.margin = margin(12, 18, 12, 12)
        ) +
        labs(
          x = "Date",
          y = "Count",
          title = if (!is.na(selected_iz())) paste("Timeline for:", selected_iz()) else "Global Timeline"
        )
    }, res = 108)
    
    output$dist <- renderPlot({
      d <- global_filtered()
      v <- input$var
      if (is.null(v) || !nzchar(v) || !(v %in% names(d))) {
        # If no summary variable is selected, show the busiest zones instead.
        tmp <- d %>%
          count(IZ_LABEL, sort = TRUE) %>%
          head(12) %>%
          mutate(IZ_LABEL = str_wrap(IZ_LABEL, width = 18))
        return(
          ggplot(tmp, aes(reorder(IZ_LABEL, n), n)) +
            geom_col(fill = "#18bc9c") +
            coord_flip() +
            scale_y_continuous(expand = expansion(mult = c(0, 0.05))) +
            theme_minimal(base_size = 17) +
            theme(
              plot.title = element_text(size = 20, face = "bold"),
              axis.title = element_text(size = 15),
              axis.text = element_text(size = 12, colour = "#2f2f2f"),
              axis.text.y = element_text(lineheight = 0.95),
              panel.grid.minor = element_blank(),
              plot.margin = margin(12, 18, 12, 24)
            ) +
            labs(x = NULL, y = "Count", title = "Top Zones (Global)")
        )
      }
      if (is.numeric(d[[v]])) {
        # Plot numeric fields as a histogram.
        tmp_num <- d %>%
          filter(is.finite(.data[[v]]))
        validate(need(nrow(tmp_num) > 0, "No numeric values available."))
        ggplot(tmp_num, aes(x = .data[[v]])) +
          geom_histogram(bins = 30, fill = "#18bc9c") +
          theme_minimal(base_size = 17) +
          theme(
            axis.title = element_text(size = 15),
            axis.text = element_text(size = 13, colour = "#2f2f2f"),
            panel.grid.minor = element_blank(),
            plot.margin = margin(12, 18, 12, 12)
          ) +
          labs(x = v, y = "Count")
      } else {
        # Plot categorical fields as counts of the most common values.
        tmp <- d %>%
          mutate(vv = as.character(.data[[v]])) %>%
          filter(!is.na(vv) & vv != "") %>%
          count(vv, sort = TRUE) %>%
          head(12) %>%
          mutate(vv = str_wrap(vv, width = 18))
        ggplot(tmp, aes(reorder(vv, n), n)) +
          geom_col(fill = "#18bc9c") +
          coord_flip() +
          scale_y_continuous(expand = expansion(mult = c(0, 0.05))) +
          theme_minimal(base_size = 17) +
          theme(
            axis.title = element_text(size = 15),
            axis.text = element_text(size = 12, colour = "#2f2f2f"),
            axis.text.y = element_text(lineheight = 0.95),
            panel.grid.minor = element_blank(),
            plot.margin = margin(12, 18, 12, 24)
          ) +
          labs(x = NULL, y = "Count")
      }
    }, res = 108)
    
    output$top_iz <- renderDT({
      datatable(
        iz_agg() %>%
          left_join(iz_sentiment_agg(), by = "IZ_CODE") %>%
          arrange(desc(n)),
        rownames = FALSE
      ) %>%
        formatStyle(
          "sentiment_score",
          backgroundColor = styleInterval(c(-0.1, 0.1), c("#ffcccc", "#f8f9fa", "#ccffcc"))
        )
    })
    
    output$dl_report <- downloadHandler(
      filename = function() {
        paste0("Summary_Report_", gsub(" ", "_", colab_name), "_", Sys.Date(), ".html")
      },
      content = function(file) {
        rmarkdown::render(
          REPORT_TEMPLATE,
          output_file = file,
          params = list(data = filtered(), title = colab_name),
          envir = new.env(parent = globalenv()),
          quiet = TRUE
        )
      }
    )
  })
}

# =========================
# MAIN APP
# =========================
ui <- fluidPage(
  uiOutput("main_ui")
)

server <- function(input, output, session) {
  
  active_df0 <- reactive({
    infile <- input$upload
    if (is.null(infile)) return(df0_default)
    
    # Return NULL on a bad upload so the UI can show a message instead of crashing.
    tryCatch({
      read_spots_file(infile$datapath)
    }, error = function(e) {
      NULL
    })
  })
  
  active_df <- reactive({
    d0 <- active_df0()
    if (is.null(d0)) return(NULL)
    
    # Join the uploaded or default records to Intermediate Zones before the tabs use them.
    tryCatch({
      spatial_join_to_iz(d0, iz)
    }, error = function(e) {
      NULL
    })
  })
  
  active_colabs <- reactive({
    d <- active_df()
    if (is.null(d) || nrow(d) == 0) return(character(0))
    # Build tabs from the categories that are actually present in the current data.
    out <- sort(unique(trimws(as.character(d[[COL_COLAB]]))))
    out[!is.na(out) & nzchar(out)]
  })
  
  output$main_ui <- renderUI({
    colab_names <- active_colabs()
    colab_panels <- lapply(colab_names, function(cn) {
      tabPanel(cn, colabUI(paste0("tab_", make.names(cn)), cn))
    })
    
    if (length(colab_panels) == 0) {
      colab_panels <- list(
        tabPanel(
          "Upload data",
          fluidPage(
            card(
              card_header("No report data loaded"),
              tags$p(
                class = "text-muted",
                "The app is running, but there is no bundled CommuniMap report dataset in this copy of the project."
              ),
              tags$p(
                class = "text-muted",
                "Use the upload control in the Data Summary tab to load a valid CommuniMap export and unlock the CoLab dashboards."
              )
            )
          )
        )
      )
    }
    
    navbarPage(
      title = "CommuniMap Glasgow",
      theme = bs_theme(version = 5, bootswatch = "flatly"),
      
      tabPanel(
        "Data Summary",
        fluidPage(
          layout_sidebar(
            sidebar = sidebar(
              width = 360,
              tags$h5("Data Management"),
              fileInput("upload", "Upload new data (.csv, .xlsx, .xls)", accept = c(".csv", ".xlsx", ".xls")),
              br(),
              div(class = "alert alert-info", textOutput("status_msg", inline = TRUE))
            ),
              card(
                card_header("About the data used in this app"),
                tags$p(
                  class = "text-muted",
                  "This dashboard is designed to explore CommuniMap reports across Glasgow. ",
                  "The app can run either on a bundled report dataset, if one is included, or on a file uploaded by the user."
                ),
                tags$p(
                  class = "text-muted",
                "The uploaded data should be an exported file from CommuniMap in the same structure as the original export used to build this dashboard. ",
                "In particular, the file should contain the key fields needed for mapping and filtering, including category, latitude, longitude."
              ),
              tags$p(
                class = "text-muted",
                "Supported file types are .csv, .xlsx, and .xls. ",
                "If the uploaded file does not follow the expected format, the dashboard may not be able to read it correctly."
              ),
              tags$p(
                class = "text-muted",
                "The app also uses external geography and deprivation files in the background: ",
                "Intermediate Zone boundaries, Data Zone boundaries, SIMD data, and the 2011 lookup linking Data Zones to Intermediate Zones."
              )
            ),
            br(),
            card(
              card_header("Current data source"),
              verbatimTextOutput("current_data_info")
            ),
            br(),
            card(card_header("Counts by CoLab"), DTOutput("dq_counts")),
            br(),
            card(card_header("Spatial Join Statistics"), verbatimTextOutput("dq_join"))
          )
        )
      ),
      
      tabPanel(
        "SIMD Map",
        fluidPage(
          layout_sidebar(
            sidebar = sidebar(
              width = 360,
              tags$h5("SIMD Layer"),
              tags$p(
                class = "text-muted small",
                "This tab shows the original SIMD map at Data Zone level for Glasgow."
              ),
              tags$p(
                class = "text-muted small",
                "Data Zones are smaller than Intermediate Zones, so this map gives a more detailed view of deprivation patterns across the city."
              ),
              tags$p(
                class = "text-muted small",
                "The map opens with SIMD rank by default, and you can switch to the individual domain ranks such as income, employment, health, education, access, crime, and housing."
              ),
              selectInput(
                "simd_var",
                "Choose SIMD variable",
                choices = c(
                  "SIMD 2020 Rank" = "SIMD2020v2_Rank",
                  "Income Domain Rank" = "SIMD2020v2_Income_Domain_Rank",
                  "Employment Domain Rank" = "SIMD2020_Employment_Domain_Rank",
                  "Health Domain Rank" = "SIMD2020_Health_Domain_Rank",
                  "Education Domain Rank" = "SIMD2020_Education_Domain_Rank",
                  "Access Domain Rank" = "SIMD2020_Access_Domain_Rank",
                  "Crime Domain Rank" = "SIMD2020_Crime_Domain_Rank",
                  "Housing Domain Rank" = "SIMD2020_Housing_Domain_Rank"
                ),
                selected = "SIMD2020v2_Rank"
              )
            ),
            card(
              card_header("SIMD Data Zone Map"),
              tags$p(
                class = "text-muted small",
                "This is the detailed SIMD map. It is useful if you want to look directly at deprivation patterns without averaging them up to Intermediate Zone level."
              ),
              leafletOutput("simd_map", height = 700)
            )
          )
        )
      ),
      
      do.call(navbarMenu, c(list("CoLabs"), colab_panels))
    )
  })
  
  observe({
    lapply(active_colabs(), function(cn) {
      colabServer(paste0("tab_", make.names(cn)), cn, active_df)
    })
  })
  
  output$status_msg <- renderText({
    if (is.null(input$upload) && default_data_available) {
      paste("Currently using the default dataset:", DATA_FILE)
    } else if (is.null(input$upload)) {
      "No default report dataset is bundled with this copy of the app. Upload a CommuniMap export to start using the CoLab dashboards."
    } else if (is.null(active_df0())) {
      "Uploaded file could not be read. Please check that it is a valid CommuniMap export with the expected columns."
    } else {
      paste("Currently using uploaded file:", input$upload$name)
    }
  })
  
  output$current_data_info <- renderPrint({
    using_uploaded <- !is.null(input$upload) && !is.null(active_df0())
    
    list(
      active_report_data = if (using_uploaded) {
        input$upload$name
      } else if (default_data_available) {
        DATA_FILE
      } else {
        NA_character_
      },
      active_report_source = if (using_uploaded) {
        "Uploaded by user"
      } else if (default_data_available) {
        "Default app data"
      } else {
        "No bundled report data"
      },
      intermediate_zone_shapefile = IZ_SHP,
      data_zone_shapefile = DZ_SHP,
      simd_file = SIMD_FILE,
      lookup_file = LOOKUP_FILE,
      rows_in_raw_data = if (!is.null(active_df0())) nrow(active_df0()) else NA_integer_,
      rows_joined_to_intermediate_zone = if (!is.null(active_df())) nrow(active_df()) else NA_integer_,
      date_range_in_active_data = if (!is.null(active_df0()) && any(!is.na(active_df0()$CREATED_DATE))) {
        paste(min(active_df0()$CREATED_DATE, na.rm = TRUE), "to", max(active_df0()$CREATED_DATE, na.rm = TRUE))
      } else {
        NA_character_
      }
    )
  })
  
  output$dq_counts <- renderDT({
    validate(need(!is.null(active_df()) && nrow(active_df()) > 0, "No report data loaded yet."))
    req(active_df())
    datatable(active_df() %>% count(.data[[COL_COLAB]], sort = TRUE))
  })
  
  output$dq_join <- renderPrint({
    validate(need(!is.null(active_df0()) && !is.null(active_df()), "No report data loaded yet."))
    req(active_df0(), active_df())
    list(
      n_total = nrow(active_df0()),
      n_with_latlon = sum(is.finite(active_df0()[[COL_LAT]]) & is.finite(active_df0()[[COL_LON]]), na.rm = TRUE),
      n_with_parsed_date = sum(!is.na(active_df0()$CREATED_DATE)),
      n_joined_to_iz = nrow(active_df()),
      n_iz_with_simd_summary = nrow(iz_simd)
    )
  })
  
  output$simd_map <- renderLeaflet({
    default_var <- if (!is.null(input$simd_var) && input$simd_var %in% names(dz_glw)) {
      input$simd_var
    } else {
      "SIMD2020v2_Rank"
    }
    
    simd_obj <- build_simd_map_data(dz_glw, default_var)
    
    leaflet(simd_obj$data) %>%
      addProviderTiles(providers$CartoDB.Positron) %>%
      fitBounds(
        as.numeric(dz_glw_bbox$xmin), as.numeric(dz_glw_bbox$ymin),
        as.numeric(dz_glw_bbox$xmax), as.numeric(dz_glw_bbox$ymax)
      ) %>%
      addPolygons(
        fillColor = ~simd_obj$pal(metric),
        fillOpacity = 0.75,
        weight = 0.6,
        color = "white",
        label = simd_obj$label,
        highlightOptions = highlightOptions(weight = 1.5, color = "#222", bringToFront = TRUE)
      ) %>%
      addPolylines(
        data = glasgow_outline,
        color = "#333333",
        weight = 1,
        opacity = 0.8,
        fill = FALSE
      ) %>%
      addLegend(
        "bottomright",
        pal = simd_obj$pal,
        values = simd_obj$data$metric,
        title = default_var
      )
  })
  
  observeEvent(input$simd_var, {
    req(input$simd_var)
    req(input$simd_var %in% names(dz_glw))
    
    simd_obj <- build_simd_map_data(dz_glw, input$simd_var)
    
    leafletProxy("simd_map", data = simd_obj$data) %>%
      clearShapes() %>%
      clearControls() %>%
      addPolygons(
        fillColor = ~simd_obj$pal(metric),
        fillOpacity = 0.75,
        weight = 0.6,
        color = "white",
        label = simd_obj$label,
        highlightOptions = highlightOptions(weight = 1.5, color = "#222", bringToFront = TRUE)
      ) %>%
      addPolylines(
        data = glasgow_outline,
        color = "#333333",
        weight = 1,
        opacity = 0.8,
        fill = FALSE
      ) %>%
      addLegend(
        "bottomright",
        pal = simd_obj$pal,
        values = simd_obj$data$metric,
        title = input$simd_var
      )
  }, ignoreInit = TRUE)
}

shinyApp(ui, server)
