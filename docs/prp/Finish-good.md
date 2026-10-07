# Table Finish-good and Automation SaveBatch

## 📋 Overview

The **Finish-good** table stores data after the milk has been mixed,
sterilized, and packed into cartons. Operators collect milk samples and
check values according to the produced **batch**.

  -----------------------------------------------------------------------
  Item                                Description
  ----------------------------------- -----------------------------------
  **Data Entry Page**                 `/finish-good1/:user`

  **Data Storage**                    1 batch = 1 Row

  **Automation**                      `SaveBatch` (runs when SUP creates
                                      `product_ID`)

  **Users**                           SUP creates `product_ID`; Operator
                                      checks values on
                                      `/finish-good1/:user`
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## 📌 Why Store Data as Rows Instead of Columns?

When milk starts feeding into the machine, the Operator collects a milk
sample for testing.

-   **Continuous feed:** Consecutive Batches can be checked in the same
    test cycle.
-   **Emergency machine stop:** That Batch must restart milk feeding and
    be checked again.

Because of these events, **the number of Batches per check is not
fixed**, so a fixed number of Batch columns cannot be defined.

Therefore, the system stores data as **1 batch = 1 Row** instead.\
\> Previously, the data was stored in columns.

------------------------------------------------------------------------

## ⚙️ Automation: `SaveBatch`

Runs when SUP creates `product_ID`, looping to create a Row in
**Finish-good** for every entered Batch.\
(Checks `Batch1`--`Batch11` and filters out empty entries.)

  -----------------------------------------------------------------------
  Output Field                        Meaning
  ----------------------------------- -----------------------------------
  `Group`                             Group / machine (MC)

  `Flavor`                            Flavor of that Batch

  `Batch`                             Batch number

  `Product_ID`                        Product identifier created from
                                      Production Date and Production Loop
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## 🆔 `Product_ID` Format

``` text
{2-digit year}{month}{day}-{Week}{day abbreviation}{Loop}-{Group}
```

### Example

``` text
260106-41Tu1-A
```

> January 6, 2026, Week 41, Tuesday, Loop 1, Group A

### Day Abbreviations

  Day          Abbreviation
  ----------- --------------
  Sunday           `Su`
  Monday           `Mo`
  Tuesday          `Tu`
  Wednesday        `We`
  Thursday         `Th`
  Friday           `Fr`
  Saturday         `Sa`

------------------------------------------------------------------------

## 💻 Script

``` javascript
let dateTimeString = $("trigger.fields.Product Date");
let dateTime = new Date(dateTimeString);
let date = String(dateTime.getDate()).padStart(2, '0');
let month = String(dateTime.getMonth() + 1).padStart(2, '0');
let year = (dateTime.getFullYear() % 100).toString().padStart(2, '0');
let dayNames = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];
let day = dayNames[dateTime.getDay()];
let week = $("trigger.fields.Week");
let loop = $("trigger.fields.Loop");
let MC = $("trigger.fields.Group");
let productId = `${year}${month}${date}-${week}${day}${loop}-${MC}`;

return [
  { Group: MC, Flavor: $("trigger.fields.Flavor1"), Batch: $("trigger.fields.Batch1"), Product_ID: productId },
  { Group: MC, Flavor: $("trigger.fields.Flavor2"), Batch: $("trigger.fields.Batch2"), Product_ID: productId },
  { Group: MC, Flavor: $("trigger.fields.Flavor3"), Batch: $("trigger.fields.Batch3"), Product_ID: productId },
  { Group: MC, Flavor: $("trigger.fields.Flavor4"), Batch: $("trigger.fields.Batch4"), Product_ID: productId },
  { Group: MC, Flavor: $("trigger.fields.Flavor5"), Batch: $("trigger.fields.Batch5"), Product_ID: productId },
  { Group: MC, Flavor: $("trigger.fields.Flavor6"), Batch: $("trigger.fields.Batch6"), Product_ID: productId },
  { Group: MC, Flavor: $("trigger.fields.Flavor7"), Batch: $("trigger.fields.Batch7"), Product_ID: productId },
  { Group: MC, Flavor: $("trigger.fields.Flavor8"), Batch: $("trigger.fields.Batch8"), Product_ID: productId },
  { Group: MC, Flavor: $("trigger.fields.Flavor9"), Batch: $("trigger.fields.Batch9"), Product_ID: productId },
  { Group: MC, Flavor: $("trigger.fields.Flavor10"), Batch: $("trigger.fields.Batch10"), Product_ID: productId },
  { Group: MC, Flavor: $("trigger.fields.Flavor11"), Batch: $("trigger.fields.Batch11"), Product_ID: productId }
].filter(item => item.Batch && item.Batch.toString().trim() !== "");
```

------------------------------------------------------------------------

## 🚨 Emergency Case: Machine Stop and Restart Milk Feed

When milk feeding must restart, the **Operator must manually create a
new `product_ID`** by changing **no** from `1` to `2`.

Then enter the data on:

``` text
/finish-good1/:user
```
