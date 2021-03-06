#' MCmat
#'
#' This function simulates MC step for an entire matrix. Should not need to be used by user directly; available to help with determining network estimation. 
#'
#' @author Bryan Martin
#' @author Amy Willis
#' 
#' @param Y logratio matrix
#' @param W corresponding count matrix
#' @param eY current expected value of logratio matrix
#' @param N number of samples, or nrow of Y
#' @param Q number of OTUs minus the base, or ncol of Y
#' @param base OTU index used for base
#' @param sigma current estimate of sigma
#' @param MCiter number of MC samples to generate
#' @param stepsize variance used for MH samples, defaults to 1. Tweak to adjust acceptance ratio
#' @param perturbation size of purturbation used for to_log_ratios, defaults to 0.05
#' @param network How to estimate network. Defaults to "default" (generalised inverse, aka naive). Other options include "diagonal", or a function that takes a sample covariance matrix and returns an estimate of the inverse covariance matrix (eg glasso or SpiecEasi)
#' @param ncores number of cores to use, defaults to 1
#' @param ... additional arguments to be supplied to the network function
#' 
#' @import doParallel
#' @import abind
#' @import foreach
#'
#' @export
MCmat <- function(Y, W, eY, N, Q, base, sigma, MCiter, stepsize = 1, 
                  perturbation = 0.05, network = "default", ncores = 1, ...) {
  
  if (network == "diagonal") {
    sigInv <- diagonal_network(sigma)
  } else if (network == "default") {
    sigInv <- default_network(sigma)
  } else if (network == "stars") {
    sigInv <- stars(sigma, W, base = base, perturbation = perturbation, ncores = ncores, ...)
  } else { 
    sigInv <- try(network(sigma, ...), silent = T)
    if (class(sigInv) == "try-error") {
      stop("Cannot use supplied network option?")
    }
  }
  # Global variables check fix
  i <- NULL
  MH_path <- function(i) {
    MCrow(Yi = Y[i, ], Wi = W[i, ], eYi = eY[i, ], Q = Q, base = base, sigInv = sigInv, MCiter = MCiter, 
          stepsize = stepsize)
  }
  
  if (ncores > 1 & requireNamespace("doParallel", quietly = TRUE) &
      requireNamespace("foreach", quietly = TRUE) &
      requireNamespace("doSNOW", quietly = TRUE) 
  ) {
    ####################
    # Parallel option ##
    ####################
    registerDoParallel(cores = min(ncores, parallel::detectCores()))
    Y.MH <-  foreach(i = 1:N, .combine = "acomb3", .multicombine = TRUE) %dopar% {
      MH_path(i)
    }
    stopImplicitCluster()
  } else {
    ####################
    ## Series option ###
    ####################
    if (ncores > 1) {
      warning("Running in series; one of the packages doParallel, foreach or doSNOW is missing")
    }
    Y.MH <-  foreach(i = 1:N, .combine = 'acomb3', .multicombine = TRUE, .packages = "foreach") %do% {
      MH_path(i)
    }
  }
  
  # Should be (MCiter x Q x N) Dont forget, first column is acceptance
  return(Y.MH)
}

diagonal_network <- function(sigma) {
  # take diagonal vec, make it a diagonal matrix, solve
  diag(1/diag(sigma))
}


default_network <- function(sigma) {
  test <- try(chol(sigma), silent = T)
  if (class(test) == "try-error") {
    test2 <- try(svd(sigma), silent = T)
    if (class(test2) == "try-error") {
      message("SVD failed; sigma is")
      print(sigma)
      stop()
    } else {
      sigInv <- MASS::ginv(sigma)
    }
  } else {
    sigInv <- chol2inv(chol(sigma))
  }
  sigInv
}

#' stars
#' 
#' @param sigma current estimate of sigma
#' @param W corresponding count matrix
#' @param base OTU index used for base
#' @param perturbation size of purturbation used for to_log_ratios, defaults to 0.05
#' @param ncores number of cores to use, defaults to 1
#' @param ... other arguments to pass
#' 
#' Estimate the network using the package SpiecEasi
stars <- function(sigma, W, base, perturbation, ncores, ...) {
  
  if (!requireNamespace("glasso", quietly = TRUE) | !requireNamespace("SpiecEasi", quietly = TRUE)) {
    stop("Packages glasso and SpiecEasi are needed for this function to work. \n
         Please install them.",
         call. = FALSE)
  }
  Y_p <- to_log_ratios(W, base = base, perturbation = perturbation)
  inverse_covariance_estimate <- SpiecEasi::sparseiCov(data=Y_p, method = "glasso")
  selected <- SpiecEasi::icov.select(inverse_covariance_estimate, rep.num=5, ncores = ncores)
  gl <- glasso::glasso(sigma, rho = selected$opt.lambda)
  gl$wi
}