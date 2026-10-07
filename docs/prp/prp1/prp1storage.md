# 🥛 PRP1 Soy Milk

The PRP1 Soy Milk system records production data from Storage through
Standardized. Data is stored using a **row-based** structure, with each
Batch in a separate Row, allowing the system to support an increasing
number of Batches.

------------------------------------------------------------------------

## 🗄️ 1. System Database

  --------------------------------------------------------------------------
  Table           Storage Format                   Description
  --------------- -------------------------------- -------------------------
  `prp1_table`    Row                              Stores `Product_ID`,
                                                   Flavor, Batch, and
                                                   production data (Yield)
                                                   from all 4 data-entry
                                                   pages

  `Finish-good`   Row                              Stores datamilk after
                                                   sterilization

  `PRP_Spec`      \-                               Specification table used
                                                   to validate Source,
                                                   Flavor, Size
  --------------------------------------------------------------------------

------------------------------------------------------------------------

## 🔑 2. Product_ID Creation

**Sup** creates the initial data using Automation
**`Generate Product Batches`**, which uses `Product_Date`, `Loop`, and
`Week` to create `Product_ID` and save it to `prp1_table`.

Example data in `prp1_table`

  Product_Date     Loop   Week Batch    Flavor
  -------------- ------ ------ -------- --------
  7/30/2026           1     31 1773-1   D
  7/30/2026           1     31 1773-2   D

``` text
Product_Date = 7/30/2026
Week         = 31
Loop         = 1
        │
        ▼
Automation: Generate Product Batches
        │
        ▼
Product_ID (initial) = 300726-31Th1
```

> **Group:** The final `Product_ID` must include **Group**, which is
> assigned on the Standardized page because the Group may change later
> in the process (see Section 6).

------------------------------------------------------------------------

## 🔎 3. selection of Batch

When entering PRP1, the system displays the available Batches. The user
must select a Batch before opening its data-entry page.

``` text
PRP1
  │
  ▼
Display Batch list
  │
  ▼
User selects a Batch
  │
  ▼
Data-entry page
```

------------------------------------------------------------------------

## ⚙️ 4. Data-Entry Pages and Conditions

`prp1_table` has 4 data-entry pages. **Condition and Step** control the
sequence in which pages are displayed.

``` text
Storage
   │
   ▼
Before Cooling
   │
   ▼
After Cooling
   │
   ▼
Standardized
```

The system checks each Step condition before allowing data entry in the
next stage.

------------------------------------------------------------------------

## 📋 5. Specification Validation --- PRP_Spec

Every page validates data against `PRP_Spec` using all 3 required
values.

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

## 🧪 6. Standardized

On the `Standardized` page, the user must **select Group and press Save
first** before the remaining fields are displayed.

-   Group is used to create the final `Product_ID`.
-   Group is entered on this page because it may change later in the
    production process.
-   When Save is pressed, the system adds `Product_ID` to `Finish-good`
    based on the data entered on the Standardized page.

``` text
Standardized
     │
     ▼
Select Group
     │
     ▼
   Save
     │
     ├─────────────────────────┐
     ▼                         ▼
Display fields for entry      Product_ID (with Group)
                               │
                               ▼
                          Finish-good
```

### 🧮 BOM and `buffer_vol`

On the Standardized page, the system automatically calculates
`buffer_vol` from **BOM** data; the user does not need to calculate it
manually.

``` text
BOM
 │
 ▼
Calculate
 │
 ▼
buffer_vol
```

------------------------------------------------------------------------

## 🔄 7. Overall Workflow

``` text
Sup
 │
 ▼
Automation: Generate Product Batches
(Product_Date + Loop + Week)
 │
 ▼
prp1_table  ← Product_ID, Flavor, Batch data
 │
 ▼
Select Batch
 │
 ▼
Storage
 │
 ▼
Before Cooling
 │
 ▼
After Cooling
 │
 ▼
Standardized
 │
 ├── Select Group → Save → Display fields for entry
 ├── BOM → buffer_vol
 │
 ▼
Product_ID (with Group) → Finish-good

* Every page validates values using PRP_Spec (Source, Flavor, Size).
```

------------------------------------------------------------------------

## ⭐ Key Points

  -----------------------------------------------------------------------
  Item                       Description
  -------------------------- --------------------------------------------
  **Product**                PRP1 Soy Milk

  **Tables Used**            `prp1_table`, `Finish-good` (+ `PRP_Spec` as
                             the specification table)

  **Data Structure**         Row-based (each Batch is stored as a
                             separate Row)

  **Initial Data Creation**  Sup uses Automation
                             `Generate Product Batches` with
                             Product_Date, Loop, and Week

  **Data-Entry Pages**       Storage → Before Cooling → After Cooling →
                             Standardized

  **Batch Selection**        A Batch must be selected before entering
                             data

  **Condition**              Controls the display of Steps and data-entry
                             pages

  **Standardized**           Group must be selected and saved first

  **Group**                  Entered on the Standardized page to create
                             the final Product_ID (Group may change
                             later)

  **Finish-good**            Saving on Standardized adds Product_ID to
                             Finish-good

  **BOM / `buffer_vol`**     On the Standardized page, the system
                             calculates `buffer_vol` from BOM

  **Specification**          `PRP_Spec` uses Source, Flavor, and Size for
                             validation
  -----------------------------------------------------------------------
