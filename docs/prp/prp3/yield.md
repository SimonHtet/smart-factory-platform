# PRP3 — Yield: production stage pages

[← PRP3 overview](README.md)

The Yield pages record each production stage for every Batch:

**Thermised → Blending → After Past / After cooling → Standardized / Standardization**

- [Products and tables](#products-and-tables)
- [Stage pages](#stage-pages)
- [Spec check (`CheckSpecPrp`)](#spec-check-checkspecprp)
- [BOM and `buffer_vol` formulas](#bom-and-buffer_vol-formulas)
- [Permissions](#permissions)
- [URL parameters](#url-parameters)

## Flow

1. The **SUP** creates the `product_ID` on `/create-tag/:user` ([details](prp3-table.md#create-tag-page--create-taguser)).
2. The system creates a matching row in **`Yield`** — or in **`Yield2`** for Fermented Milk.
3. **Operators** enter data on `/inputdata`, `/blending`, `/buffer` and `/buffer2`.
4. On **Save**, the data is written to `Yield` / `Yield2`; Standardized also writes to **`Prp 3 table`**.

## Products and tables

Each product needs different fields, so every page shows the form for the product of the
current `product_ID` (conditional display).

| Product | Stored in |
|---|---|
| Demol Milk | `Yield` |
| Soy Milk | `Yield` |
| Tea | `Yield` |
| Fermented Milk | `Yield2` |

> `Yield` ran out of columns, so `Yield2` was added for Fermented Milk. Creating a Fermented Milk
> `product_ID` automatically creates its row in `Yield2`.

## Stage pages

| # | Stage | Route | Records |
|---|---|---|---|
| 1 | **Thermised** | `/inputdata/:a/:b/:user` | Quality check from PRP2 |
| 2 | **Blending** | `/blending/:a/:b/:user` | Check when receiving milk into the tank car |
| 3 | **After Past / After cooling** | `/buffer/:a/:b/:user` | After pasteurization / cooling |
| 4 | **Standardized / Standardization** | `/buffer2/:a/:b/:user` | Final standardization + SUP sign-off |

### Behaviour shared by all stage pages

- Shows **8 Batches** in order; the SUP can renumber, add or delete Batches.
- Data can be **edited at any time**, but the operator's **employee ID can be saved only once**.
- JavaScript checks that every required field is filled — **incomplete data cannot be saved**.
- A successfully saved Batch **turns green**.
- Values are validated against [`PRP_Spec`](#spec-check-checkspecprp).

### Page-specific details

**Thermised** — also has a pop-up for entering **water pH**.

**After Past / After cooling** — the heading depends on the product:

| Product | Heading |
|---|---|
| Fresh Milk | After Past |
| Tea | After cooling |
| Soy Milk | After cooling |

**Standardized / Standardization** — heading by product, plus extra features:

| Product | Heading |
|---|---|
| Fresh Milk | Standardized |
| Soy Milk | Standardized |
| Tea | Standardization |

- SUP verification / sign-off field
- Calculates **BOM volume** and **`buffer_vol`** ([formulas](#bom-and-buffer_vol-formulas))
- Save writes to both **`Yield`** and **`Prp 3 table`**

## Spec check (`CheckSpecPrp`)

Used by all four stage pages, and by PRP1. The spec row is looked up by **milk source,
flavor and batch size** — all three must be filled in before the check can run.

```sql
SELECT *
FROM PRP_Spec
WHERE Milk_Source = {{source}}
  AND Flavor      = {{flavor}}
  AND Batch_Size  = {{Size}}
```

## BOM and `buffer_vol` formulas

### BOM — total volume

Number of Batches that have a flavor (`Flavor1`–`Flavor8`) × `BOM_Volume`.

```javascript
var flavors = [
  $("New Repeater.Prp 3 table.Flavor1"),
  $("New Repeater.Prp 3 table.Flavor2"),
  $("New Repeater.Prp 3 table.Flavor3"),
  $("New Repeater.Prp 3 table.Flavor4"),
  $("New Repeater.Prp 3 table.Flavor5"),
  $("New Repeater.Prp 3 table.Flavor6"),
  $("New Repeater.Prp 3 table.Flavor7"),
  $("New Repeater.Prp 3 table.Flavor8")
];

var count = 0;
for (var i = 0; i < flavors.length; i++) {
  var flavor = flavors[i];
  if (flavor !== null && flavor !== undefined && flavor !== "") {
    count++;
  }
}

var bomVolume = parseFloat($("New Data Provider 3.Rows.0.BOM_Volume")) || 0;
return count * bomVolume;
```

### `buffer_vol` — total summary volume

Sum of `Summery1`–`Summery8` (field names as spelled in the app); non-numeric values count as `0`.

```javascript
const c =
  (Number($("New Form.Fields.Summery1")) || 0) +
  (Number($("New Form.Fields.Summery2")) || 0) +
  (Number($("New Form.Fields.Summery3")) || 0) +
  (Number($("New Form.Fields.Summery4")) || 0) +
  (Number($("New Form.Fields.Summery5")) || 0) +
  (Number($("New Form.Fields.Summery6")) || 0) +
  (Number($("New Form.Fields.Summery7")) || 0) +
  (Number($("New Form.Fields.Summery8")) || 0);

return c;
```

## Permissions

| Role | Can |
|---|---|
| **SUP** | Create `product_ID` · renumber, add and delete Batches · edit data at any time · sign off Standardized |
| **Operator** | Enter data for each Batch · save their employee ID once |

## URL parameters

| Parameter | Meaning |
|---|---|
| `:user` | Logged-in user |
| `:a`, `:b` | Values passed between pages to identify the `product_ID` / Batch |
