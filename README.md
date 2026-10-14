<img width="1230" height="829" alt="AHLookup screenshot" src="https://github.com/user-attachments/assets/ce045478-d14d-4369-a8dc-efcad83062c6" />
# AH Lookup

A WoW Forever addon that lets you search **Auctionator's saved price data** from anywhere in the world — no need to be at the auction house.

## Features

- `/ahl` opens a search window with a search bar
- Results update as you type, with forgiving multi-word search (see below); you can also type an item ID
- Each row shows the item icon, quality-colored name, and Auctionator's last AH price
- **Hover** a row to see the full item tooltip (works alongside DEValueTooltip, Auctionator's own tooltip lines, etc.)
- **Shift + left-click** a row to link the item in chat (opens the chat box if it isn't already open)
- **Ctrl + left-click** to preview the item in the dressing room
- Mouse wheel or the scrollbar to scroll; Escape closes the window; window position is remembered

## Searching

Type any number of partial words, in any order. Every word has to match somewhere in the item name:

- `gree iro bra` finds **Green Iron Bracers** and **Greenweave Bracers of Fire Protection**
- `bra gree iro` finds the same items (word order doesn't matter)
- `khadgars` finds **Khadgar's Whisker** (punctuation can be skipped)
- `brcrs` finds every kind of **Bracers** (letters can be skipped)

A word matches if it starts a word in the name, appears inside a word, or (loosest) its letters appear in order within a short stretch of the name. That last case is how `iro` matches the "**i**·**r**e Pr·**o**" in "F**ire Pro**tection".

Results are ranked so the best matches come first:

1. Exact name match
2. Names that start with what you typed
3. Names that contain what you typed
4. Words that start or appear inside words in the name
5. Letters-in-order (fuzzy) matches, tighter ones first

Ties are sorted alphabetically.

## Installation

1. Copy the `AHLookup` folder into:
   ```
   World of Warcraft\_forever_\Interface\AddOns\AHLookup\
   ```
2. `/reload` or restart the game.
3. Auctionator must be installed and have completed at least one AH scan.

## Commands

| Command | Effect |
|---|---|
| `/ahl` or `/ahlookup` | Toggle the search window |
| `/ahl <text>` | Open the window and search for `<text>` (e.g. `/ahl runecloth`) |
| `/ahl debug` | Show which Auctionator data table is being used and how many items it holds |
| `/ahl resetcache` | Forget cached item names and reload them |
| `/ahl help` | Show help |

## How it works

Auctionator stores prices keyed by **item ID only**, with no item names. So the first time you open the window after a scan, AH Lookup asks the game for each item's name (throttled so it doesn't flood the server). The status line shows "loading names (N left)" while this happens, and results fill in as names arrive. Items already in your game's local cache load almost instantly.

Names are saved in `AHLookupDB` (SavedVariables), so after the first session the window is ready immediately. Items added by new scans are picked up whenever you open the window, press **Refresh**, or close the auction house with the window open.

Prices come from the same sources as Waylaid Crate Advisor and DEValueTooltip:

1. `Auctionator.API.v1.GetAuctionPriceByItemID`
2. Fallback: `AUCTIONATOR_PRICE_DATABASE["Realm Faction"][itemID].m`

If no price data shows up, run `/ahl debug` to see what Auctionator data the addon can find.
