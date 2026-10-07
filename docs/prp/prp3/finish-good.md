# Finish-good table and the SaveBatch automation

[← PRP3 overview](README.md)

`Finish-good` stores the check done **after the milk has been mixed, sterilized and packed into
cartons**: operators take a sample from each Batch and record the values.
It is **shared by all plants** — PRP1 writes to it too.

| | |
|---|---|
| **Data entry page** | `/finish-good1/:user` |
| **Layout** | 1 Batch = 1 row |
| **Rows created by** | Automation **SaveBatch**, when the SUP creates the `product_ID` |
| **Users** | SUP creates the `product_ID`; operators enter the check values |

## Why rows instead of columns

When milk starts feeding the machine, the operator samples it for testing. How many Batches one
check covers isn't fixed:

- **Continuous feed** — several consecutive Batches can be checked in one test cycle.
- **Emergency machine stop** — the Batch must restart its milk feed and be checked again.

A fixed set of `Batch1…BatchN` columns can't handle that, so Finish-good moved from columns
(the old design) to **one row per Batch**.

## SaveBatch

Runs when the SUP creates a `product_ID`. It reads `Batch1`–`Batch11` from the trigger,
**skips empty Batches**, and creates one Finish-good row per Batch with:

| Field | Meaning |
|---|---|
| `Group` | Machine group (MC) |
| `Flavor` | Flavor of that Batch |
| `Batch` | Batch number |
| `Product_ID` | Built from the production date, week, day, loop and group — format in [prp3-table.md](prp3-table.md#product_id) |

### Script

```javascript
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

> ℹ️ The script reads up to **11** Batches, while `Prp 3 table` holds 8 (`Batch1`–`Batch8`).

## Emergency: machine stop and milk-feed restart

If the milk feed has to restart, the **operator creates a new `product_ID` by hand**, changing the
number (`no`) from `1` to `2`, then enters the data on `/finish-good1/:user`.
