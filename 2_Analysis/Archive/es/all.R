# Setup ------------------------------------------------------------------------
library(stargazer)
library(gtsummary)
library(tibble)
library(dplyr)
library(ggplot2)
library(stringr)
library(purrr)
library(sf)
library(ipumsr)
library(tidyr)

# Set IPUMS API Key (Ensure your API key is correctly inputted here)
set_ipums_api_key("59cba10d8a5da536fc06b59d5cae6eb507764cabbc0de684e3dc0014", save = TRUE, overwrite = TRUE)

# Define Extract for 1-Year ACS Data
ACS_extract_1yr <- define_extract_usa(
  "Capstone Data Pull IPUMS USA 1-year ACS",
  c("us2009a", "us2010a", "us2011a", "us2012a","us2013a","us2014a","us2015a","us2016a", "us2017a", "us2018a","us2019a", "us2020a"),
  c(
    "STATEFIP", "COUNTYFIP", "DENSITY", "PUMA", "HHWT", "PERWT",
    "MOMLOC", "MOMRULE", "SPLOC", "SPRULE", "NCHILD", "NCHLT5", "FAMUNIT", "YNGCH", "ELDCH", "RELATE",
    "HHINCOME", "POVERTY", "OWNERSHP", "FTOTINC", "MULTGEN",
    "AGE", "SEX", "RACE", "EDUC", "HISPAN", "MARST", "EMPSTAT", "MIGRATE1")
)

# Submit the extract
dat_file_path <- "A://R-local//3.31//usa_00018.dat"
xml_file_path <- "A://R-local//3.31//usa_00018.xml"

# Read the microdata using the read_ipums_micro function
ACS_extract_09_20_1yr <- read_ipums_micro(data_file = dat_file_path, ddi=xml_file_path)


# CITY FILTER ------------------------------------------------------------------

ACS_1_year_cities <- ACS_extract_09_20_1yr %>%
  mutate(city = case_when(
    STATEFIP == 36 & COUNTYFIP %in% c(5,61, 81, 85, 47) ~ "NYC",
    STATEFIP == 11 ~ "DC",
    STATEFIP == 24 & COUNTYFIP == 005 ~ "BAL", 
    STATEFIP == 48 & COUNTYFIP == 201 ~ "HOU",
    STATEFIP == 17 & PUMA %in% c(3501, 3502, 3503, 3504, 3505, 3506, 3507, 3508, 
                                 3509,3510, 3511, 3512, 3513, 3514, 3514, 3516, 
                                 3517, 3518, 3519) ~ "CHI",
    STATEFIP == 42 & COUNTYFIP == 101 ~ "PHI",
    STATEFIP == 06 & COUNTYFIP == 037 ~ "LA",
    STATEFIP == 06 & COUNTYFIP == 073 ~ "SD",
    STATEFIP == 04 & PUMA %in% c(0112, 0113, 0114, 0115, 0116, 0117, 0118, 0119, 
                                 0120,0121,0122, 0123, 0125, 0128, 0129) ~ "PHX"))



#SAMPLE FILTERS ------------------------

# sample filters:
## heads of households
## renters (look at 0s and negatives)
## households with at least one pre-k age child

# RELATE: 0101 = head of household, 0301 = child, 0303 = step child

filtered_sample_prek_all <- ACS_1_year_cities %>%
  filter(!is.na(city), # Filter only for our cities
         RELATE == 1, # Head of household
         OWNERSHP == 2, # Renters
         NCHLT5 > 0) # Number of own children under age 5 is > 1


# remove 2020 from dataframe

filtered_sample_prek_all <- filtered_sample_prek_all %>%
  filter(YEAR != 2020)

# Event Study HOU ---------------------------------------------------------------------

# remove scientific notation
options(scipen = 999, digits = 10)

# filter dataset to only NYC and control 
control <- subset(filtered_sample_prek_all, city %in% c("NYC", "CHI", "SD", "LA", "PHI", "HOU"))

# apply weights (HHWT)
control <- control[rep(seq_len(nrow(control)), control$HHWT), ]

# create a flag for 1 or 0 if it's NYC 
control$city_ind <- ifelse(control$city == "NYC", 1, 0)

# create a flag for post-period
control$post <- ifelse(control$YEAR >= 2014, 1, 0)

# make MIGRATE1 binary
control <- control %>%
  mutate(migrate_binary = ifelse(MIGRATE1 %in% c(2, 3, 4), 1, 0))

# create a flag for year
prepended_value <- "INX"
control$Year_INX <- paste0(prepended_value, control$YEAR)
control_wide <- pivot_wider(control, names_from = Year_INX, values_from = Year_INX, values_fn = list(Year_INX = length), values_fill = 0)

# estimate the regression
es <- lm(migrate_binary ~ ., data = select(control_wide
                                           , migrate_binary
                                           , HHINCOME, SEX, AGE, 
                                           POVERTY,
                                           NCHILD,
                                           RACE,
                                           MARST, 
                                           EMPSTAT,
                                           MULTGEN
                                           , starts_with("INX"))
)

summary(es)

# get standard errors
out = summary(es)
se = out$coefficients[ , 2] #extract 2nd column from the coefficients object in out

# filter to only the time variables, and scale standard errors
inx_se <- se[grep("^INX", names(se))]
inx_se <- inx_se * 1.96

# get coefficients
df1 <- data.frame(es$coefficients)
df1 <- rownames_to_column(df1, var = "Name")

# create dataframe
se_df <- data.frame(Name = names(inx_se), Value = inx_se)
merged_df <- merge(se_df, df1, by = "Name")

# clean up df
merged_df$Year <- as.integer(gsub("INX", "", merged_df$Name)) # replace INX with integer
merged_df$Name <- NULL #get rid of 'Name' now that we have Year
colnames(merged_df)[colnames(merged_df) == "es.coefficients"] <- "Coefficient"
colnames(merged_df)[colnames(merged_df) == "Value"] <- "Std_Error"

# plot the event study
ggplot(data = merged_df, mapping = aes(x = Year, y = Coefficient)) +
  geom_line(linetype = "dashed") +
  geom_point() + 
  geom_errorbar(aes(ymin = (Coefficient-Std_Error), ymax = (Coefficient+Std_Error)), width = 0.2) +
  labs(title = "Coefficient with Error Bars",
       x = "Year",
       y = "Coefficient") +
  scale_x_continuous(breaks = seq(min(merged_df$Year), max(merged_df$Year), by = 1)) +
  geom_vline(xintercept = 2014)

# Model ---------------------------------------------------------------------

# lm with controls
model <- lm(migrate_binary ~ 
              post + #flag for pre/post
              city_ind + #flag for treatment vs. control
              post:city_ind +
              HHINCOME + # control variable
              AGE + # control
              SEX +
              POVERTY +
              NCHILD +
              RACE + 
              MARST + #Marital status
              EMPSTAT +
              MULTGEN,
            data = control)

summary(model)


# create the table
t1 <- tbl_regression(model, label=list(EMPSTAT ~ "Employment Status", MULTGEN ~ "Multigenerational household", post ~ "Post-Period Indicator", city_ind ~ "Treatment Indicator", RACE ~ "Race"))
caption = "Regression Model Summary Output"
modify_caption(t1, caption, text_interpret = c("md", "html"))
print(t1)

######scratch---------

# create a flag for post-period if it's supposed to be 0 for all control (need to check)
#control <- control %>%
#  mutate(year_flag = case_when(
#    city == 'NYC' ~ control$YEAR, .default = 0))

# create a new year if the INX indicator is supposed to be 0 for control (???) 
#control$Year_flag <- ifelse(city_ind == 1), control$Year,0))
#control_wide <- subset(control_wide, select = -INX0)