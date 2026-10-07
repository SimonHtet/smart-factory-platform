# 🏭 Overall Project Overview

## PRP Dairy Mixing and Quality Control

### 📌 Project Overview

**PRP (Dairy Mixing and Quality Control)** is a system for storing and
managing data related to production processes within **PRP 3**.

**PRP 3 is Production Building 3** which supports production of several
product types includes

-   🥛 Fresh Milk
-   🌱 Soy Milk
-   🍵 Tea
-   ☕ Coffee
-   🥛 Fermented Milk
-   🍊 Juice

The system was developed to move production-data storage from
**paper-based records (Paper-based)** to a **digital system** so data
can be searched, verified, and reused more conveniently and quickly

------------------------------------------------------------------------

# 🎯 Why Was PRP Developed?

Previously, production data was mainly recorded on paper documents and
forms, causing issues such as

-   📄 High paper consumption
-   🔎 Difficulty retrieving historical data
-   ⏱️ Time-consuming data verification
-   📚 Data scattered across multiple documents
-   🔄 Difficulty reusing data downstream
-   📊 Difficulty consolidating data for analysis or reference

Therefore, the **PRP Application** was developed to store data
digitally, reduce paper use, and make data easier to search, verify, and
reuse

------------------------------------------------------------------------

# 👥 System Users

The main system users are

  ---------------------------------------------------------------------------
  User           Responsibility
  -------------- ------------------------------------------------------------
  **SUP**        Creates Product_ID and enters production data within their
                 responsibility

  **Operator**   Enters production data and actual process data
  ---------------------------------------------------------------------------

------------------------------------------------------------------------

# 🔄 Overall Production Workflow

The main PRP Application workflow runs from Product_ID creation through
finished-product data entry

``` mermaid
flowchart LR

    A["SUP Creates Product_ID"]
    --> B["Thermised"]

    B --> C["Blending"]

    C --> D["After Past"]

    D --> E["Standardized"]

    E --> F["Finish-good"]
```

### Production Process

1.  **SUP Creates Product_ID** SUP Creates `Product_ID` as the reference
    number for the Product and Batch

2.  **Thermised** Records data from the Thermised process

3.  **Blending** Records data from the Blending process

4.  **After Past** Records data after the relevant process

5.  **Standardized** Records data at the Standardized stage

6.  **Finish-good** Final stage for recording finished-product data

------------------------------------------------------------------------

# 🆔 Product_ID

`Product_ID` is key data used as **a Product identifier and a link
between production stages**

All tables related to the production process store `Product_ID`

Therefore, when a user searches by `Product_ID` the system can retrieve
and display production data related to that Product

``` text
                         Product_ID
                    ┌────────┼────────┬────────┐
                    │        │        │        │
                    ▼        ▼        ▼        ▼
                Thermised Blending After Past Standardized
                    │        │        │        │
                    └────────┴────────┴────────┘
                             │
                             ▼
                         Finish-good
```

> **Product_ID serves as the main reference for production data**
> allowing the same Product to be traced across each production stage

------------------------------------------------------------------------

# ✍️ Manual vs Automatic Data

The system divides data entry into two types: **manually entered data**
and **data generated or calculated automatically by the system**

## 👤 Manual Input

Most production-process data is entered by users

### SUP

SUP is responsible for creating `Product_ID`

After creating `Product_ID` the system saves the data to the relevant
tables

SUP also provides some data, such as

-   BOM
-   Buffer Volume (`buffer_vol`)

The system assists with part of the `buffer_vol` calculation

### Operator

Operator enters actual data generated during production, such as

-   Thermised
-   Blending
-   After Past
-   Standardized
-   Other relevant production data

------------------------------------------------------------------------

# ⚙️ Automatic Data Generation

On the **Finish-good** page, when SUP creates `Product_ID`, the system
loops to generate the related data automatically.

``` text
SUP Creates Product_ID
          │
          ▼
    Save Product_ID
          │
          ▼
   Automatic Loop
          │
          ▼
     Finish-good
```

However, if automatic generation fails or creates incorrect data
**Operator can manually create new data**

------------------------------------------------------------------------

# 🗃️ Database Relationship

The main tables related to PRP data are

-   `Prp 3 table`
-   `Yield`
-   `Yield2`
-   `PRP_Spec`
-   `Finish-good`

------------------------------------------------------------------------

## 📊 Prp 3 table

`Prp 3 table` stores core Product and Batch data such as

  Field          Description
  -------------- --------------------------
  `Product_ID`   Product reference number
  `Week`         Production Week
  `Loop`         Production Loop
  `Group`        Product Group
  `Flavor`       Flavor
  `Batch`        Batch

Data from `Prp 3 table` is used as reference data in other tables

------------------------------------------------------------------------

## 📈 Yield

`Yield` uses `Product_ID` from `Prp 3 table` to link Yield data to the
Product being produced.

``` text
Prp 3 table
     │
     │ Product_ID
     ▼
   Yield
```

------------------------------------------------------------------------

## 📈 Yield2

`Yield2` uses `Product_ID` from `Prp 3 table` in the same way to link
related Yield data.

``` text
Prp 3 table
     │
     │ Product_ID
     ▼
   Yield2
```

------------------------------------------------------------------------

## 📦 Finish-good

`Finish-good` uses `Product_ID` from `Prp 3 table` to link
finished-product data with the produced Product.

``` text
Prp 3 table
     │
     │ Product_ID
     ▼
 Finish-good
```

------------------------------------------------------------------------

## 🧪 PRP_Spec

`PRP_Spec` serves as the Specification source for Product validation,
with relevant data such as

-   Source
-   Flavor
-   Size

Data from `PRP_Spec` can be used as reference criteria for Product
validation

``` text
PRP_Spec
   │
   ├── Source
   ├── Flavor
   └── Size
        │
        ▼
   Specification
        │
        ▼
 Product / Quality Check
```

------------------------------------------------------------------------

# 🔗 Overall Data Relationship

The overall table relationships are shown below

``` mermaid
flowchart TD

    P["Prp 3 table"]

    P -->|"Product_ID"| Y["Yield"]
    P -->|"Product_ID"| Y2["Yield2"]
    P -->|"Product_ID"| FG["Finish-good"]

    S["PRP_Spec"]
    S -->|"Source / Flavor / Size"| Q["Product / Quality Check"]

    P --> Q
```

> `Product_ID` is key data used to link Product data across tables

------------------------------------------------------------------------

# 🔍 How the System Works

The overall system workflow can be summarized as follows

``` text
┌───────────────────────────┐
│ 1. SUP Creates Product_ID │
└─────────────┬─────────────┘
              │
              ▼
┌───────────────────────────┐
│ 2. Production Data Entry  │
│    • Thermised             │
│    • Blending              │
│    • After Past            │
│    • Standardized          │
└─────────────┬─────────────┘
              │
              ▼
┌───────────────────────────┐
│ 3. Quality / Specification│
│    Check                   │
│    • PRP_Spec              │
└─────────────┬─────────────┘
              │
              ▼
┌───────────────────────────┐
│ 4. Yield                   │
│    • Yield                 │
│    • Yield2                │
└─────────────┬─────────────┘
              │
              ▼
┌───────────────────────────┐
│ 5. Finish-good             │
└───────────────────────────┘
```

------------------------------------------------------------------------

# 🎯 Project Goals

PRP Application has the following primary goals

-   📄 Reduce paper documents and paper usage
-   🔎 Make production data easier to find
-   ⚡ Reduce data-verification time
-   🗃️ Store data systematically
-   🔗 Link data using `Product_ID`
-   📊 Make downstream data use more convenient
-   🏭 Support the transition of production processes to Digital and
    Smart Factory systems

------------------------------------------------------------------------

# 📖 Documentation Structure

After this **Overall Project Overview** section, the documentation
continues with technical details for each part of the PRP Application

``` text
Overall Project Overview
        │
        ├── PRP1
        ├── PRP2
        ├── PRP3
        │
        ├── Pages
        ├── Tables
        ├── Queries
        ├── Automations
        └── Workflows
```

The **Overall Project Overview** section therefore provides an overview
for readers who have never used the PRP Application, explaining its
purpose, users, production process, data relationships, and role within
the Smart Factory Platform before the page-level technical details
