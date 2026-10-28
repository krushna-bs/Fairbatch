```ts
import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";

describe("FairBatch", function () {
  let fairBatch: Contract;
  let testUSDC: Contract;
  let buyer: any;
  let seller: any;
  let other: any;

  const PRICE_SCALE = ethers.parseEther("1");
  const ONE_ETH = ethers.parseEther("1");

  beforeEach(async function () {
    [buyer, seller, other] = await ethers.getSigners();

    const TestUSDC = await ethers.getContractFactory("TestUSDC");
    testUSDC = await TestUSDC.deploy();
    await testUSDC.waitForDeployment();

    const FairBatch = await ethers.getContractFactory("FairBatch");
    fairBatch = await FairBatch.deploy(
      await testUSDC.getAddress()
    );
    await fairBatch.waitForDeployment();

    // Give the buyer test USDC for BUY-order escrow.
    await testUSDC.connect(buyer).mint();

    await testUSDC
      .connect(buyer)
      .approve(
        await fairBatch.getAddress(),
        ethers.MaxUint256
      );
  });

  it("deploys with the correct TestUSDC address", async function () {
    expect(await fairBatch.testUSDC()).to.equal(
      await testUSDC.getAddress()
    );
  });

  it("accepts a BUY order and stores it", async function () {
    const price = 2500n * 1_000_000n;

    await fairBatch
      .connect(buyer)
      .submitBuy(ONE_ETH, price);

    const order = await fairBatch.orders(1);

    expect(order.owner).to.equal(buyer.address);
    expect(order.side).to.equal(0);
    expect(order.ethAmount).to.equal(ONE_ETH);
    expect(order.limitPrice).to.equal(price);
    expect(order.epoch).to.equal(1);
    expect(order.status).to.equal(0);
  });

  it("accepts a SELL order with ETH escrow", async function () {
    const price = 2400n * 1_000_000n;

    await fairBatch
      .connect(seller)
      .submitSell(ONE_ETH, price, {
        value: ONE_ETH,
      });

    const order = await fairBatch.orders(1);

    expect(order.owner).to.equal(seller.address);
    expect(order.side).to.equal(1);
    expect(order.ethAmount).to.equal(ONE_ETH);
    expect(order.limitPrice).to.equal(price);
    expect(order.escrowedAmount).to.equal(ONE_ETH);
  });

  it("rejects an order larger than 10 ETH", async function () {
    const price = 2500n * 1_000_000n;
    const tooLarge = ethers.parseEther("10.000000000000001");

    await expect(
      fairBatch
        .connect(buyer)
        .submitBuy(tooLarge, price)
    ).to.be.revertedWithCustomError(
      fairBatch,
      "OrderTooLarge"
    );
  });

  it("rejects an epoch above the 64-order cap", async function () {
    const price = 2500n * 1_000_000n;

    for (let i = 0; i < 64; i++) {
      await fairBatch
        .connect(buyer)
        .submitBuy(
          ethers.parseEther("0.1"),
          price
        );
    }

    await expect(
      fairBatch
        .connect(buyer)
        .submitBuy(
          ethers.parseEther("0.1"),
          price
        )
    ).to.be.revertedWithCustomError(
      fairBatch,
      "TooManyOrders"
    );
  });

  it("does not allow orders after the epoch is closed", async function () {
    const price = 2500n * 1_000_000n;

    await fairBatch
      .connect(buyer)
      .submitBuy(ONE_ETH, price);

    await fairBatch.closeEpoch();

    await expect(
      fairBatch
        .connect(buyer)
        .submitBuy(ONE_ETH, price)
    ).to.be.revertedWithCustomError(
      fairBatch,
      "EpochClosed"
    );
  });

  it("selects the price with maximum executable volume", async function () {
    const buyPriceHigh = 2600n * 1_000_000n;
    const buyPriceLow = 2500n * 1_000_000n;
    const sellPriceLow = 2400n * 1_000_000n;

    await fairBatch
      .connect(buyer)
      .submitBuy(
        ONE_ETH,
        buyPriceHigh
      );

    await fairBatch
      .connect(buyer)
      .submitBuy(
        ONE_ETH,
        buyPriceLow
      );

    await fairBatch
      .connect(seller)
      .submitSell(
        ONE_ETH,
        sellPriceLow,
        { value: ONE_ETH }
      );

    await fairBatch.closeEpoch();
    await fairBatch.clearEpoch();

    const epoch = await fairBatch.epochs(1);

    expect(epoch.clearingPrice).to.equal(
      buyPriceHigh
    );
    expect(epoch.matchedVolume).to.equal(
      ONE_ETH
    );
  });

  it("uses the lower price when executable volume ties", async function () {
    const lowPrice = 2400n * 1_000_000n;
    const highPrice = 2500n * 1_000_000n;

    await fairBatch
      .connect(buyer)
      .submitBuy(
        ONE_ETH,
        lowPrice
      );

    await fairBatch
      .connect(buyer)
      .submitBuy(
        ONE_ETH,
        highPrice
      );

    await fairBatch
      .connect(seller)
      .submitSell(
        ONE_ETH,
        lowPrice,
        { value: ONE_ETH }
      );

    await fairBatch.closeEpoch();
    await fairBatch.clearEpoch();

    const epoch = await fairBatch.epochs(1);

    expect(epoch.clearingPrice).to.equal(
      lowPrice
    );
  });

  it("matches equal-sized compatible orders", async function () {
    const buyPrice = 2500n * 1_000_000n;
    const sellPrice = 2400n * 1_000_000n;

    await fairBatch
      .connect(buyer)
      .submitBuy(
        ONE_ETH,
        buyPrice
      );

    await fairBatch
      .connect(seller)
      .submitSell(
        ONE_ETH,
        sellPrice,
        { value: ONE_ETH }
      );

    await fairBatch.closeEpoch();
    await fairBatch.clearEpoch();

    const buyOrder = await fairBatch.orders(1);
    const sellOrder = await fairBatch.orders(2);

    expect(buyOrder.status).to.equal(1);
    expect(sellOrder.status).to.equal(1);
    expect(buyOrder.matchedOrderId).to.equal(2);
    expect(sellOrder.matchedOrderId).to.equal(1);
  });

  it("refunds an unmatched BUY order", async function () {
    const buyPrice = 2500n * 1_000_000n;

    await fairBatch
      .connect(buyer)
      .submitBuy(
        ONE_ETH,
        buyPrice
      );

    await fairBatch.closeEpoch();
    await fairBatch.clearEpoch();

    const before = await testUSDC.balanceOf(
      buyer.address
    );

    await fairBatch
      .connect(buyer)
      .refundOrder(1);

    const after = await testUSDC.balanceOf(
      buyer.address
    );

    expect(after - before).to.equal(
      ethers.parseUnits("2500", 6)
    );

    const order = await fairBatch.orders(1);

    expect(order.status).to.equal(3);
    expect(order.escrowedAmount).to.equal(0);
  });

  it("settles a matched pair at the clearing price", async function () {
    const buyPrice = 2500n * 1_000_000n;
    const sellPrice = 2400n * 1_000_000n;

    await fairBatch
      .connect(buyer)
      .submitBuy(
        ONE_ETH,
        buyPrice
      );

    await fairBatch
      .connect(seller)
      .submitSell(
        ONE_ETH,
        sellPrice,
        { value: ONE_ETH }
      );

    await fairBatch.closeEpoch();
    await fairBatch.clearEpoch();

    const buyerEthBefore =
      await ethers.provider.getBalance(
        buyer.address
      );

    await fairBatch
      .connect(other)
      .settleMatch(1);

    const buyerEthAfter =
      await ethers.provider.getBalance(
        buyer.address
      );

    expect(buyerEthAfter - buyerEthBefore).to.equal(
      ONE_ETH
    );

    const sellerUSDC =
      await testUSDC.balanceOf(
        seller.address
      );

    expect(sellerUSDC).to.equal(
      ethers.parseUnits("2500", 6)
    );

    const buyOrder = await fairBatch.orders(1);
    const sellOrder = await fairBatch.orders(2);

    expect(buyOrder.status).to.equal(2);
    expect(sellOrder.status).to.equal(2);
  });
});
```
