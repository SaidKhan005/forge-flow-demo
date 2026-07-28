---
source_pdf: Clover Training Full Manual.pdf
title: Clover POS
pages: 24
conversion_notes: Selectable text extracted with PyMuPDF from the designed Clover Training Full Manual, a full-page-screenshot operator manual. The manual's text boxes were reflowed into Markdown paragraphs; the nine ALL-CAPS section banners (INTRO, BAR TABS, FLOOR PLAN SCREEN NAVIGATION, TABLE STATUS, ORDER SCREEN WALKTHROUGH, GUEST MANAGEMENT, ITEM MANAGEMENT, PAYMENTS, ORDER MANAGEMENT) formatted as title-case Markdown ## headings; each step title formatted as a ### heading with its instruction text as the body; the table-status legend and the payment-options list preserved as Markdown bullets. Non-content chrome excluded, the repeated cover/title art on page 1 and the standalone banner glyphs. The doc name is presented under the operator manual title Clover POS (unchanged from the prior source so the routed label, destination, and corpus id stay the same). Content pictures (the full-page step screenshots, roughly three per page at 1536x864 or larger) are extracted to assets/internal/barrio/training/clover_sop/ and referenced with image markers at their source positions by tool/barrio_training_image_extractor.py; markers are formatting, not words.
---

# Clover POS

## Table of Contents

- Intro
- Bar Tabs
- Floor Plan Screen Navigation
- Table Status
- Order Screen Walkthrough
- Guest Management
- Item Management
- Payments
- Order Management

## Intro

### Log In to the Clover Station

Log in to the Clover station using either your assigned fingerprint or your assigned six-digit code.

### Open the Point-of-Sale System (First Login of the Day)

If you are the first person to log in for the day, select Clover Dining to open the food and beverage point-of-sale system.

![](assets/internal/barrio/training/clover_sop/01.webp)

### View the Floor Plan

The first screen displayed is the floor plan.

### Begin an Order

To begin an order, select the appropriate table on the screen.

![](assets/internal/barrio/training/clover_sop/02.webp)

### Navigate Between Rooms and Revenue Types

The options along the top of the screen allow you to navigate between the different rooms and revenue types. These include Takeout and Bar Tabs.

![](assets/internal/barrio/training/clover_sop/03.webp)

## Bar Tabs

### Begin a Bar Tab

While on the Bar Tab screen, select the green plus icon in the bottom right corner.

![](assets/internal/barrio/training/clover_sop/04.webp)

### Enter the Number of Guests

Enter the number of guests for the tab. A bar tab is typically assigned to a single individual, so enter one guest.

![](assets/internal/barrio/training/clover_sop/05.webp)

### Add a Menu Item

Select a menu item, such as Can Pop, to add it to the order.

![](assets/internal/barrio/training/clover_sop/06.webp)

### Select the Item Modifier

Select the relevant modifier for the item.

![](assets/internal/barrio/training/clover_sop/07.webp)

### Access Additional Options

Once all items for the bar tab have been added, select the three-dot icon on the bottom bar.

![](assets/internal/barrio/training/clover_sop/08.webp)

### Add a Note to Label the Tab

This opens a menu. For bar tabs, always add a note to label the name on the tab and identify the person responsible for the bar tab.

![](assets/internal/barrio/training/clover_sop/09.webp)

### Name the Tab

This opens a pop-up window for you to name the tab. In this example, the tab is named Brian.

![](assets/internal/barrio/training/clover_sop/10.webp)

### Fire the Order

Select Fire All to send the order.

### Access an Existing Tab

The tab then appears under Bar Tabs with the relevant name. Select the tab to reopen it and make adjustments.

![](assets/internal/barrio/training/clover_sop/11.webp)

## Floor Plan Screen Navigation

### Open the Cash Drawer

Within any tab, select the three-dot icon in the top right corner. At the Bar station, this will prompt you to open the cash drawer.

![](assets/internal/barrio/training/clover_sop/12.webp)

### Provide a Reason to Open the Cash Drawer

Selecting Open Cash Drawer prompts you to enter a reason. This field is mandatory. You will not be able to open the cash drawer without providing a reason.

![](assets/internal/barrio/training/clover_sop/13.webp)

### Use the Search Function

Next to the three-dot icon is a search icon. Selecting it opens the search function, which includes open tables.

![](assets/internal/barrio/training/clover_sop/14.webp)

### Locate Orders Using Search

Use the search function to locate specific orders by name, table, or the note made on the table. The search bar allows you to quickly take action on a table or tab. Through this function, you can start an order, view or modify an order, and pay for an order.

![](assets/internal/barrio/training/clover_sop/15.webp)

### Search for a Specific Tab

For example, you can search for the tab that was just added, named Brian.

![](assets/internal/barrio/training/clover_sop/16.webp)

### Open the Main Navigation Sidebar

The menu icon in the top right corner opens the main navigation sidebar. To view all orders, both open and closed, select View All Orders.

![](assets/internal/barrio/training/clover_sop/17.webp)

### View Orders History

This opens a new screen that displays all orders from the past thirty days.

![](assets/internal/barrio/training/clover_sop/18.webp)

### Filter Orders

Open orders and paid orders can be filtered as shown.

![](assets/internal/barrio/training/clover_sop/19.webp)

### Apply Additional Filters

At the top right of this screen, you can select the filter icon to organize and display orders more granularly. For example, you can filter orders by employee.

![](assets/internal/barrio/training/clover_sop/20.webp)

### Filter by Payment Status

You can also filter by payment status, for example paid or partially paid.

![](assets/internal/barrio/training/clover_sop/21.webp)

### Sort Orders

Orders can also be sorted by either the time they were rung in or the time the table was closed.

![](assets/internal/barrio/training/clover_sop/22.webp)

## Table Status

### View the Table Status Legend

The floor plan displays different statuses on tables. Select Legend in the bottom right corner to view what each status means:

- Light blue indicates a table you own that has been seated.
- Red indicates a table you own that has been seated for longer than one and a half hours.
- Green indicates that the table has paid. Because payments are integrated, this status should not normally appear.

### Access Permissions for Tables

When logged in, you will see your teammates' names on the tables they own. Unless you have the assigned permissions, such as those of a manager or supervisor, you cannot access another teammate's table.

![](assets/internal/barrio/training/clover_sop/23.webp)

![](assets/internal/barrio/training/clover_sop/24.webp)

### Visibility of Bar Tabs by Access Level

You will not be able to see a teammate's bar tabs unless you have the same or a higher access level. For example, a server cannot see a supervisor's tables, but a supervisor can see a server's tables.

![](assets/internal/barrio/training/clover_sop/25.webp)

## Order Screen Walkthrough

### View the Order Screen

Once inside a table, you will see the order screen. The table number is displayed in the top left corner, for example Table 2 in this case.

![](assets/internal/barrio/training/clover_sop/26.webp)

### Adjust the Guest Count

Below the table number, you will see the guest count. Select it to adjust the number of guests for the table.

![](assets/internal/barrio/training/clover_sop/27.webp)

### Navigate the Categories List

On the left side, the categories are organized in a list. Scroll up and down to view all the categories. Some categories are broken down into color-coded subcategories. For example, Beverages is broken down into Cold Beverages and Hot Beverages. The items appear in order of subcategory. The final item in each category is a custom item, which is available to higher access levels.

![](assets/internal/barrio/training/clover_sop/28.webp)

### Filter by Subcategory

Within each category, you can select a subcategory to filter into that specific subcategory. For example, here you are in Beverages, then Cold Beverages.

![](assets/internal/barrio/training/clover_sop/29.webp)

### Organization of Large Subcategory Lists

Large subcategory lists, such as bottled wine lists and longer liquor lists, are further organized in alphabetical order.

![](assets/internal/barrio/training/clover_sop/30.webp)

### Locate the All Items Category

At the very bottom of the category list is an All Items category

![](assets/internal/barrio/training/clover_sop/31.webp)

### Use the Search Bar to Find Menu Items

Use the search bar to quickly find an item on the menu.

![](assets/internal/barrio/training/clover_sop/32.webp)

## Guest Management

### Select the Correct Guest Before Ringing an Item

When ringing in any item, first select the guest the item belongs to, unless it is an item being shared by the whole table. This is essential for the kitchen to understand timing, plating, and fulfillment. Select a guest to manage their individual order.

Important: The Whole Table option is used only for shareable items.

![](assets/internal/barrio/training/clover_sop/33.webp)

### Manage an Individual Guest

Select the three dots on each guest to manage that guest. This opens a menu that allows you to manage the guest and their items.

![](assets/internal/barrio/training/clover_sop/34.webp)

### Add Guest Allergens

Use Add Allergens to record any allergens that a guest has. If an allergen is not available as an option, use the Add Custom Allergen function.

![](assets/internal/barrio/training/clover_sop/35.webp)

### Move Items Between Guests

Use Move Items to transfer items from one guest to another or to move items to the entire table. Select the item you want to move on the left, then select the destination on the right side tabs.

![](assets/internal/barrio/training/clover_sop/36.webp)

### Move a Guest to Another Table

Select Move Guest to relocate a diner to a different table.

![](assets/internal/barrio/training/clover_sop/37.webp)

### Guest Appearance After Being Moved

Once a guest has been moved to another table, they will appear at the destination table as shown, for example Guest 5 (From Table 2). Moving a guest adds another guest to the destination table. It does not merge the guest number from the former table into the new one.

![](assets/internal/barrio/training/clover_sop/38.webp)

## Item Management

### Add Custom Modifiers

To add a custom modifier, select an item, choose Custom Modifier, and type in the modifier

![](assets/internal/barrio/training/clover_sop/39.webp)

### Set the Item Quantity

Select the quantity at the top to choose the number of items to ring in, for example six tequila shots.

![](assets/internal/barrio/training/clover_sop/40.webp)

### Quantity Display

The quantity appears as a blue number next to the item.

![](assets/internal/barrio/training/clover_sop/41.webp)

### Adjust Quantity and Apply Item-Level Discounts

Select an item to view it and make quantity adjustments. This screen can also be used to apply item-level discounts. Use the plus and minus icons to adjust the quantity of items. Select the Add Discount button to apply a discount to the selected item only.

![](assets/internal/barrio/training/clover_sop/42.webp)

### Discount Menu

Selecting Add Discount opens a discount menu.

![](assets/internal/barrio/training/clover_sop/43.webp)

### Item-Specific Discount Applied

The discount is applied to the specific item only.

![](assets/internal/barrio/training/clover_sop/44.webp)

### Voiding Fired Items

Subtracting the quantity of items that have already been fired triggers a void of that individual item quantity. Voided item receipts are printed for transparent tracking and accountability.

![](assets/internal/barrio/training/clover_sop/45.webp)

### Void an Entire Item

Selecting Void while on an item deletes the entire item, including all quantities of it.

### Deleting Items That Have Not Been Fired

When items have not been fired, they can be deleted directly. This does not trigger a void.

![](assets/internal/barrio/training/clover_sop/46.webp)

### Using Whole Table to Split and Share Items

Placing and moving items to the Whole Table allows for splitting and sharing among seats and guests. If any items under a guest need to be split, move them to the Whole Table first, then split them as shown. Selecting the three-dot icon on Whole Table opens the screen shown below.

![](assets/internal/barrio/training/clover_sop/47.webp)

### Split Item Cost Among Guests

Select Split Item Cost to divide shared items between guests. Select the items on the left and the guests who will split the item on the right.

![](assets/internal/barrio/training/clover_sop/48.webp)

![](assets/internal/barrio/training/clover_sop/49.webp)

## Payments

### Initiate a Payment

To initiate a payment on either a handheld or stationed device, select Pay or select Pay by Guest.

### Payment Options Window

Selecting Pay opens a window with multiple options:

- Pay the full amount of the bill

![](assets/internal/barrio/training/clover_sop/50.webp)
- Split the entire bill into custom or equal amounts.

![](assets/internal/barrio/training/clover_sop/51.webp)
- Split by Items allows you to take payments per item

![](assets/internal/barrio/training/clover_sop/52.webp)
- Split by Guest allows you to split the bill by the guests on the table to take payment

![](assets/internal/barrio/training/clover_sop/53.webp)

### Pay by Guest Prompt

Selecting Pay by Guest will first prompt you to either share the Whole Table items or not

![](assets/internal/barrio/training/clover_sop/54.webp)

### Select a Guest for Payment

You will then be prompted to select a guest to take payment from.

![](assets/internal/barrio/training/clover_sop/55.webp)

## Order Management

### Move an Order

Use Move Order to transfer a table or tab to another table or tab.

![](assets/internal/barrio/training/clover_sop/56.webp)

### Transfer Prompt

You will be prompted to make a transfer to either a table or a tab.

![](assets/internal/barrio/training/clover_sop/57.webp)

### Select the Destination

Select the destination table or tab.

![](assets/internal/barrio/training/clover_sop/58.webp)

### Confirm the Transfer

Confirm the transfer. Note that this action is irreversible. You will need to perform a manual re-transfer to undo it.

![](assets/internal/barrio/training/clover_sop/59.webp)

### Add an Order-Level Discount

To add discounts to the entire order rather than a single item, use Add Order Discounts.

### Order Discount Pop-Up

This opens the same pop-up seen with item discounts. Note that these discounts apply to the entire bill and stack on top of item discounts.

![](assets/internal/barrio/training/clover_sop/60.webp)

### Open the Full Function Menu

Selecting the three-dot icon on the lower toolbar opens the full function menu.

![](assets/internal/barrio/training/clover_sop/61.webp)

### Transfer the Server

Select Transfer Server to reassign the order to another team member.

![](assets/internal/barrio/training/clover_sop/62.webp)

### Use Coursing

Use Coursing to organize the timing of order delivery.

![](assets/internal/barrio/training/clover_sop/63.webp)

### Combine Orders

Select Combine Orders to merge two existing tables or tabs.

![](assets/internal/barrio/training/clover_sop/64.webp)

### Combining Orders Steps

The steps are the same as those for moving a table.

![](assets/internal/barrio/training/clover_sop/65.webp)

![](assets/internal/barrio/training/clover_sop/66.webp)

### Add Notes

Use Notes to create custom notes for yourself or any team member viewing the point-of-sale system.

These notes can be used to track bar tabs or to record special reservation details for a table. They serve as your personal go-to reference for a table or tab.

![](assets/internal/barrio/training/clover_sop/67.webp)

### Delete an Order

Use Delete to cancel an order and start over. Note that Delete can only be used before anything has been fired.

![](assets/internal/barrio/training/clover_sop/68.webp)

### Voiding After Firing

If items have already been fired, each item must be voided individually.

![](assets/internal/barrio/training/clover_sop/69.webp)
