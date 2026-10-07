# 🥛 PRP1 Fresh MilkandFermented Milk

The **PRP1 Fresh Milk** system uses the same production process as PRP3,
so it shares the `prp3 table`. `Product_ID` is the primary reference
used to link data across all tables.

------------------------------------------------------------------------

## 🗄️ 1. System Database

  --------------------------------------------------------------------------
  Table           Storage Format                   Description
  --------------- -------------------------------- -------------------------
  `prp3 table`    Column (up to 8 Batches)         Stores `Product_ID`,
                                                   Flavor, and Batch. Fresh
                                                   Milk uses the same
                                                   process as PRP3, so it
                                                   uses the same table.

  `Yield`         Column (up to 8 Batches)         Stores production data
                                                   across 4 subpages:
                                                   Thermised, Recombine,
                                                   After Past, and
                                                   Standardized.

  `Finish-good`   Row (Row)                        Stores datamilk after
                                                   sterilization creates
                                                   Rows based on the number
                                                   of produced Batches using
                                                   Automation `SaveBatch`

  `PRP_Spec`      \-                               Specification table used
                                                   to validate Source,
                                                   Flavor, Size
  --------------------------------------------------------------------------

------------------------------------------------------------------------

## 🔑 2. Product_ID Creation

**Sup** creates the `Product_ID` using the following data

``` text
Product + Date + Week + Loop + Group
                  │
                  ▼
             Product_ID
                  │
        Save to 3 tables simultaneously
      ┌───────────┼───────────┐
      ▼           ▼           ▼
 prp3 table      Yield    Finish-good
```

> `Product_ID` is not passed from `prp3 table` to other tables instead,
> it is saved to all 3 tables simultaneously when created

------------------------------------------------------------------------

## 🔄 3. Production Workflow

``` text
                  Sup creates Product_ID
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
     prp3 table         Yield        Finish-good
   (Product_ID,           │          (stored as Rows)
    Flavor, Batch)        │                ▲
                          │                │
     ┌──────────┬─────────┼─────────┐      │
     ▼          ▼         ▼         ▼      │
 Thermised  Recombine After Past Standardized
                                           │
                       Automation SaveBatch loops to create Rows
                       based on the number of produced Batches
```

------------------------------------------------------------------------

## 📄 4. Yield Data Entry Pages

`Yield` consists of 4 subpages Each page uses its own Table for data
storage and references data using `Product_ID`

  -----------------------------------------------------------------------
  Page             Table                Note
  ---------------- -------------------- ---------------------------------
  Thermised        `prp1thermised`      includes pH checking andincludes
                                        a Model for checking water pH
                                        **does not include** Sediment and
                                        Water Add (different from PRP3)

  Recombine        `blendingprp1`       \-

  After Past       `buffer1_prp1`       adds a check for **SNF**
                                        (different from PRP3)

  Standardized     `buffer2_prp1`       Super verifies correctness andthe
                                        system calculates `BOM_Volume`,
                                        `Buffer_Volume` automatically
  -----------------------------------------------------------------------

Each page can display up to **8 Batch** on a single page

> **Note:** The Table names above identify where each page stores its
> data; they do not represent a sequence of data transfer between Tables

### 🧪 4.1 Thermised

-   Check **pH**
-   Includes a Model for checking **water pH**
-   Does not check **Sediment** and **Water Add**

### 🥛 4.2 Recombine

-   Allows entry and verification of up to 8 Batches simultaneously on
    one page

### 🧪 4.3 After Past

-   Adds a check for **SNF**

### ⚙️ 4.4 Standardized

``` text
Standardized
     │
     ▼
Super verifies correctness
     │
     ├──────────────┐
     ▼              ▼
BOM_Volume     Buffer_Volume
(calculated automatically)
```

The system calculates values automatically to reduce manual calculations
and data-entry errors

------------------------------------------------------------------------

## 📦 5. Finish-good

-   Receives `Product_ID` when Sup creates it (not from the 4 Yield
    pages)
-   Stores data as **Row**
-   Automation **`SaveBatch`** loops to create Rows based on the number
    of produced Batches

``` text
Product_ID + number of Batches
          │
          ▼
  Automation: SaveBatch
          │  (loop)
          ▼
 Row 1, 2, 3 ... N
```

------------------------------------------------------------------------

## 📋 6. Specification --- PRP_Spec

The system validates data against criteria from the `PRP_Spec` using all
3 values for validation

``` text
PRP_Spec
   │
   ├── Source
   ├── Flavor
   └── Size
```

  Specification   Description
  --------------- ----------------
  `Source`        Product source
  `Flavor`        Flavor
  `Size`          Size

------------------------------------------------------------------------

## ⭐ Key Points

  -----------------------------------------------------------------------
  Item                       Description
  -------------------------- --------------------------------------------
  **Product**                PRP1 Fresh Milk

  **Tables Used**            `prp3 table`, `Yield`, `Finish-good` (+
                             `PRP_Spec` as the specification table)

  **Product_ID Creation**    Sup creates it from Product + Date + Week +
                             Loop + Group

  **Product_ID Storage**     Save to 3 tables simultaneously:
                             `prp3 table`, `Yield`, `Finish-good`

  **prp3 table**             Stores Product_ID, Flavor, and Batch in
                             columns, up to 8 Batches

  **Yield**                  Column-based storage for up to 8 Batches
                             across 4 subpages

  **Finish-good**            Stored as Rows created by Automation
                             `SaveBatch`

  **Thermised**              `prp1thermised` --- checks pH, includes a
                             water pH Model, does not include Sediment
                             and Water Add

  **Recombine**              `blendingprp1`

  **After Past**             `buffer1_prp1` --- adds SNF

  **Standardized**           `buffer2_prp1` --- Super verifies the data;
                             `BOM_Volume` and `Buffer_Volume` are
                             calculated

  **Specification**          `PRP_Spec` uses Source, Flavor, and Size for
                             validation
  -----------------------------------------------------------------------
