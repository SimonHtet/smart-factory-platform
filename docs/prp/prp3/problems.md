# PRP3 — Known issues and improvement ideas

[← PRP3 overview](README.md)

| # | Issue | Why it hurts | Proposed fix | Status |
|---|---|---|---|---|
| 1 | Stage data stored in numbered columns | Every extra Batch needs new columns | Row-based storage | Open |
| 2 | Products need different fields | Each new product may need new input pages | One structure sized for the largest product; unused fields = `0` | Open |
| 3 | Finish-good stored Batches as columns | Re-checks and extra Batches don't fit | One row per Batch | ✅ Done — see [finish-good.md](finish-good.md) |

## 1. Stage data is stored in columns

Thermised, Blending, After Past and Standardized data is stored with one column per Batch:

```
Current                        Proposed
Thermised_1 … Thermised_10     Process     Batch   Value
Blending_1  … Blending_10      Thermised   1       …
                               Thermised   2       …
                               Blending    1       …
```

If production grows to 10+ Batches per run, the columnar design needs new columns — and new
input-page fields — every time. A **row per Batch per process** has no upper limit and doesn't
change the table structure as volumes grow. (`Yield2` already exists because `Yield` ran out of
columns.)

## 2. Adding new products

Products go through different stages:

```
Product A: Thermised → Blending → After Past → Standardized
Product B: Thermised → Blending → Standardized
```

Building separate input pages per product means every new product needs new pages.

**Proposal:** design one structure around the product with the **most** stages and set unused
values to `0`:

| Stage | Product A | Product B |
|---|---|---|
| Thermised | 100 | 100 |
| Blending | 200 | 200 |
| After Past | 150 | **0** |
| Standardized | 180 | 180 |

All products then share the same tables and pages.

## 3. Finish-good Batches as columns — done

The number of Batches that need checking can't be known in advance (a quality issue can require
another sample), so a `Product_ID | Batch_1 | … | Batch_10` layout always hits its limit.
Finish-good now stores **one row per Batch** (`Product_ID | Batch`), and a re-check is simply a
new row. See [finish-good.md](finish-good.md#why-rows-instead-of-columns).

## Summary

Wherever the number of Batches or checks can't be fixed in advance, **use rows, not columns**.
That covers more Batches, new products and extra checks without changing the database structure.
