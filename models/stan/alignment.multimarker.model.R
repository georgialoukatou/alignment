library(data.table)
library(bit64)
library(Matrix)
library(rstan)
library(dplyr)
library(tidyr)
library(ggplot2)
library(langcog)

ci_32 <- function(x){quantile(x,.32)}
ci_68 <- function(x){quantile(x,.68)}

#code from http://akhilsbehl.github.io/blog/2014/08/20/r-converting-a-data-dot-table-to-a-multi-way-array-cube/
dt2array = function (x, facts, dims) {
  stopifnot(is.data.table(x))
  setkeyv(x, rev(dims))
  stopifnot(!any(duplicated(x)))
  dimensions = lapply(x[ , rev(dims), with=FALSE],
                      function (x) sort(unique(x)))
  xFull = data.table(expand.grid(dimensions, stringsAsFactors=FALSE))
  setkeyv(xFull, rev(dims))
  x = data.table:::merge.data.table(xFull, x, by=dims, all=TRUE)
  factsVec = unlist(x[ , facts, with=FALSE], recursive=FALSE, use.names=FALSE)
  nFacts = length(facts)
  nDims = length(dims)
  if (nFacts > 1) {
    dim(factsVec) = c(sapply(dimensions, length), nFacts)
    dimnames(factsVec) = c(dimensions, "facts"=list(facts))
    return(aperm(factsVec, perm=c(nDims:1, nDims + 1)))
  } else {
    dim(factsVec) = sapply(dimensions, length)
    dimnames(factsVec) = dimensions
    return(aperm(factsVec))
  }
}

rstan_options(auto_write = TRUE)
options(mc.cores = parallel::detectCores())


d2 <- fread('test50cats.csv') %>%
  rename(vspeak=verifiedSpeaker,vreply=verifiedReplier) %>%
  group_by(vspeak,vreply,category) %>%
  summarise_each(funs(sum), ba, nba, bna, nbna) %>%
  mutate(pa = log(ba/(ba+nba)) - log(bna/(bna+nbna))) %>%
  arrange(vspeak,vreply,category)

counts_ab <- dt2array(d2,"ba",c("vspeak","vreply","category"))
counts_notab <- dt2array(d2,"bna",c("vspeak","vreply","category"))

num_utterances_ab <- counts_ab + dt2array(d2,"nba",c("vspeak","vreply","category"))
num_utterances_notab <- counts_notab + dt2array(d2,"nbna",c("vspeak","vreply","category"))

pa <- dt2array(d2,"pa",c("vspeak","vreply","category"))

num_subpops <- 2
num_markers <- 6

alignment_data <- list(NumMarkers=num_markers,
                       NumSubPops = num_subpops,
                       NumUtterancesAB = num_utterances_ab,
                       NumUtterancesNotAB = num_utterances_notab,
                       CountsAB = counts_ab,
                       CountsNotAB = counts_notab)


fit <- stan(file = 'alignment.multimarker.stan', data = alignment_data, 
            iter = 1000, chains =1 )

eta_ab_subpops <- colMeans(rstan:::extract(fit,"eta_ab_subpops")$eta_ab_subpops)
eta_subpops <- colMeans(rstan:::extract(fit,"eta_subpop")$eta_subpop)

#These should be very high if the model is learning correctly
cor(1/(1+exp(-eta_subpops-eta_ab_subpops)),counts_ab/num_utterances_ab)
cor(1/(1+exp(-eta_subpops)),counts_notab/num_utterances_notab)

#eta_ab_pop (the amount people align for each marker) should be positive in general
eta_pop <- colMeans(rstan:::extract(fit,"eta_pop")$eta_pop)
eta_ab_pop <- colMeans(rstan:::extract(fit,"eta_ab_pop")$eta_ab_pop)

#comparing mean p(A)-smoothed to inferred log p(B|A) - log p(B|-A) [mean across markers]
log(mu_ab)-log(mu_notab)
apply(pa,c(1,2),mean)

#eta_alignment is the average amount (across markers) that subgroups align
# This is our key variable for determining alignment to power
eta_alignment <- apply(rstan:::extract(fit,"eta_ab_subpops")$eta_ab_subpops,c(2,3),mean)


eta_ab_pop <- rstan:::extract(fit,"eta_ab_pop")$eta_ab_pop
eta_pop <- rstan:::extract(fit,"eta_pop")$eta_pop
n_pop <- mean(rstan:::extract(fit,"n_pop")$n_pop)
n_person <- colMeans(rstan:::extract(fit,"n_person")$n_person)

eta_pop <- mean(rstan:::extract(fit,"eta_pop")$eta_pop)
eta_person <- colMeans(rstan:::extract(fit,"eta_person")$eta_person)

theta_a <- colMeans(rstan:::extract(fit,"thetaA")$thetaA)
theta_nota <- colMeans(rstan:::extract(fit,"thetaNotA")$thetaNotA)
theta_diffs <- log(theta_a) - log(theta_nota)

theta_a <- rstan:::extract(fit,"thetaA")$thetaA
theta_nota <- rstan:::extract(fit,"thetaNotA")$thetaNotA
theta_diffs <- rstan:::extract(fit,"thetaA")$thetaA - rstan:::extract(fit,"thetaNotA")$thetaNotA



diff_ff <- theta_diffs[,1,1]
diff_ft <- theta_diffs[,1,2]
diff_tf <- theta_diffs[,2,1]
diff_tt <- theta_diffs[,2,2]

diff_ff <- theta_diffs[,1,1]
diff_ft <- theta_diffs[,1,2]
diff_tf <- theta_diffs[,2,1]
diff_tt <- theta_diffs[,2,2]

qplot(1:500,ff,geom ="smooth")
qplot(1:500,tf,geom = "smooth")

mu_ab <- rstan:::extract(fit,"mu_ab")$mu_ab

mu_ff <- mu_ab[,1,1]
mu_ft <- mu_ab[,1,2]
mu_tf <- mu_ab[,2,1]
mu_tt <- mu_ab[,2,2]

mu_subpop <- rstan:::extract(fit,"mu_subpop")$mu_subpop


mu_ab <- colMeans(rstan:::extract(fit,"mu_ab")$mu_ab)
mu_person <- colMeans(rstan:::extract(fit,"mu_person")$mu_person)

cor.matrix <- data.frame(pa = d2$pa,
                         counts = num_utterances_ab,
                         unsmoothed = d2$unsmoothed,
                         theta_diff = theta_diffs,
                         mu_ab = mu_ab,
                         vspeak = d2$vspeak,
                         vreply = d2$vreply) %>%
  group_by(vspeak,vreply) %>%
  multi_boot_standard(., "theta_diff", 
                      statistics_functions = c("ci_32", "ci_68"))

ggplot(aes(x = inf, y = unsmoothed, color = log(counts)), data = cor.matrix) +
  geom_point(size=2) + 
  theme_bw(base_size = 14) +
  theme(panel.grid = element_blank())
