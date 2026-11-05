const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 24 * 60 * 60;

describe("ShelfLife", function () {
  let sl, owner, keeper, consignor, buyer, other;
  const start = ethers.parseEther("10");
  const floor = ethers.parseEther("4");
  const stepBps = 1000; // 10% of start per step
  const stepSecs = 7 * DAY;
  const term = 90 * DAY;
  const commission = 2000; // 20%

  beforeEach(async function () {
    [owner, keeper, consignor, buyer, other] = await ethers.getSigners();
    const F = await ethers.getContractFactory("ShelfLife");
    sl = await F.deploy();
    await sl.waitForDeployment();
    await sl.connect(keeper).openShop("Cedar & Co", commission);
  });

  async function consign() {
    await sl
      .connect(consignor)
      .consign(0, "Walnut credenza", start, floor, stepBps, stepSecs, term);
    return 0;
  }

  it("opens a shop with its commission on record", async function () {
    const s = await sl.getShop(0);
    expect(s.keeper).to.equal(keeper.address);
    expect(s.name).to.equal("Cedar & Co");
    expect(s.commissionBps).to.equal(commission);
    expect(s.accepting).to.equal(true);
    expect(await sl.shopCount()).to.equal(1n);
    await expect(sl.connect(keeper).openShop("Too greedy", 4001)).to.be.revertedWith(
      "commission too high"
    );
  });

  it("consigns an item with a fixed markdown schedule", async function () {
    const id = await consign();
    const it = await sl.getItem(id);
    expect(it.consignor).to.equal(consignor.address);
    expect(it.startPrice).to.equal(start);
    expect(it.floorPrice).to.equal(floor);
    expect(it.stepBps).to.equal(stepBps);
    expect(it.title).to.equal("Walnut credenza");
    expect(it.status).to.equal(0); // OnShelf
    expect(await sl.priceOf(id)).to.equal(start);
    expect(await sl.getShopItems(0)).to.deep.equal([0n]);
    expect(await sl.itemsByConsignor(consignor.address)).to.deep.equal([0n]);
    expect((await sl.getShop(0)).itemsTaken).to.equal(1);
  });

  it("rejects a floor above the start, a zero step or a term outside the bounds", async function () {
    await expect(
      sl.connect(consignor).consign(0, "x", floor, start, stepBps, stepSecs, term)
    ).to.be.revertedWith("bad floor");
    await expect(
      sl.connect(consignor).consign(0, "x", start, floor, 0, stepSecs, term)
    ).to.be.revertedWith("bad step");
    await expect(
      sl.connect(consignor).consign(0, "x", start, floor, 2001, stepSecs, term)
    ).to.be.revertedWith("bad step");
    await expect(
      sl.connect(consignor).consign(0, "x", start, floor, stepBps, stepSecs, 60)
    ).to.be.revertedWith("bad term");
    await expect(
      sl.connect(keeper).consign(0, "x", start, floor, stepBps, stepSecs, term)
    ).to.be.revertedWith("keeper cannot consign to own shop");
  });

  it("steps the price down on the clock, with nobody doing anything", async function () {
    const id = await consign();
    expect(await sl.priceOf(id)).to.equal(start);
    expect(await sl.stepsTaken(id)).to.equal(0n);

    await time.increase(stepSecs + 1);
    expect(await sl.stepsTaken(id)).to.equal(1n);
    expect(await sl.priceOf(id)).to.equal(ethers.parseEther("9"));

    await time.increase(2 * stepSecs);
    expect(await sl.stepsTaken(id)).to.equal(3n);
    expect(await sl.priceOf(id)).to.equal(ethers.parseEther("7"));
  });

  it("never marks down below the floor the consignor set", async function () {
    const id = await consign();
    await time.increase(20 * stepSecs); // would be -100% without the floor
    expect(await sl.priceOf(id)).to.equal(floor);
    expect(await sl.nextStepIn(id)).to.equal(0n);

    await time.increase(60 * stepSecs);
    expect(await sl.priceOf(id)).to.equal(floor);
  });

  it("reports the time to the next markdown", async function () {
    const id = await consign();
    const left = await sl.nextStepIn(id);
    expect(left).to.be.greaterThan(0n);
    expect(left).to.be.lessThanOrEqual(BigInt(stepSecs));
    await time.increase(Number(left) + 1);
    expect(await sl.stepsTaken(id)).to.equal(1n);
  });

  it("sells at the marked-down price and splits three ways", async function () {
    const id = await consign();
    await time.increase(2 * stepSecs + 1);
    const price = await sl.priceOf(id); // 8 BOT

    const fee = (price * 150n) / 10_000n;
    const comm = (price * BigInt(commission)) / 10_000n;
    const toConsignor = price - fee - comm;

    await expect(sl.connect(buyer).buy(id, { value: price }))
      .to.emit(sl, "Sold")
      .withArgs(id, buyer.address, price, toConsignor, comm, fee);

    const it = await sl.getItem(id);
    expect(it.status).to.equal(1); // Sold
    expect(it.soldFor).to.equal(price);
    expect(it.buyer).to.equal(buyer.address);
    expect(await sl.proceeds(consignor.address)).to.equal(toConsignor);
    expect(await sl.proceeds(keeper.address)).to.equal(comm);
    expect(await sl.accumulatedFees()).to.equal(fee);
    expect(await sl.lockedTotal()).to.equal(toConsignor + comm);
    expect((await sl.getShop(0)).itemsSold).to.equal(1);
  });

  it("returns overpayment instead of keeping it", async function () {
    const id = await consign();
    const price = await sl.priceOf(id);
    const sent = price + ethers.parseEther("3");

    const before = await ethers.provider.getBalance(buyer.address);
    const tx = await sl.connect(buyer).buy(id, { value: sent });
    const rc = await tx.wait();
    const after = await ethers.provider.getBalance(buyer.address);
    expect(before - after - rc.gasUsed * rc.gasPrice).to.equal(price);
    expect((await sl.getItem(id)).soldFor).to.equal(price);
  });

  it("refuses a sale under the shelf price, from the consignor, or after the term", async function () {
    const id = await consign();
    await expect(
      sl.connect(buyer).buy(id, { value: start - 1n })
    ).to.be.revertedWith("under the shelf price");
    await expect(sl.connect(consignor).buy(id, { value: start })).to.be.revertedWith(
      "consignor cannot buy"
    );

    await time.increase(term + 1);
    await expect(sl.connect(buyer).buy(id, { value: start })).to.be.revertedWith("term expired");
    expect(await sl.isOnShelf(id)).to.equal(false);
  });

  it("lets the consignor pull the item at any time", async function () {
    const id = await consign();
    await expect(sl.connect(consignor).returnItem(id))
      .to.emit(sl, "ItemReturned")
      .withArgs(id, consignor.address, true);
    expect((await sl.getItem(id)).status).to.equal(2); // Returned
    await expect(sl.connect(buyer).buy(id, { value: start })).to.be.revertedWith(
      "not on the shelf"
    );
  });

  it("lets the keeper return it only once the term has run out", async function () {
    const id = await consign();
    await expect(sl.connect(keeper).returnItem(id)).to.be.revertedWith("term still running");
    await expect(sl.connect(other).returnItem(id)).to.be.revertedWith("not a party");

    await time.increase(term + 1);
    await expect(sl.connect(keeper).returnItem(id))
      .to.emit(sl, "ItemReturned")
      .withArgs(id, consignor.address, false);
  });

  it("pays each party on their own pull, so a quiet shop strands nobody", async function () {
    const id = await consign();
    const price = await sl.priceOf(id);
    await sl.connect(buyer).buy(id, { value: price });

    const owed = await sl.proceeds(consignor.address);
    const before = await ethers.provider.getBalance(consignor.address);
    const tx = await sl.connect(consignor).withdrawProceeds();
    const rc = await tx.wait();
    const after = await ethers.provider.getBalance(consignor.address);
    expect(after - before + rc.gasUsed * rc.gasPrice).to.equal(owed);

    expect(await sl.proceeds(consignor.address)).to.equal(0n);
    await expect(sl.connect(consignor).withdrawProceeds()).to.be.revertedWith(
      "nothing to withdraw"
    );
    // The keeper's commission is still waiting for them, untouched.
    expect(await sl.proceeds(keeper.address)).to.be.greaterThan(0n);
  });

  it("stops new consignments when the shop closes its doors but keeps selling the shelf", async function () {
    const id = await consign();
    await expect(sl.connect(keeper).setAccepting(0, false))
      .to.emit(sl, "ShopAccepting")
      .withArgs(0, false);
    await expect(
      sl.connect(other).consign(0, "late", start, floor, stepBps, stepSecs, term)
    ).to.be.revertedWith("not accepting");
    await expect(sl.connect(buyer).buy(id, { value: start })).to.emit(sl, "Sold");
    await expect(sl.connect(other).setAccepting(0, true)).to.be.revertedWith("not keeper");
  });

  it("blocks new shops, consignments and sales while paused but never a withdrawal", async function () {
    const id = await consign();
    await sl.connect(buyer).buy(id, { value: start });

    await sl.connect(owner).pause();
    await expect(sl.connect(other).openShop("Nope", 100)).to.be.revertedWithCustomError(
      sl,
      "EnforcedPause"
    );
    await expect(
      sl.connect(other).consign(0, "nope", start, floor, stepBps, stepSecs, term)
    ).to.be.revertedWithCustomError(sl, "EnforcedPause");

    // Proceeds already credited are owed and still move.
    await sl.connect(consignor).withdrawProceeds();
    await sl.connect(keeper).withdrawProceeds();

    await sl.connect(owner).unpause();
    await expect(sl.connect(other).openShop("Open again", 100)).to.emit(sl, "ShopOpened");
  });

  it("caps the fee and lets the owner withdraw fees only", async function () {
    await expect(sl.connect(owner).setFeeBps(501)).to.be.revertedWith("fee too high");
    await sl.connect(owner).setFeeBps(500);
    await expect(sl.connect(other).setFeeBps(10)).to.be.revertedWithCustomError(
      sl,
      "OwnableUnauthorizedAccount"
    );

    await expect(sl.connect(owner).withdrawFees(owner.address)).to.be.revertedWith(
      "nothing to withdraw"
    );

    const id = await consign();
    await sl.connect(buyer).buy(id, { value: start });
    const fees = await sl.accumulatedFees();
    expect(fees).to.equal((start * 500n) / 10_000n);

    await sl.connect(owner).withdrawFees(owner.address);
    expect(await sl.accumulatedFees()).to.equal(0n);
    // What is left is exactly what the two parties are owed.
    expect(await ethers.provider.getBalance(await sl.getAddress())).to.equal(
      await sl.lockedTotal()
    );
  });

  it("holds accounting across two sales and a return", async function () {
    await sl.connect(consignor).consign(0, "A", start, floor, stepBps, stepSecs, term);
    await sl.connect(consignor).consign(0, "B", start, floor, stepBps, stepSecs, term);
    await sl.connect(other).consign(0, "C", start, floor, stepBps, stepSecs, term);

    await time.increase(stepSecs + 1);
    await sl.connect(buyer).buy(0, { value: ethers.parseEther("9") });
    await sl.connect(buyer).buy(1, { value: ethers.parseEther("9") });
    await sl.connect(other).returnItem(2);

    expect(await ethers.provider.getBalance(await sl.getAddress())).to.equal(
      (await sl.lockedTotal()) + (await sl.accumulatedFees())
    );

    await sl.connect(consignor).withdrawProceeds();
    await sl.connect(keeper).withdrawProceeds();
    expect(await sl.lockedTotal()).to.equal(0n);
    expect(await ethers.provider.getBalance(await sl.getAddress())).to.equal(
      await sl.accumulatedFees()
    );
  });

  it("keeps newest-first pages and rejects views on a shop or item that does not exist", async function () {
    await expect(sl.getItem(0)).to.be.revertedWith("no such item");
    await expect(sl.getShop(1)).to.be.revertedWith("no such shop");
    await consign();
    await sl.connect(other).openShop("Second", 500);
    expect(await sl.itemCount()).to.equal(1n);
    expect(await sl.getRecentShops(5)).to.deep.equal([1n, 0n]);
    expect(await sl.getRecentItems(5)).to.deep.equal([0n]);
    expect(await sl.expiresAt(0)).to.be.greaterThan(0n);
  });
});
