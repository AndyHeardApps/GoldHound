# GoldHound

A World of Warcraft: Forever addon that sniffs out gold-making opportunities from
your own auction house scans. Every suggestion shows cost, profit after the
auction house cut, return on investment, and the item's sale rate.

## What it finds

| Tab | Category | What it means |
| --- | --- | --- |
| Opportunities | Flip | A single auction far below the item's market value. Buy, relist. |
| Opportunities | Reset | A commodity whose cheap listings all sit well under its price history, cost less than the gold you have, and sell fast enough to move within a week. Buy them all, relist at the historical price. |
| Opportunities | Snipe | An auction ending soon where the required bid is far below market value. |
| Opportunities | Vendor sell | An auction cheaper than what a vendor pays for it. |
| Opportunities | Disenchant | An auction worth more as enchanting materials. Only shown when one of your characters has enough Enchanting skill. |
| Opportunities | Recipe | A recipe on the AH that one of your characters can learn now (profession and skill checked) and whose product is profitable to craft. Shows crafts needed to pay the recipe back. |
| Opportunities | Vendor buy | Limited-stock vendor items and vendor recipes that resell for more on the AH. Unlimited vendor junk is deliberately excluded. |
| Crafting | Craft | Recipes your characters know whose product sells for more than the materials. Each material is costed at the cheapest of vendor, what the auction house charges right now (the cheapest current listings from the last scan or refresh), or crafting it yourself from another recipe you know (smelting your own bars, for example). The product is valued at market. The **In bags** column shows how much of the materials you already hold across your characters: whole crafts covered, or the share of one craft's cost. The tooltip splits the material cost into owned and to-buy, and lists how many of each reagent you have. Owned materials are still costed at market, since you could sell them instead. |
| Restock | Restock | Items you have sold at least twice that are now scarce on the auction house. |
| Ledger | | A graph of your net worth over time (liquid gold across your characters, and inventory plus auctions at market value), above your actual sales, recorded when you collect gold from the mailbox. |
| Shopping | | A shopping list for a chosen craft: reagents needed, what you already have, where to get each one, and a Buy button for auction house commodities. Recipe headers and craft steps show the current profit per item made, with per-craft and planned totals in the tooltip. |

Clicking any row that is about an item opens its price history: one bar per
observation showing the lowest and highest listing, the 25th to 75th percentile
box, the median and the mean, with the exact numbers on hover. Every row also
has a small refresh button that re-prices that item on the spot; on a craft (in
Crafting or Plan) it re-prices the product and all its reagents, including
intermediates you craft yourself.

A posting helper also appears beside the Blizzard sell tab when you drop an item
in. It shows market value, the current cheapest listing, sale rate, deposits for
each duration, and a suggested price with a button to apply it.

Item tooltips gain market value, cheapest listing, quantity listed, sale rate,
craft cost, vendor price and disenchant value.

## Sale rates

The game never reports how fast items sell, so GoldHound infers it:

1. Each full scan is compared with the previous one. A listing that vanished
   before its time-left band could have expired counts as a sale. Rates become
   available after about 12 hours of observation and improve with every scan.
2. Your own mailbox invoices give an exact rate for things you sell.

Until there is enough data a suggestion says "unknown" rather than guessing.

## Setup

1. The addon folder lives at `_classic_beta_/Interface/AddOns/GoldHound`
   (a symlink to this repository is fine).
2. Log in. Open each profession window once on every character so recipes and
   skill levels are recorded. Visit vendors you use for reagents so their prices
   are known.
3. At the auction house press **Scan AH** in the GoldHound window (`/gh`) or the
   GoldHound button on the auction house frame. The server allows roughly one
   full scan every 15 minutes.
   Between full scans, **Refresh crafts** re-prices only the items your known
   recipes make or use. It runs one auction house search per item, which the
   15-minute throttle does not apply to, so the Crafting tab can be rechecked
   every couple of minutes. A few hundred items take one to two minutes; the
   table updates as results arrive, and clicking the button again stops it.
   Reagents with an unlimited vendor price are skipped, as the vendor sets
   their price. Refreshed listings replace the full-scan listings for those
   items, so the Buy buttons use the current prices too, and each refresh adds
   a point to the item's price history. Sale rates still only come from full
   scans.
   Right-click **Scan AH** (or `/gh auto`) to turn on auto-scan: while the
   auction house stays open, a new full scan starts each time the cooldown
   ends, so you can park a character at the auctioneer and let the price
   history build up.
   The listings from the last scan, with any refreshes since, are saved, so
   the opportunities are still there after a reload or relog. The Age column
   shows how old the prices behind each row are, and the small refresh button
   on a row re-checks just that item (or that craft and its reagents).
   Click a row for the item's price chart. Alt-click any item link, in chat,
   your bags or any other window, to open the same chart.
4. Scan at least three times over a day or two. Flips and resets need price
   history before they appear.

## Commands

| Command | Effect |
| --- | --- |
| `/gh` | Toggle the window |
| `/gh scan` | Full scan (add `force` to ignore the local cooldown) |
| `/gh auto [on\|off]` | Auto-scan: start a full scan whenever the cooldown ends while the auction house is open |
| `/gh refresh` | Re-price only the items your recipes make and use (add `force` to ignore the cooldown, `stop` to cancel) |
| `/gh minprofit 1g50s` | Minimum profit before something is suggested (0 disables) |
| `/gh minroi 25` | Minimum return on investment in percent; a suggestion must clear both thresholds, so set the flat minimum to 0 to go by ROI alone (0 disables) |
| `/gh discount 30` | How far below market a flip or snipe must be, in percent |
| `/gh resetdiscount 35` | How far below the price history a reset buy must be |
| `/gh cut 5` | Auction house cut applied to every sale estimate |
| `/gh tooltip` | Toggle the tooltip lines |
| `/gh status` | Database summary |
| `/gh units auto\|unit\|stack` | How the full scan reports commodity buyouts. Auto-detected after each scan by comparing one listing with a live search; override only if the detection is wrong |
| `/gh reset prices\|recipes\|vendors\|ledger\|worth` | Wipe stored data |

## Notes on the Forever client

- Interface version 16001, modern `C_AuctionHouse`, `C_TradeSkillUI` and `C_Item` APIs.
- Early beta builds wrote SavedVariables but did not reload them. If the price
  database is empty after a relog on an old build, that is the cause.
- Classic-era disenchant tables and deposit rates are used as estimates and may
  need adjusting once Forever's numbers are confirmed.
