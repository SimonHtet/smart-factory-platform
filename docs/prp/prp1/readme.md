# 🏭 Project Overview --- PRP1 Dairy Mixing and Quality Control

## 📌 Project Overview

**PRP1** is Production Building 1, which supports 3 products:

-   🥛 **Fresh Milk**
-   🌱 **Soy Milk**
-   🥛 **Fermented Milk**

The production process is divided into 2 main areas.

  Production Area   Product
  ----------------- ----------------------------
  **Blending**      Soy Milk
  **Recombine**     Fresh Milk, Fermented Milk

The **PRP1 Dairy Mixing and Quality Control** system was developed to
convert production records from **Paper-based Data** to **Digital
Data**, storing the information in a Database so it can be searched,
verified, and reused more conveniently.

------------------------------------------------------------------------

## 🎯 Objectives

The system was developed to:

-   📄 Reduce paper usage
-   🔎 Make data easier to search
-   📊 Make historical data easier to verify
-   💾 Store data in a Database
-   ⚡ Reduce data-entry and verification time
-   🔄 Support downstream use of the data

------------------------------------------------------------------------

## 👥 System Users

  -------------------------------------------------------------------------
  User           Responsibility
  -------------- ----------------------------------------------------------
  **SUP**        Creates `Product_ID` and defines related production data

  **Operator**   Records production data at each stage
  -------------------------------------------------------------------------

------------------------------------------------------------------------

## 🔄 Production Workflow

### 🥛 Fresh Milk --- Recombine

``` text
SUP
 │
 ▼
Create Product_ID
 │
 ▼
Thermised
 │
 ▼
Recombine
 │
 ▼
After Past
 │
 ▼
Standardized
 │
 ▼
Finish-good
```

### 🌱 Soy Milk --- Blending

``` text
SUP
 │
 ▼
Product Date
 │
 ▼
Generate Product Batches
 │
 ▼
Storage
 │
 ▼
Blending
 │
 ▼
After Past
 │
 ▼
Standardized
 │
 ▼
Create Product_ID
 │
 ▼
Finish-good
```

------------------------------------------------------------------------

## 🗃️ Main Database

  ----------------------------------------------------------------------------
  Table             Purpose
  ----------------- ----------------------------------------------------------
  **Prp 3 table**   Stores `Product_ID`, `Flavor`, and `Batch` for the Fresh
                    Milk process

  **prp1_table**    Stores `Product_ID`, `Flavor`, `Batch`, and Soy Milk
                    production data

  **Yield**         Stores Fresh Milk production data at each stage

  **Finish-good**   Stores product data after sterilization
  ----------------------------------------------------------------------------

------------------------------------------------------------------------

## ⚙️ Automation

The system includes Automations that support the production process,
such as:

-   **Generate Product Batches** --- Creates Batch data for Soy Milk
-   **SaveBatch** --- Creates Batch data in `Finish-good` based on the
    number of produced Batches

------------------------------------------------------------------------

## 👤 User Input & ⚙️ System Automation

The system is divided into 2 main types of operation: **manually entered
data** and **data generated or calculated automatically by the system**.

### 👤 manually entered data

  ------------------------------------------------------------------------------
  User           Data Entered
  -------------- ---------------------------------------------------------------
  **SUP**        `Product_ID` and data related to Product creation

  **SUP**        `BOM` and `Buffer_Vol` data, which the system uses for related
                 calculations

  **Operator**   Production data at each stage, such as Storage, Blending,
                 Thermised, Recombine, After Past, and Standardized

  **Operator**   Production data and actual values generated during the
                 production process
  ------------------------------------------------------------------------------

### ⚙️ Data Generated Automatically by the System

  ----------------------------------------------------------------------------
  Process           System Automation
  ----------------- ----------------------------------------------------------
  **Soy Milk**      The system loops to create `Batch` numbers and stores them
                    as Rows so SUP does not need to add Batches one by one

  **Finish-good**   When SUP creates `Product_ID`, the system loops to
                    automatically create Batch data in `Finish-good`

  **BOM /           The system uses SUP-entered data to automatically
  Buffer_Vol**      calculate related values
  ----------------------------------------------------------------------------

> **Summary:** SUP defines and enters the main data used to create a
> Product. The Operator records actual production-process data, while
> the system helps generate Batches, create `Finish-good` data, and
> automatically calculate selected values to reduce duplicate entry and
> manual errors.
