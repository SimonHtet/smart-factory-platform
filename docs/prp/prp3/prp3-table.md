# PRP3 — `Prp 3 table`

[← PRP3 overview](README.md)

`Prp 3 table` holds the core data of each production run in PRP3 — and of **PRP1 Fresh Milk**,
which uses the same process. It is filled from the Create Tag page and updated again when the
Standardized stage is saved.

## Fields

| Field | Type | Description |
|---|---|---|
| `product_ID` | String | Run identifier, e.g. `120226-1Fr2-M` — see [format](#product_id) |
| `Flavor1` – `Flavor8` | Text | Flavor of each Batch |
| `Batch1` – `Batch8` | Number / String | Batch numbers — up to **8 Batches per loop** |
| `Size1` – `Size8` | Float (tons) | Size of each Batch, in **tons** |
| Yield / Finish-good | Record | Yield summary and finished-product data recorded after production |

Batches are stored as **numbered columns**, which caps a run at 8 Batches — see
[problems.md](problems.md#1-stage-data-is-stored-in-columns).

## Product_ID

Generated automatically from the date, week, day of week, loop and group:

```
{YY}{MM}{DD}-{Week}{Day}{Loop}-{Group}
```

| Example | Meaning |
|---|---|
| `260106-41Tu1-A` | 6 Jan 2026, week 41, Tuesday, loop 1, group A |

Day codes: `Su` `Mo` `Tu` `We` `Th` `Fr` `Sa`. This is the format produced by the
[SaveBatch script](finish-good.md#script).

> ⚠️ **To verify:** the original docs give `120226-1Fr2-M` as the PRP3 example and describe the
> format as *Product + Date + Group + Week + Loop*, which does not match the script's
> `YYMMDD-…` order. PRP1 Soy Milk uses `DDMMYY` (`300726-31Th1`). Check which order the live app
> produces before relying on either.

## Create Tag page — `/create-tag/:user`

- Used by the **SUP** to create the `Product_ID`, flavors, batches and sizes for a run.
- Each SUP **sees only their own supervisor code**.
- On confirm, everything is saved to `Prp 3 table`, and a matching row is created in `Yield` /
  `Yield2` and in `Finish-good` so the run can be tracked through every stage.
