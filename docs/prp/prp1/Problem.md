# Overview of Problems and Improvement Approaches

## 1. Adding Products in the Future

because **Fresh Milk** uses the same production process as **PRP3**
Therefore, potential issues when adding new Products in the future will
be similar to PRP3

Each Product type may have different production processes and required
data, so the system must be designed to support adding new Products in
the future

------------------------------------------------------------------------

## 2. Soy Milk Storage and Blending Process

For **Soy Milk**, the `Storage` and `Blending` processes require that
**Batch numbers should not be split**.

However, the current system splits Batch numbers from the first step,
causing users to enter data **twice**

### Improvement Approach

In the future, `Storage` and `Blending` should be separated and the
data-entry pages redesigned to match the actual production process

**Expected Benefits**

-   Reduce duplicate data entry
-   Reduce confusion when managing Batch numbers
-   Align the data-entry structure with the actual production process
-   Reduce the chance of data-entry errors

------------------------------------------------------------------------

## 3. Finish-good Data Display

Users need an overall view of **Finish-good overall** so data can be
checked and tracked more easily

### Current-System Improvement

The current system has added **a Finish-good data table** so users can
view the overall data from a single page

``` text
Finish-good
     │
     ▼
┌─────────────────────────────────────┐
│          Finish-good Table           │
├──────────┬─────────┬───────┬────────┤
│ Product  │ Batch   │ Group │ Status │
├──────────┼─────────┼───────┼────────┤
│ ...      │ ...     │ ...   │ ...    │
└──────────┴─────────┴───────┴────────┘
```

------------------------------------------------------------------------

## 4. Operator Employee-ID Validation

To prevent data that does not match the required format, the system now
validates **Operator**

### Data Entry Conditions

  Item                                  Condition
  ------------------------------------- -----------------------------
  Employee ID                           6 characters allowed
  Emoji                                 Not allowed
  Data that does not match the format   The system blocks the input

### Operation

``` text
Operator
   │
   ▼
Enter Employee ID
   │
   ▼
Validate data
   │
   ├── Valid ──────► Continue
   │
   └── Invalid ───► System blocks the input
```

The system therefore ensures that Employee IDs use the correct format
and prevents entry of **Emoji or data that does not meet the
conditions** into the system
