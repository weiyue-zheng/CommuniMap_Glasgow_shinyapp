prepare_sentiment_documents <- function(d) {
  txt_fields <- intersect(TEXT_ANALYSIS_FIELDS, names(d))
  if (length(txt_fields) == 0 || nrow(d) == 0) {
    return(tibble())
  }
  
  d %>%
    mutate(.report_id = row_number()) %>%
    unite("txt", all_of(txt_fields), sep = " ", na.rm = TRUE) %>%
    mutate(
      txt = str_replace_all(txt, "_x000D_", " "),
      txt = str_to_lower(txt)
    ) %>%
    mutate(
      txt = Reduce(
        function(acc, pat) str_replace_all(acc, regex(pat, ignore_case = TRUE), " "),
        SENTIMENT_STRIP_PATTERNS,
        init = txt
      ),
      txt = str_replace_all(txt, "https?://\\S+", " "),
      txt = str_replace_all(txt, "[[:space:]]+", " "),
      txt = str_trim(txt)
    ) %>%
    filter(txt != "")
}

compute_sentence_sentiment <- function(d) {
  docs <- prepare_sentiment_documents(d)
  if (nrow(docs) == 0) {
    return(tibble())
  }
  
  docs %>%
    select(.report_id, IZ_CODE, txt) %>%
    unnest_tokens(sentence, txt, token = "sentences") %>%
    mutate(sentence = str_trim(sentence)) %>%
    filter(sentence != "") %>%
    unnest_tokens(word, sentence, drop = FALSE) %>%
    inner_join(SENTIMENT_LEXICON, by = "word") %>%
    group_by(.report_id, IZ_CODE, sentence) %>%
    summarise(
      sentiment_terms = n(),
      sentence_score = mean(value),
      .groups = "drop"
    )
}

compute_report_sentiment <- function(d) {
  sentence_scores <- compute_sentence_sentiment(d)
  if (nrow(sentence_scores) == 0) {
    return(tibble())
  }
  
  sentence_scores %>%
    group_by(.report_id) %>%
    summarise(
      sentiment_terms = n(),
      sentiment_score = mean(sentence_score),
      .groups = "drop"
    ) %>%
    inner_join(sentence_scores %>% select(.report_id, IZ_CODE) %>% distinct(), by = ".report_id")
}

compute_sentiment_examples <- function(d) {
  sentence_scores <- compute_sentence_sentiment(d)
  if (nrow(sentence_scores) == 0) {
    return(tibble())
  }
  
  bind_rows(
    sentence_scores %>%
      filter(sentence_score > 0) %>%
      slice_max(sentence_score, n = 4, with_ties = FALSE) %>%
      mutate(sentiment = "positive"),
    sentence_scores %>%
      filter(sentence_score < 0) %>%
      slice_min(sentence_score, n = 4, with_ties = FALSE) %>%
      mutate(sentiment = "negative")
  ) %>%
    arrange(desc(sentiment), desc(abs(sentence_score))) %>%
    ungroup()
}
