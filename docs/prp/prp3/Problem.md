# ⚠️ Problem Overview

The current system design has several issues that may affect production
scalability and the addition of new Products in the future:

------------------------------------------------------------------------

## 1. Storing Production Data as Columns

Currently, production-process data such as:

-   `Thermised`
-   `Blending`
-   `After Past`
-   `Standardized`

is stored in a **Column-based** format, where data for each Batch is
predefined in the table structure.

This design may become limiting as production capacity increases. For
example, if future production reaches **10 Batches or more**, new
Columns may be required, making the Database structure larger and harder
to maintain.

### Improvement Approach

Consider changing the storage model from **Column-Based** to
**Row-Based**.

Concept example

``` text
Current

Thermised_1
Thermised_2
Thermised_3
...
Thermised_10

Blending_1
Blending_2
Blending_3
...
Blending_10
```

to

``` text
Proccess      Batch
Thermised     1
Thermised     2
Thermised     3
...
Thermised     10

Blending      1
Blending      2
Blending      3
...
Blending      10
```

Row-based storage reduces the need to predefine the number of Batches
and provides more flexibility as Batch counts increase.

------------------------------------------------------------------------

## 2. Adding New Products

Each Product may have different data and production stages, so the
required data can vary by Product.

For example:

``` text
Product A
├── Thermised
├── Blending
├── After Past
└── Standardized

Product B
├── Thermised
├── Blending
└── Standardized
```

If separate Input pages are designed for each Product, adding a new
Product may require creating or modifying additional Input pages based
on that Product's data requirements.

### Improvement Approach

Consider designing the structure around the **largest data set**.

For Products that do not use certain data fields or stages, those values
can be set to `0` so the same structure and Input pages can be shared.

Example

``` text
Product A
Thermised      = 100
Blending       = 200
After Past     = 150
Standardized   = 180

Product B
Thermised      = 100
Blending       = 200
After Past     = 0
Standardized   = 180
```

This approach reduces the need to create new Input pages for every
Product.

------------------------------------------------------------------------

# 🥛 3. Table Finish-good

Another limitation is **Finish-good** storage, especially when the
maximum number of Batches requiring inspection cannot be determined in
advance.

During production, a Product may need to be checked again. For example,
a quality issue may require collecting another milk sample for
additional inspection.

Therefore, the exact number of Batches that must be checked in a process
cannot be predetermined.

If the table is designed using Columns, for example:

``` text
Batch_1
Batch_2
Batch_3
...
Batch_10
```

The system is limited by the predefined number of Columns. If future
Batch counts exceed the design, both the Database structure and Input
pages must be modified.

### Improvement Approach

Consider changing **Finish-good from Column-Based to Row-Based**
storage.

Example

``` text
Current

Product_ID | Batch_1 | Batch_2 | Batch_3 | ... | Batch_10
```

Change to:

``` text
Product_ID | Batch
-----------|------
Product A  | 1
Product A  | 2
Product A  | 3
Product A  | 4
...
```

With Row-Based storage, the maximum number of Batches does not need to
be predefined in the Table structure.

If additional Product checks are required, a new Row can be added
immediately without adding Columns or changing the Database structure.

------------------------------------------------------------------------

# 🎯 Summary of Problems and Approaches

  ------------------------------------------------------------------------
  Problem                     Limitation         Approach
  --------------------------- ------------------ -------------------------
  Thermised / Blending /      More Columns are   Consider Row-Based
  After Past / Standardized   required as Batch  storage
  data is stored as Columns   count increases    

  Products have different     Separate Input     Design around the largest
  data requirements           pages may be       data set and use `0` for
                              required           unused fields

  Finish-good has a limited   Cannot flexibly    Change to Row-Based
  predefined Batch count      support additional 
                              Batches            

  Additional milk checks may  The amount of data Add new Rows instead of
  be required                 is unpredictable   Columns
  ------------------------------------------------------------------------

### Core Concept

``` text
                    Current System
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
    Limited Batch     Different Products   Finish-good
          │              │              │
          ▼              ▼              ▼
    Add Columns       Add Input Pages      Add Columns
          │              │              │
          └──────────────┼──────────────┘
                         ▼
                 Future Improvement
                         │
                         ▼
                  Row-Based Design
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
     Add Batches      Support Products     Add Data
     Flexibly          More easily          Without Column limits
```

> **Note:** Row-Based design should be considered for future
> scalability, especially when Batch counts and inspection data cannot
> be predetermined.
