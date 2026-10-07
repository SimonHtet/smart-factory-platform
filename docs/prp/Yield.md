# 🏭 Yield Production Data Entry System

### PRP Production Data Entry

> System for recording data at each production stage\
> **Thermised → Blending → After Past / After Cooling → Standardized /
> Standardization**

Supports **4 product types**, each with different data requirements

------------------------------------------------------------------------

## 📑 Table of Contents

-   [📌 Overview](#-Overview)
-   [🥛 Product Types](#-Product%20Types)
-   [🔄 Workflow](#-Workflow)
-   [📋 Page Details](#-Page%20Details)
-   [🗄️ Database](#️-Database)
-   [🧮 Queries and Calculation
    Formulas](#-Queries%20and%20Calculation%20Formulas)
-   [👤 User Permissions](#-User%20Permissions)
-   [🔗 URL Parameters](#-url-parameters)

------------------------------------------------------------------------

# 📌 Overview

### 🔹 Main Workflow

  -----------------------------------------------------------------------
                      Step                     Description
  -------------------------------------------- --------------------------
                     **1**                     **SUP** creates
                                               `product_ID` on
                                               `/create-tag/:user`

                     **2**                     The system uses
                                               `product_ID` to create a
                                               data Row in the **Yield**

                     **3**                     For **Fermented Milk**,
                                               data is created in
                                               **Yield2**

                     **4**                     Operators enter data
                                               through `/inputdata`,
                                               `/blending`, `/buffer`,
                                               `/buffer2`

                     **5**                     When Save is pressed, data
                                               is written to **Yield /
                                               Yield2** and **prp3
                                               table**
  -----------------------------------------------------------------------

------------------------------------------------------------------------

# 🥛 Product Types

Because each Product requires different data, each page conditionally
displays a form based on the Product name **(conditional display)**

        Product        Storage Table
  ------------------- ---------------
     🥛 Demol Milk        `Yield`
      🫘 Soy Milk         `Yield`
        🍵 Tea            `Yield`
   🥣 Fermented Milk     `Yield2`

> 💡 **Note:** The `Yield` table is already full, so **Yield2** was
> added specifically for Fermented Milk data When SUP creates a
> Fermented Milk `product_ID`, the system automatically creates a data
> Row in `Yield2`

------------------------------------------------------------------------

## 🔄 Production Workflow

``` mermaid
flowchart TD
    A["🏷️ Create Tag<br/>/create-tag/:user<br/>SUP creates product_ID"]
    B["🔥 Thermised<br/>/inputdata/:a/:b/:user<br/>PRP2 Quality Check"]
    C["🥛 Blending<br/>/blending/:a/:b/:user<br/>Tank Car Receiving Check"]
    D["❄️ After Past / After Cooling<br/>/buffer/:a/:b/:user"]
    E["⚙️ Standardized / Standardization<br/>/buffer2/:a/:b/:user"]

    A --> B
    B --> C
    C --> D
    D --> E
```

# 📋 Page Details

## 1. 🏷️ `/create-tag/:user` --- Create Tag

-   Used by **SUP**
-   Creates `product_ID`
-   The `Yield` and `Yield2` tables use this value across all data-entry
    pages

------------------------------------------------------------------------

## 2. 🔥 `/inputdata/:a/:b/:user` --- Thermised

Stores data checked from **prp2**

### Product

-   Demol Milk
-   Soy Milk
-   Tea
-   Fermented Milk

### Operation

-   Displays the form based on the Product name
-   When this page opens, **8 Batches** are displayed in sequence
-   Includes a modal for entering **water pH**
-   **SUP** can change the Batch number, delete a Batch, or add a Batch
-   Data can be edited at any time
-   **Employee ID** can be saved **only once**
-   JavaScript validates completeness
-   If any required field is incomplete, **the data cannot be saved**
-   After a successful save, **the Batch background turns green**
-   **Spec values are validated** using data from `PRP_Spec`

See details at [CheckSpecPrp](#checkspecprp)

------------------------------------------------------------------------

## 3. 🥛 `/blending/:a/:b/:user` --- Blending

StoresData checked when **receiving milk into the tank car**

### Product

-   Demol Milk
-   Soy Milk
-   Tea
-   Fermented Milk

### Operation

Works exactly like the Thermised page

-   8 batch
-   SUP permissions
-   Employee IDcan be saved only once
-   Validate completeness
-   Background turns green after saving

------------------------------------------------------------------------

## 4. ❄️ `/buffer/:a/:b/:user` --- After Past / After cooling

The displayed heading depends on the Product

    Product      Displayed Name
  ------------ -------------------
   Fresh Milk    **After Past**
      Tea       **After cooling**
    Soy Milk    **After cooling**

------------------------------------------------------------------------

## 5. ⚙️ `/buffer2/:a/:b/:user` --- Standardized / Standardization

The displayed heading depends on the Product

    Product       Displayed Name
  ------------ ---------------------
   Fresh Milk    **Standardized**
    Soy Milk     **Standardized**
      Tea       **Standardization**

### Additional Features

-   Provides a field for **SUP verification/sign-off**
-   Calculates **BOM**
-   Calculates **buffer_vol**
-   When saved, data is written to the **Yield** and **prp3 table**

See details at [Calculation Formulas](#Calculation%20Formulas)

------------------------------------------------------------------------

# 🗄️ Database

  -----------------------------------------------------------------------
  Table                               Purpose
  ----------------------------------- -----------------------------------
  `Yield`                             Stores production data forDemol
                                      Milk, Soy Milk, Tea and receives
                                      `product_ID` from the
                                      `/create-tag/:user`

  `Yield2`                            Stores dataFermented Milk because
                                      `Yield` is full

  `prp3 table`                        Receives data when saved from the
                                      Standardized / Standardization

  `PRP_Spec`                          Spec table for validating entered
                                      values
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## 📊 Data Stored by Each Page

  -----------------------------------------------------------------------
  Page                                Stored Data
  ----------------------------------- -----------------------------------
  `/inputdata/:a/:b/:user`            Data checked from prp2 (Thermised)

  `/blending/:a/:b/:user`             Data checked whenreceiving milk
                                      into the tank car

  `/buffer/:a/:b/:user`               After Past / After cooling

  `/buffer2/:a/:b/:user`              Standardized / Standardization
  -----------------------------------------------------------------------

------------------------------------------------------------------------

# 🧮 Queries and Calculation Formulas

## 🔍 CheckSpecPrp

Used to validate Spec values on the Thermised, Blending, buffer, and
buffer2 pages

All **3 values are required**

-   `source`
-   `flavor`
-   `Size`

before the values can be retrieved for validation

``` sql
SELECT *
FROM PRP_Spec
WHERE Milk_Source = {{source}}
  AND Flavor = {{flavor}}
  AND Batch_Size = {{Size}}
```

------------------------------------------------------------------------

## 🧮 Calculation Formulas

### BOM --- Total Volume

Count the Flavor fields that contain values **Flavor1--Flavor8** and
multiply by `BOM_Volume`

``` javascript
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

var bomVolume =
  parseFloat(
    $("New Data Provider 3.Rows.0.BOM_Volume")
  ) || 0;

var total = count * bomVolume;

return total;
```

------------------------------------------------------------------------

### 📦 buffer_vol --- Total Summary Volume

Sum `Summery1` through `Summery8`

Non-numeric values are treated as `0`

``` javascript
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

------------------------------------------------------------------------

# 👤 User Permissions

       Role      Permission
  -------------- ------------------------------------
     **SUP**     Create `product_ID`
     **SUP**     Change Batch number
     **SUP**     Add / delete Batch
     **SUP**     Edit data at any time
     **SUP**     Sign off on the Standardized page
   **Operator**  Enter data for each Batch
   **Operator**  Employee ID can be saved only once

------------------------------------------------------------------------

# 🔗 URL Parameters

  -----------------------------------------------------------------------
                 Parameter                Meaning
  --------------------------------------- -------------------------------
                  `:user`                 Logged-in user

                `:a`, `:b`                Values passed between pages
                                          (used to reference `product_ID`
                                          / Batch data)
  -----------------------------------------------------------------------

------------------------------------------------------------------------

::: {align="center"}
**PRP Production Data Entry**
:::
