---
title: "CommuniMap Glasgow: Comprehensive Analysis Report"
output: html_document
params:
  data: NA
  title: NA
---



# CoLab Dashboard Analysis: Example CoLab

**Report Date:** 2026-03-25

**Overview:** This report summarises activity within the selected CoLab. It highlights how reports are distributed across Glasgow, how activity changes over time, and what themes appear in the report text.

---

## 1. Understanding the Sentiment Score

The sentiment score gives a simple summary of the tone of the report text. It is based on the **Bing sentiment lexicon**, which classifies sentiment-bearing words as positive or negative.

#### **Formula**

$$\text{Sentiment Score} = \text{mean of sentence polarity scores within each report}$$

Each sentence is treated as one entry, scored from the mix of positive and negative words within that sentence, and then averaged up to the report level. Repeated photo-caption boilerplate is stripped out first.

#### **How to read it**

- **Positive values:** more positive language overall
- **Around zero:** fairly neutral or mixed language
- **Negative values:** more negative language overall

This should be treated as a broad guide rather than a perfect measure of how people feel.

---

## 2. Activity Over Time

The chart below shows how many reports were submitted each day. This can help highlight busy periods, quiet periods, or sudden spikes in activity.

<img src="C:/Users/2452200Z/AppData/Local/Temp/RtmpaMAtE3/file70442a2e565_files/figure-html/ts_plot-1.png" width="864" />

---

## 3. Where Reports Are Concentrated

This figure shows the Intermediate Zones with the highest number of reports in the current selection. It gives a quick picture of which areas are most active.

<img src="C:/Users/2452200Z/AppData/Local/Temp/RtmpaMAtE3/file70442a2e565_files/figure-html/dist_plot-1.png" width="864" />

---

## 4. Example Sentences

This table highlights example sentences with the strongest positive and negative sentiment scores.


|Sentiment | Score|Sentence                                                                                                                                                                                                                                   |
|:---------|-----:|:------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|Positive  |     1|how can we improve the outcomes?                                                                                                                                                                                                           |
|Positive  |     1|it’s important to recognise how much of the carbon we consume is embedded in the things we use everyday                                                                                                                                    |
|Positive  |     1|do you think it looks like a giant diorama?                                                                                                                                                                                                |
|Positive  |     1|or is it well executed?                                                                                                                                                                                                                    |
|Negative  |    -1|a double yellow line just for length of the section of dropped kerb would make a huge difference here where cyclists transition between the road and the path over the ha’penny bridge. it’s a tricky manoeuvre when a car is blocking it. |
|Negative  |    -1|the children's group from kelvinside academy dona fishing trap for creatures inbtyeboade down from queen margaret drive. i'm their net they got one little minnie recently they have not had many fish.                                    |
|Negative  |    -1|poor tree was blown over in the wind and is struggling to survive. one of three near the entrance to the reserve. claypits.                                                                                                                |
|Negative  |    -1|honey fungus on an old tree stump along the kelvin, upstream from kelvindale weir                                                                                                                                                          |

---

## 5. Summary Table

The table below lists the top 20 Intermediate Zones in the selected data, along with the number of reports and a sentiment score where text is available.


|IZ_CODE   |IZ_LABEL                   | Count| Score|
|:---------|:--------------------------|-----:|-----:|
|S02001951 |North Kelvin               |    33|  0.49|
|S02001856 |Govan and Linthouse        |    32|  0.39|
|S02001941 |Ruchill                    |    20|  0.20|
|S02001869 |Maxwell Park               |    16|  0.25|
|S02001859 |Ibrox                      |    15|  0.47|
|S02001952 |Kelvingrove and University |    12|  1.00|
|S02001938 |Woodside                   |    11|  0.71|
|S02001868 |Strathbungo                |     8|  0.80|
|S02001888 |Toryglen and Oatlands      |     6|  0.62|
|S02001873 |Pollokshaws                |     4|    NA|
|S02001935 |Anderston                  |     4| -0.50|
|S02001842 |Darnley East               |     3|  0.50|
|S02001936 |Finnieston and Kelvinhaugh |     3|  1.00|
|S02001953 |Hillhead                   |     3|  0.53|
|S02001965 |Yoker North                |     3|  0.57|
|S02001858 |Mosspark                   |     2|    NA|
|S02001864 |Pollokshields East         |     2|  1.00|
|S02001867 |Battlefield                |     2|  0.00|
|S02001937 |Woodlands                  |     2|  1.00|
|S02001940 |Keppochhill                |     2| -1.00|
