# Put in NEWS.md when ready

# * A new function, `rob_blobbogram()` has been added in response to
# https://github.com/mcguinlu/robvis/issues/102 by @rdboyes.

#' Risk of bias blobbogram plot
#'
#' @param ma an object from the brms or metafor packages
#' @param rob a risk of bias table, either ROB2, ROB2-Cluster, QUADAS-2, or Robins (see example data)
#' @param rob_tool The risk of bias tool used. Defaults to ROB2. Supports "ROB2", "ROB2-Cluster", "QUADAS-2", and "Robins".
#' @param rob_colour The risk of bias colour scheme. As in other robvis functions. Supports "cochrane", "colourblind" or a custom vector of colours.
#' @param subset_col Column containing the variable to subset the meta-analysis by. Default "Overall".
#' @param subset_col_order An optional vector containing the levels of "subset_col" in the order that they should appear in the table.
#' @param overall_estimate Logical. Show a summary measure across groups?
#' @param add_tests Logical. Should a summary of statistical tests by subgroup be included as a row?
#' @param ... options to be passed to forester::forester. See https://github.com/rdboyes/forester for more information.
#'
#' @return an image
#'
#' @export
rob_blobbogram <- function(ma,
                           rob,
                           rob_tool = "ROB2",
                           rob_colour = "cochrane",
                           subset_col = "Overall",
                           space_last = TRUE,
                           subset_col_order = NULL,
                           overall_estimate = TRUE,
                           add_tests = TRUE,
                           cache_label = 'foo',
                           iter = '1e4',
                           sd_prior = 'cauchy(0, .3)',
                           adapt_delta = 0.8,
                           ...){

  if (class(ma) == 'brmsfit') {  # brms meta-analysis
    data <- brms_object_to_table(ma, rob, cache_label = cache_label, subset_col = 'group',
                                 iter = iter, sd_prior = sd_prior, adapt_delta = adapt_delta)
  } else {                       # metafor meta-analysis
    data <- metafor_object_to_table(ma,
                                    rob,
                                    subset_col = subset_col,
                                    rob_tool = rob_tool,
                                    rob_colour = rob_colour,
                                    subset_col_order = subset_col_order,
                                    overall_estimate = overall_estimate,
                                    add_tests = add_tests)
  }

  rob_plot <- select_rob_columns(data, rob_tool) %>%
    appendable_rob_ggplot(rob_tool = rob_tool,
                          rob_colour = rob_colour,
                          space_last = space_last)

  forester::forester(dplyr::select(data, Study),
                     data$est,
                     data$ci_low,
                     data$ci_high,
                     add_plot = rob_plot,
                     ...)

}

# Helpers for rob_blobbogram ====

brms_function <- function(model, data = dat, average_effect_label = 'Pooled effect',
                          iter = '50e4', sd_prior = "cauchy(0, .3)", adapt_delta = 0.8, cache_file = 'foo') {
  ## https://github.com/mvuorre/brmstools
  ## https://vuorre.netlify.com/post/2016/09/29/meta-analysis-is-a-special-case-of-bayesian-multilevel-modeling/

  # store study names to avoid clashes with commas in spread_draws() column specifications
  data <- data %>%
    mutate(study_number = as.numeric(rownames(data)))
  study_names <- data %>% select(study_number, Study)

  model <- brm(
    d | se(se) ~ 1 + (1 | study_number),
    data = data,
    chains=8, iter=iter,
    prior = c(prior_string("normal(0,1)", class = "Intercept"),
              prior_string(sd_prior, class = "sd")),
    control = list(adapt_delta = adapt_delta),
    file = paste(cache_file, 'brms', sep = '-')
  )

  # For an explanation of tidybayes::spread_draws(), refer to http://mjskay.github.io/tidybayes/articles/tidy-brms.html
  # Study-specific effects are deviations + average
  draws <- spread_draws(model, r_study_number[study_number, term], b_Intercept) %>%
    rename(b = b_Intercept) %>%
    mutate(b = r_study_number + b) %>%
    left_join(study_names, by = 'study_number')

  # Average effect
  draws_overall <- spread_draws(model, b_Intercept) %>%
    rename(b = b_Intercept) %>%
    mutate(Study = average_effect_label)

  # Combine average and study-specific effects' data frames
  combined_draws <- bind_rows(draws, draws_overall) %>%
    ungroup() %>%
    mutate(Study = fct_relevel(Study, average_effect_label, after = Inf)) # put overall effect after individual studies

  # summarise in metafor format
  metafor <- group_by(combined_draws, Study) %>%
    mean_hdci(b) %>% # FIXME: parameterise interval
    rename(est = b, ci_low = .lower, ci_high = .upper)

  return(metafor)
}

brms_object_to_table <- function(model, rob, overall_estimate = FALSE, subset_col = "Overall",
                                 rob_colour = "cochrane", rob_tool = "ROB2", subset_col_order = NULL,
                                 iter = '1e4', sd_prior = "cauchy(0, .3)", adapt_delta = 0.8,
                                 cache_label = 'foo') {

  table <- merge(data.frame(model$data %>% select(Study, d, se), stringsAsFactors = FALSE),
                 rob, by = "Study")

  # Reorder data
  table <- dplyr::select(table, Study, dplyr::everything())

  # Clean level names so that they look nice in the table
  table[[subset_col]] <- stringr::str_to_sentence(table[[subset_col]])
  levels <- unique(table[[subset_col]])

  if(!(is.null(subset_col_order))){
    levels <- intersect(subset_col_order, levels)
  }else if(rob_tool %in% c("ROB2", "QUADAS-2", "ROB2-Cluster") & subset_col == "Overall"){
    levels <- intersect(c("High", "Some concerns", "Low", "No information"), levels)
  }else if(rob_tool == "Robins" & subset_col == "Overall"){
    levels <- intersect(c("Critical", "Serious", "Moderate", "Low", "No information"), levels)
  }

  # Work out if only one level is present. Passed to create_subtotal_row(), so
  # that if only one group, no subtotal is created.
  single_group <- ifelse(length(levels)==1, TRUE, FALSE)

  # Subset data by levels, run user-defined metafor function on them, and
  # recombine along with Overall rma output
  subset <- lapply(levels, function(level){dplyr::filter(table, !!as.symbol(subset_col) == level)})
  names(subset) <- levels

  # model each data subset
  subset_res <- lapply(levels, function(level){brms_function(model, data = subset[[level]],
                                                             iter = iter, sd_prior = sd_prior, adapt_delta = adapt_delta,
                                                             cache_file = paste(cache_label, level, sep = '-'))})
  names(subset_res) <- levels

  # This binds the table together
  subset_tables <-
    lapply(levels, function(level){
      rbind(
        create_title_row(level),
        dplyr::select(subset_res[[level]], Study, .data$est, .data$ci_low, .data$ci_high)
      )
    })

  subset_table <- do.call("rbind", lapply(subset_tables, function(x) x))

  ordered_table <- rbind(subset_table,
                         if (overall_estimate) {
                           create_subtotal_row(rma, "Overall", add_blank = FALSE)
                         })

  # Indent the studies for formatting purposes
  ordered_table$Study <- as.character(ordered_table$Study)
  ordered_table$Study <- ifelse(!(ordered_table$Study %in% levels) & ordered_table$Study != "Overall",
                                paste0("  ", ordered_table$Study),
                                ordered_table$Study)

  rob$Study <- paste0("  ", rob$Study)

  return(dplyr::left_join(ordered_table, rob, by = "Study"))
}

metafor_function <- function(res, data = dat){
  eval(rlang::call_modify(res$call, data = quote(data)))
}

create_subtotal_row <- function(rma,
                                name = "Subtotal",
                                single_group = FALSE,
                                add_tests = FALSE,
                                add_blank = TRUE){

  if (single_group == FALSE) {
    row <- data.frame(Study = name,
                      # est = exp(rma$b),
                      # ci_low = exp(rma$ci.lb),
                      # ci_high = exp(rma$ci.ub)
                      est = rma$b,
                      ci_low = rma$ci.lb,
                      ci_high = rma$ci.ub
                      )


    if (add_tests) {

      tests <- data.frame(
        Study = paste0(
          "Q=",
          formatC(rma$QE, digits = 2, format =
                    "f"),
          ", df=",
          rma$k - rma$p,
          ", p=",
          formatC(rma$QEp, digits = 2, format = "f"),
          "; ",
          "I^2",
          "=",
          formatC(rma$I2, digits = 1, format =
                    "f"),
          "%"
        ),

        est = c(NA),
        ci_low = c(NA),
        ci_high = c(NA))


      row <- rbind(row,
                   tests)
    }


    if(add_blank){row <- dplyr::add_row(row)}


    return(row)
  }
}

create_title_row <- function(title){
  return(data.frame(Study = title, est = NA, ci_low = NA, ci_high = NA))
}

appendable_rob_ggplot <- function(rob_gdata, space_last = TRUE, rob_tool = "ROB2", rob_colour = "cochrane"){
  # given a data frame with arbitrary column names, makes a rob plot with those columns
  # when space_last = true, separates the last column by a half width (usually for an overall)
  # NA rows indicate spaces

  #### turn the rob input into ggplot-able data ################################

  columns <- colnames(rob_gdata)

  rob_gdata$row_num = (nrow(rob_gdata) - 1):0

  rob_gdata <- tidyr::pivot_longer(rob_gdata, !.data$row_num, names_to = "x", values_to = "colour")

  rob_gdata <- dplyr::mutate(rob_gdata, x = purrr::map_dbl(x, ~which(. == columns)))

  if(space_last == TRUE){
    rob_gdata$x[rob_gdata$x == max(rob_gdata$x, na.rm = TRUE)] <- max(rob_gdata$x, na.rm = TRUE) + 0.5
  }

  rob_gdata <- rob_gdata[stats::complete.cases(rob_gdata), ]

  rob_colours <- get_colour(rob_tool, rob_colour)

  if(rob_tool == "Robins"){
    bias_colours <- c("Critical" = rob_colours$critical_colour,
                      "Serious" = rob_colours$high_colour,
                      "Moderate" = rob_colours$concerns_colour,
                      "Low" = rob_colours$low_colour,
                      "No information" = rob_colours$ni_colour)
  }else{
    bias_colours <- c("High" = rob_colours$high_colour,
                      "Some concerns" = rob_colours$concerns_colour,
                      "Low" = rob_colours$low_colour,
                      "No information" = rob_colours$ni_colour)
  }

  titles <- data.frame(names = columns,
                       y = (max(rob_gdata$row_num) + 1),
                       x = unique(rob_gdata$x))

  rectangles <- rob_gdata

  rectangles$xmin <- rectangles$x - 0.5
  rectangles$xmax <- rectangles$x + 0.5
  rectangles$ymin <- rectangles$row_num - 0.5
  rectangles$ymax <- rectangles$row_num + 0.5

  ############################## the rob ggplot figure #########################

  rob_plot <- ggplot2::ggplot(data = rob_gdata) +
    ggplot2::geom_rect(data = rectangles,
                       ggplot2::aes(xmin = .data$xmin,
                                    ymin = .data$ymin,
                                    xmax = .data$xmax,
                                    ymax = .data$ymax),
                       fill = "white",
                       colour = "#eff3f2") +
    ggplot2::geom_point(size = 5, ggplot2::aes(x = .data$x, y = .data$row_num, colour = .data$colour)) +
    ggplot2::geom_point(size = 3, ggplot2::aes(x = .data$x, y = .data$row_num, shape = .data$colour)) +
    ggplot2::scale_y_continuous(expand = c(0,0)) + # position dots
    ggplot2::scale_x_continuous(expand = c(0,0), limits = c(0, (max(rob_gdata$x) + 1))) +
    ggplot2::geom_text(data = titles, ggplot2::aes(label = .data$names, x = .data$x, y = .data$y)) +
    ggplot2::scale_color_manual(values = bias_colours,
                                na.translate = FALSE) +
    ggplot2::scale_shape_manual(
      values = c(
        "High" = 120,
        "Critical" = 120,
        "Serious" = 120,
        "Moderate" = 45,
        "Some concerns" = 45,
        "Low" = 43,
        "No information" = 63
      ))

  return(rob_plot)
}

metafor_object_to_table <- function(rma,
                                    rob,
                                    add_tests = TRUE,
                                    overall_estimate = TRUE,
                                    subset_col = "Overall",
                                    rob_colour = "cochrane",
                                    rob_tool = "ROB2",
                                    subset_col_order = NULL){

  table <- merge(data.frame(Study = rma$slab,
                            yi = rma$yi,
                            vi = rma$vi,
                            # est = exp(rma$yi),
                            # ci_low = exp(rma$yi - 1.96 * sqrt(rma$vi)),
                            # ci_high = exp(rma$yi + 1.96 * sqrt(rma$vi)),
                            est = rma$yi,
                            ci_low =  rma$yi - 1.96 * sqrt(rma$vi),
                            ci_high = rma$yi + 1.96 * sqrt(rma$vi),
                            stringsAsFactors = FALSE),
                 rob,
                 by = "Study")

  # Reorder data
  table <- dplyr::select(table, Study, dplyr::everything())

  # Clean level names so that they look nice in the table
  table[[subset_col]] <- stringr::str_to_sentence(table[[subset_col]])
  levels <- unique(table[[subset_col]])

  if(!(is.null(subset_col_order))){
    levels <- intersect(subset_col_order, levels)
  }else if(rob_tool %in% c("ROB2", "QUADAS-2", "ROB2-Cluster") & subset_col == "Overall"){
    levels <- intersect(c("High", "Some concerns", "Low", "No information"), levels)
  }else if(rob_tool == "Robins" & subset_col == "Overall"){
    levels <- intersect(c("Critical", "Serious", "Moderate", "Low", "No information"), levels)
  }

  # Work out if only one level is present. Passed to create_subtotal_row(), so
  # that if only one group, no subtotal is created.
  single_group <- ifelse(length(levels)==1, TRUE, FALSE)

  # Subset data by levels, run user-defined metafor function on them, and
  # recombine along with Overall rma output
  subset <-lapply(levels, function(level){dplyr::filter(table, !!as.symbol(subset_col) == level)})
  names(subset) <- levels

  # This takes the same metafor::rma function (including args) and runs it on each subsetted dataset
  subset_res <- lapply(levels, function(level){metafor_function(rma, data = subset[[level]])})
  names(subset_res) <- levels

  # This binds the table together
  subset_tables <-
    lapply(levels, function(level){
      rbind(
        create_title_row(level),
        dplyr::select(subset[[level]], Study, .data$est, .data$ci_low, .data$ci_high),
        create_subtotal_row(subset_res[[level]], single_group = single_group, add_tests = add_tests)
      )
    })

  subset_table <- do.call("rbind", lapply(subset_tables, function(x) x))

  ordered_table <- rbind(subset_table,
                         if (overall_estimate) {
                           create_subtotal_row(rma, "Overall", add_blank = FALSE)
                         })

  # Indent the studies for formatting purposes
  ordered_table$Study <- as.character(ordered_table$Study)
  ordered_table$Study <- ifelse(!(ordered_table$Study %in% levels) & ordered_table$Study != "Overall",
                                paste0("  ", ordered_table$Study),
                                ordered_table$Study)

  rob$Study <- paste0("  ", rob$Study)

  return(dplyr::left_join(ordered_table, rob, by = "Study"))
}

select_rob_columns <- function(dataframe, tool){
  if(tool == "QUADAS-2"){
    return_data <- select(dataframe, D1, D2, D3, D4, Overall)
  }else if(tool == "ROB1"){
    return_data <- select(dataframe,
                          RS = Random.sequence.generation.,
                          A = Allocation.concealment.,
                          BP = Blinding.of.participants.and.personnel.,
                          BO = Blinding.of.outcome.assessment,
                          I = Incomplete.outcome.data,
                          SR = Selective.reporting.,
                          Oth = Other.sources.of.bias.,
                          Overall = Overall)
  }else if(tool == "ROB2"){
    return_data <- select(dataframe, D1, D2, D3, D4, D5, Overall)
  }else if(tool == "ROB2-Cluster"){
    return_data <- select(dataframe, D1, D1b, D2, D3, D4, D5, Overall)
  }else if(tool == "Robins"){
    return_data <- select(dataframe, D1, D2, D3, D4, D5, D6, D7, Overall)
  }else{
    stop("Tool is not supported.")
  }
  return(return_data)
}
