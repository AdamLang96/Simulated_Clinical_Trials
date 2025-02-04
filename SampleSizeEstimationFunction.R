#' Computes Power at a Given Sample Size based on predefined LME using Monte Carlo Simulation. 
#' Creates simulated covariate data based on covariates in model and multivariate distribution in pilot data.
#' Balances treatment and placebo groups at each iteration based on model covariates to ensure equal distribution and minimize Type I error
#' Additional covariates for balancing can be specified
#' 
#' @param model LME model (must be lmer)
#' @param parameter Rate of change parameter of interest (character)
#' @param pct.change Percent change in parameter of interest (numeric)
#' @param delta Change in parameter of interest (numeric)
#' @param time Vector of time points (numeric)
#' @param data Data from pilot model fit (data.frame)
#' @param sample_sizes Vector of sample sizes per arm to calculate power (numeric)
#' @param nsim Number of iterations per sample size (numeric)
#' @param sig_level Type I error level (default is .05) (numeric)
#' @param verbose Print progress during model fit (default is TRUE) (logical)
#' @param balance.covariates Additional covariates to be used to treatment group balancing that are not in the model formula (character)
#' @param test.distribution Test distribution of simulated covariates againt pilot covariates to ensure similarity (default is FALSE) (logical)
#' @return Vector of covariates
#'
SampleSizeEstimation <- function(model, parameter,    pct.change, delta = NULL, time, 
                                 data,  sample_sizes, nsim,       sig_level = .05,
                                 verbose = TRUE,      balance.covariates = NULL, 
                                 test.distribution = FALSE) {
  
  #raise errors
  
  if(!is.null(pct.change) & !is.null(delta)) {
    stop("only pct.change or delta can be specified")
  }
  
  if(is.null(pct.change) & is.null(delta)) {
    stop("pct.change or delta must be specified")
  }
  
  if(!is.null(pct.change) & pct.change > 1) {
    stop("pct.change must be numeric between 0-1")
  }
  
  if(!is.data.frame(data)) {
    stop("data must be of class data.frame")
  }
  
  if(!is.numeric(time)) {
    stop("time must be of class numeric")
  }
 
  if(!is.numeric(sample_sizes)) {
    stop("sample_sizes must be of class numeric")
  }
  
  if(!is.numeric(nsim)) {
    stop("nsim must be of class numeric")
  }
  
  if(!is.numeric(sig_level)) {
    stop("sig_level must be of class numeric")
  }
  
  if(!is.logical(verbose)) {
    stop("verbose must be of class logical")
  }
  
  if(!is.null(balance.covariates) & !is.character(balance.covariates)) {
    stop("balance.covariates must be of class character")
  }
  
  
  
  t1 <- Sys.time()
  if(verbose) {
  cat("Beginning simulation")
  cat("\n")
  }
  init_iter_list                      <-  list()
  init_significance_list              <-  list()
  init_props_list_treatment           <-  list()
  init_props_list_placebo             <-  list()
  formula_model                       <-  as.character(formula(model))
  
  # if test.distribution = TRUE this will change
  dist.comp                           <-  FALSE
  
  #get formula from model
  formula_model_join                  <-  paste(formula_model[2], formula_model[3], sep = "~")
 
  #get covariates from model formula
  model.covariates                    <-  GetCovariates(model, parameter)
  
  #get subject ID column names
  rand.effect                         <-  names(ranef(model))
  
  #cross-sectional data
  data.cs                             <-  data[!duplicated(data[rand.effect]), ]
  
  if(!is.null(balance.covariates)) {
    model.covariates <- c(model.covariates, balance.covariates)
    model.covariates <- unique(model.covariates)
  }
  column.types               <- data[ ,model.covariates]
  
  #get numeric column names
  cols.numeric               <- c(names(Filter(is.numeric, column.types)))
  cols.numeric               <- cols.numeric[cols.numeric != parameter]
  
  #check covariate data is positive
  if(!all(data[ ,cols.numeric] >= 0)) {
    stop("all covariate data must be positive")
  }
  
  cols.numeric.stratified    <- paste(cols.numeric, "_strat", sep = "")
  
  #get categorical column names
  cols.factor                <- c(names(Filter(is.factor, column.types)))
  cols.factor                <- cols.factor[cols.factor != rand.effect]
  cols.balance               <- c(cols.numeric.stratified, cols.factor)
  cols.compare               <- c(cols.numeric, cols.factor)
  
  #add treatment term to model
  model.output               <- AddTreatmentTerm(model       = model,
                                                 parameter   = parameter,
                                                 pct.change  = pct.change,
                                                 data        = data,
                                                 rand.effect = rand.effect)

  model                         <- model.output$model
  treatment_term                <- model.output$treatment_term
  iter_form_lm                  <- model.output$formula.model
  
  iter_form_lm                  <- strsplit(iter_form_lm, "~")[[1]][[2]]
  iter_form_lm                  <- paste("model_response", iter_form_lm, sep = "~")
  
  props <- list()  
  pvals <- list()
  .nsiminnerloop <- function(i, j) {
    
    #estimate multivariate distribution (cross sectional data)
    sim.covariates      <- DefineMVND(data         = data.cs, 
                                      n            = i * 2,
                                      rand.effect  = rand.effect,
                                      covariates   = model.covariates,
                                      cols.numeric = cols.numeric,
                                      cols.factor  = cols.factor)
    #extend simulated covariate data to be longitudinal based on time
    sim.covariates.long    <- ExtendLongitudinal(sim.covariates,      parameter,   time,        rand.effect)
    sim.covariates.long    <- StratifyContinuous(sim.covariates.long, data.cs,     rand.effect, parameter, cols.numeric)
    
    #assign treatment groups
    treatment.out          <- RandomizeTreatment(sim.covariates.long, rand.effect, cols.balance)
    
    prop                         <-   treatment.out[["props"]]
    data_sample_treated          <-   treatment.out[["data"]]
    
    #test balance
    props.test                   <-   PropTestIter(prop)
    levels.factors               <-   any(Map(function(x){nlevels(x)}, 
                                        data_sample_treated[ ,cols.balance]) < 2)
    if(test.distribution) {
    dist.comp                    <-   CompareDistributions(sim.data     = sim.covariates,
                                                           pilot.data   = data.cs,
                                                           cols.compare = cols.compare,
                                                           cols.factor  = cols.factor)
    }
    #resample if balance fails
    while(any(props.test <= .05) | levels.factors | dist.comp) {
      sim.covariates      <- DefineMVND(data         = data.cs, 
                                        n            = i * 2,
                                        rand.effect  = rand.effect,
                                        covariates   = model.covariates,
                                        cols.numeric = cols.numeric,
                                        cols.factor  = cols.factor)
      #extend simulated covariate data to be longitudinal based on time
      sim.covariates.long    <- ExtendLongitudinal(sim.covariates,      parameter,   time,        rand.effect)
      sim.covariates.long    <- StratifyContinuous(sim.covariates.long, data.cs,     rand.effect, parameter, cols.numeric)
      
      #assign treatment groups
      treatment.out          <- RandomizeTreatment(sim.covariates.long, rand.effect, cols.balance)
      
      prop                         <-   treatment.out[["props"]]
      data_sample_treated          <-   treatment.out[["data"]]
      
      #test balance
      props.test                   <-   PropTestIter(prop)
      levels.factors               <-   any(Map(function(x){nlevels(x)}, 
                                                data_sample_treated[ ,cols.balance]) < 2)
      if(test.distribution) {
      dist.comp                    <-   CompareDistributions(sim.data     = sim.covariates,
                                                             pilot.data   = data.cs,
                                                             cols.compare = cols.compare,
                                                             cols.factor  = cols.factor)
      }
    }
    
    #simulate outcomes based on new model with treatment term
    simulate_response_largemodel  <- simulate(model, newdata     = data_sample_treated, 
                                              allow.new.levels   = TRUE,
                                              use.u              = FALSE)
    #refit model to simulated outcomes
    refit_data_outcomes           <- data.frame("model_response" = simulate_response_largemodel)
    colnames(refit_data_outcomes) <-          c("model_response")
    fit_iter_data                 <- bind_cols(refit_data_outcomes, data_sample_treated)
    
    refit_large                   <- lme4::lmer(formula = as.formula(iter_form_lm), 
                                                data    = fit_iter_data, 
                                                REML    = TRUE)
    #get p.value of treatment term based on Satterthwaite approximation
    pval <-  as.numeric(summary(lmerTest::as_lmerModLmerTest(refit_large))[["coefficients"]][,"Pr(>|t|)"][treatment_term])
    
    if(verbose) {
    cat("\r", j, " out of ", nsim, " complete", sep = "")
    }
    
    return(list("pval"      = pval,
                "Treatment" = prop[["Treatment"]],
                "Placebo"   = prop[["Placebo"]]))
  }
  
  for(i in 1:length(sample_sizes)) {
    props_ss  <- list()
    pvals_ss  <- c()
    for(j in 1:nsim) {
      iter_j        <- .nsiminnerloop(sample_sizes[i], j)
      props_ss[[j]] <- iter_j[c("Treatment", "Placebo")]
      pvals_ss[[j]] <- iter_j[[c("pval")]]
      }
    props[[i]] <- props_ss
    pvals[[i]] <- pvals_ss
  }
  names(props) <- names(pvals) <- paste("sample_size_", sample_sizes, sep = "")
  pval.df                      <- as.data.frame(do.call(cbind, pvals))
  
  #calculate proportion of successed (p.val <= sig_level) and 95% CI's
  conf.inter                   <- GetConfInt(pval.df, sig_level)
  conf.inter$SampleSize        <- sample_sizes
  t2                           <- Sys.time()
  timerun                      <- difftime(t2, t1, units = "mins")
  
  return(list("Power_Per_Sample"          = conf.inter,
              "Run_Time"                  = timerun,
              "pval.df"                   = pval.df))
}
