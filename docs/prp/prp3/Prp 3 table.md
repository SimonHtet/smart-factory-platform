# PRP 3: Prp 3 table

**Application:** PRP Dairy Mixing and Quality Control\
**Department:** PRP 3 (Fresh Milk, Fermented Milk, Tea, Coffee, and
Juice production)

------------------------------------------------------------------------

## 📌 1. System Purpose (Overview)

The `Prp 3 table` screen and table were created to record and manage
laboratory (Lab) and production data for **PRP 3**, covering products
such as Fresh Milk, Fermented Milk, Tea, Coffee, and Juice.

The system links data from Product identifier (`product_ID`) creation
through production-output recording (Yield & Finish-good).

------------------------------------------------------------------------

## 🏭 2. PRP 3 Department Overview

PRP 3 divides its production lines into **2 main Groups**:

-   **M Group:** Fresh Milk production line
-   **L Group:** Fermented Milk, Tea, Coffee, and Soy Milk production
    line

------------------------------------------------------------------------

## 🔑 3. Product Identifier (`product_ID`) Generation Rules

The system automatically generates `product_ID` by combining multiple
data elements, as shown in the example format below:

> **Format:** `Product` + `Date` + `Group` + `week` + `loop`\
> **Example:** `120226-1Fr2-M`

------------------------------------------------------------------------

## 📋 4. Data Details in `Prp 3 table`

This table stores key production and quality-control data. Its field
structure is described below:

  ------------------------------------------------------------------------------------
          No.          Field                   Data Type /      Description
                                               Format           
  -------------------- ----------------------- ---------------- ----------------------
         **1**         `product_ID`            String           Product identifier
                                                                generated from the
                                                                defined conditions,
                                                                e.g. `120226-1Fr2-M`

         **2**         `Flavor1` - `Flavor8`   String / Text    Product Flavor details
                                                                for each Batch

         **3**         `Batch1` - `Batch8`     Number / String  Production Batch
                                                                numbers (supports up
                                                                to 8 Batches per Loop)

         **4**         `Size1` - `Size8`       Float (tons)     Size or production
                                                                quantity of each
                                                                Batch, measured in
                                                                **tons**

         **5**         `Yield / Finish-good`   Data Record      Yield summary and
                                                                finished-product data
                                                                recorded after
                                                                production
  ------------------------------------------------------------------------------------

------------------------------------------------------------------------

## 🔐 5. Screen Access Management (`/create-tag/:user`)

-   **Visibility restriction:** On the Create Tag screen
    `/create-tag/:user`, users can view and access only their own
    **supervisor code (sup)**.
-   **Data storage:** After the data is created and confirmed, the
    system automatically saves all data to **`Prp 3 table`** for
    subsequent Yield & Finish-good status tracking.
