# ShelfLife

Consignment with automatic markdown, on BOT Chain.

A shop opens with a commission rate. A consignor puts an item on the shelf with
a start price, a floor, a markdown step and a term. From then on **the price
steps down on its own**: nobody re-lists, nobody re-prices, nobody has to be
online. `priceOf` is a pure function of the clock, so what a buyer pays is what
anyone could have computed in advance.

## What the schedule guarantees

- **The shop cannot raise a price or pause the markdown.** The schedule is
  fixed at consignment and no later call by anyone changes it.
- **The price never falls through the floor** the consignor set.
- **Past the term the shelf is closed.** The item goes back to its consignor
  rather than being quietly marked down to nothing.
- **Overpayment comes back.** A buyer racing a markdown step is refunded the
  difference in the same call.

Money is split at the moment of sale and held per party until pulled, so a shop
that goes quiet cannot strand a consignor's proceeds.

## Contract surface

| Call | Who | What it does |
|---|---|---|
| `openShop(name, commissionBps)` | anyone | Commission up to 40%, fixed for the shop's life |
| `setAccepting(shopId, bool)` | keeper | Stops new stock; items already on the shelf keep selling |
| `consign(shopId, title, startPrice, floorPrice, stepBps, stepSecs, term)` | anyone but the keeper | Step ≤ 20% of start, interval 1 hour – 30 days, term 1 – 365 days |
| `buy(itemId)` | anyone but the consignor | Pays today's price; the surplus is returned |
| `returnItem(itemId)` | consignor **any time**, keeper **only after the term** | Takes it off the shelf |
| `withdrawProceeds()` | consignor or keeper | Pull payment, works while paused |

A sale splits three ways: protocol fee (1.5% default, capped 5%), the shop's
commission, and the rest to the consignor. `onlyOwner` covers pause/unpause,
`setFeeBps` and `withdrawFees`, which is bounded by `accumulatedFees` and can
never reach credited proceeds. A pause blocks new shops, consignments and sales
but never a withdrawal.

Useful views: `priceOf`, `stepsTaken`, `nextStepIn`, `expiresAt`, `isOnShelf`.

## Build and deploy

```bash
npm install
npx hardhat test          # 17 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **Scandinavian / Nordic
minimal**: off-white and sand, hairlines, generous air, no shadows and no
gradients. Every item is drawn as a hanging swing ticket — notched corner,
punched hole, string — set in a loose airy gallery rather than as a card, and
the markdown schedule is a horizontal ladder of dots, one per step, filled as
each one is taken, with the floor marked by a wider ring. Navigation is a quiet
row of text links.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time.
