
Promise = require("bluebird");
const StableToken = artifacts.require("./StableToken.sol");
const TestnetLINK = artifacts.require("./TestnetLINK.sol");
const PiggyCompanion = artifacts.require("./PiggyCompanion.sol");
const SmartPiggies = artifacts.require("./SmartPiggies.sol");
const Resolver = artifacts.require("./ResolverSelfReturn.sol");

const expectedExceptionPromise = require("../utils/expectedException.js");
const sequentialPromise = require("../utils/sequentialPromise.js");
web3.eth.makeSureHasAtLeast = require("../utils/makeSureHasAtLeast.js");
web3.eth.makeSureAreUnlocked = require("../utils/makeSureAreUnlocked.js");
web3.eth.getTransactionReceiptMined = require("../utils/getTransactionReceiptMined.js");

if (typeof web3.eth.getAccountsPromise === "undefined") {
    Promise.promisifyAll(web3.eth, { suffix: "Promise" });
}

contract ('SmartPiggies', function(accounts) {

  let tokenInstance;
  let linkInstance;
  let piggyInstance;
  let resolverInstance;
  let owner = accounts[0];
  let user01 = accounts[1];
  let user02 = accounts[2];
  let user03 = accounts[3];
  let user04 = accounts[4];
  let user05 = accounts[5];
  let feeAddress = accounts[6];
  let addr00 = "0x0000000000000000000000000000000000000000";
  let decimal = 18;
  let decimals = web3.utils.toBN(Math.pow(10,decimal));
  let supply = web3.utils.toWei("1000", "ether");
  let approveAmount = web3.utils.toWei("100", "ether");
  let exchangeRate = 1;
  let dataSource = 'NASDAQ';
  let underlying = 'SPY';
  let oracleService = 'Self';
  let endpoint = 'https://www.nasdaq.com/symbol/spy';
  let path = '';
  let oracleTokenAddress;
  let oraclePrice = web3.utils.toBN(27000); //including hundreth of a cent
  let zeroNonce = web3.utils.toBN(0)

  /* default feePercent param = 50 */
  const DEFAULT_FEE_PERCENT = web3.utils.toBN(50);
  /* default feePercent param = 10,000 */
  const DEFAULT_FEE_RESOLUTION = web3.utils.toBN(10000);

  beforeEach(function() {
    //console.log(JSON.stringify("symbol: " + result, null, 4));
    return StableToken.new({from: owner})
    .then(instance => {
      tokenInstance = instance;
      return TestnetLINK.new({from: owner});
    })
    .then(instance => {
      linkInstance = instance;
      oracleTokenAddress = linkInstance.address;
      return Resolver.new(
        dataSource,
        underlying,
        oracleService,
        endpoint,
        path,
        oracleTokenAddress,
        oraclePrice,
        {from: owner});
    })
    .then(instance => {
      resolverInstance = instance;
      return PiggyCompanion.new({from: owner});
    })
    .then(instance => {
      helperInstance = instance;
      return SmartPiggies.new(helperInstance.address, {from: owner, gas: 8000000, gasPrice: 1100000000});
    })
    .then(instance => {
      piggyInstance = instance;

      /* setup housekeeping */
      return sequentialPromise([
        () => Promise.resolve(tokenInstance.mint(owner, supply, {from: owner})),
        () => Promise.resolve(tokenInstance.mint(user01, supply, {from: owner})),
        () => Promise.resolve(tokenInstance.mint(user02, supply, {from: owner})),
        () => Promise.resolve(tokenInstance.mint(user03, supply, {from: owner})),
        () => Promise.resolve(tokenInstance.mint(user04, supply, {from: owner})),
        () => Promise.resolve(tokenInstance.mint(user05, supply, {from: owner})),

        () => Promise.resolve(linkInstance.mint(owner, supply, {from: owner})),
        () => Promise.resolve(linkInstance.mint(user01, supply, {from: owner})),
        () => Promise.resolve(linkInstance.mint(user02, supply, {from: owner})),
        () => Promise.resolve(linkInstance.mint(user03, supply, {from: owner})),
        () => Promise.resolve(linkInstance.mint(user04, supply, {from: owner})),
        () => Promise.resolve(linkInstance.mint(user05, supply, {from: owner})),

        () => Promise.resolve(tokenInstance.approve(piggyInstance.address, approveAmount, {from: owner})),
        () => Promise.resolve(tokenInstance.approve(piggyInstance.address, approveAmount, {from: user01})),
        () => Promise.resolve(tokenInstance.approve(piggyInstance.address, approveAmount, {from: user02})),
        () => Promise.resolve(tokenInstance.approve(piggyInstance.address, approveAmount, {from: user03})),
        () => Promise.resolve(tokenInstance.approve(piggyInstance.address, approveAmount, {from: user04})),
        () => Promise.resolve(tokenInstance.approve(piggyInstance.address, approveAmount, {from: user05})),

        () => Promise.resolve(linkInstance.approve(resolverInstance.address, approveAmount, {from: owner})),
        () => Promise.resolve(linkInstance.approve(resolverInstance.address, approveAmount, {from: user01})),
        () => Promise.resolve(linkInstance.approve(resolverInstance.address, approveAmount, {from: user02})),
        () => Promise.resolve(linkInstance.approve(resolverInstance.address, approveAmount, {from: user03})),
        () => Promise.resolve(linkInstance.approve(resolverInstance.address, approveAmount, {from: user04})),
        () => Promise.resolve(linkInstance.approve(resolverInstance.address, approveAmount, {from: user05})),
        () => Promise.resolve(piggyInstance.setFeeAddress(feeAddress, {from: owner}))
      ])
    });
  });

  describe("Testing bidding functionality", function() {

    it.only("Should bid on an american call up for auction", function () {
      //American call
      collateralERC = tokenInstance.address
      dataResolver = resolverInstance.address
      collateral = web3.utils.toBN(1 * decimals)
      lotSize = web3.utils.toBN(1)
      strikePrice = web3.utils.toBN(27500) // writer wins, i.e. no payout
      expiry = 500
      isEuro = false
      isPut = false
      isRequest = false

      startPrice = web3.utils.toBN(10000)
      reservePrice = web3.utils.toBN(100)
      auctionLength = 100
      timeStep = web3.utils.toBN(1)
      priceStep = web3.utils.toBN(100)
      limitPrice = web3.utils.toBN(28000)

      startBlock = web3.utils.toBN(0)
      auctionPremium = web3.utils.toBN(0)
      eventBidPrice = web3.utils.toBN(0)

      oracleFee = web3.utils.toBN('1000000000000000000')

      serviceFee = web3.utils.toBN(0)

      params = [collateralERC,dataResolver,addr00,collateral,
        lotSize,strikePrice,expiry,isEuro,isPut,isRequest];

      tokenIds = [0,1,2,3,4,5]

      let originalBalance, spStartingBalance, spEndingBalance
      let auctionProceeds = web3.utils.toBN(0)

      // create 5 piggies, auction, and settle
      return sequentialPromise([
        () => Promise.resolve(tokenInstance.balanceOf(user01, {from: user01})),
        () => Promise.resolve(piggyInstance.getERC20Balance(user01, tokenInstance.address, {from: user01})),
        () => Promise.resolve(piggyInstance.createPiggy(params[0],params[1],params[2],params[3],
                params[4],params[5],params[6],params[7],params[8],params[9], {from: user01})),
        () => Promise.resolve(piggyInstance.startAuction(tokenIds[1],startPrice,reservePrice,
                auctionLength,timeStep,priceStep,limitPrice,true,{from: user01})),
        () => Promise.resolve(piggyInstance.bidOnPiggyAuction(tokenIds[1], oracleFee, {from: user02})), //[4]
        () => Promise.resolve(piggyInstance.getAuctionDetails(tokenIds[1], {from: user01})), //[5]
      ])
      .then(result => {
        originalBalance = result[0]
        spStartingBalance = result[1]

        assert.strictEqual(originalBalance.toString(), supply.toString(), "original token balance did not return correctly")
        assert.strictEqual(spStartingBalance.toString(), "0", "original smartpiggies erc20 balance did not return zero")

        // check events
        assert.strictEqual(result[4].logs[0].event, "BidPlaced", "bid event name did not return correctly")
        assert.strictEqual(result[4].logs[0].args.bidder, user02, "bid event param did not return correctly")
        assert.strictEqual(result[4].logs[0].args.tokenId.toNumber(), tokenIds[1], "bid event param did not return correctly")

        eventBidPrice = result[4].logs[0].args.bid
        startBlock = web3.utils.toBN(result[5].details[0])
        expiryBlock = result[5].details[1]

        return web3.eth.getBlockNumberPromise()
        .then(blockNumber => {
          if (blockNumber < expiryBlock) {
            currentBlock = web3.utils.toBN(blockNumber)
            delta = currentBlock.sub(startBlock).mul(priceStep).div(timeStep)
            auctionPremium = startPrice.sub(delta)
          } else {
              auctionPremium = reservePrice
          }
        })
      })
      .then(() => {
        spEndingBalance = collateral.add(auctionPremium)

        assert.strictEqual(eventBidPrice.toString(), auctionPremium.toString(), "bid event param did not return correctly")
        assert.strictEqual(spEndingBalance.toString(), collateral.add(auctionPremium).toString(), "sp contract balance did not update correctly")


        return sequentialPromise([
          () => Promise.resolve(piggyInstance.satisfyPiggyAuction(tokenIds[1], {from: user01})), //[0]
          () => Promise.resolve(piggyInstance.requestSettlementPrice(tokenIds[1], oracleFee, {from: user02})), // [1]
          () => Promise.resolve(piggyInstance.settlePiggy(tokenIds[1], {from: user01})), // [2]
          () => Promise.resolve(piggyInstance.getERC20Balance(user01, tokenInstance.address, {from: user01})), // [3]
          () => Promise.resolve(tokenInstance.balanceOf(user01, {from: user01})), // [4]
          () => Promise.resolve(piggyInstance.claimPayout(tokenInstance.address, spEndingBalance, {from: user01})), // [5]
          () => Promise.resolve(tokenInstance.balanceOf(user01, {from: user01})), // [6]
        ])
      })
      .then(result => {
        balanceBefore = web3.utils.toBN(result[4])
        balanceAfter = web3.utils.toBN(result[6])
        assert.strictEqual(balanceAfter.toString(), originalBalance.add(auctionPremium).toString(), "final balance did not match original balance")
          assert.strictEqual(balanceAfter.toString(), balanceBefore.add(collateral).add(auctionPremium).toString(), "token balance did not update correctly")
      })
    }); //end test

    it("Should bid on an american call up for auction", function () {
      //American call
      collateralERC = tokenInstance.address
      dataResolver = resolverInstance.address
      collateral = web3.utils.toBN(1 * decimals)
      lotSize = web3.utils.toBN(1)
      strikePrice = web3.utils.toBN(27500) // writer wins, i.e. no payout
      expiry = 500
      isEuro = false
      isPut = false
      isRequest = false

      startPrice = web3.utils.toBN(10000)
      reservePrice = web3.utils.toBN(100)
      auctionLength = 100
      timeStep = web3.utils.toBN(1)
      priceStep = web3.utils.toBN(100)

      startBlock = web3.utils.toBN(0)
      auctionPrice = web3.utils.toBN(0)

      oracleFee = web3.utils.toBN('1000000000000000000')

      serviceFee = web3.utils.toBN('0')

      params = [collateralERC,dataResolver,addr00,collateral,
        lotSize,strikePrice,expiry,isEuro,isPut,isRequest];

      tokenIds = [0,1,2,3,4,5]

      let originalBalance, spBalanceUser01, spBalanceUser02, spBalanceUser03
      let auctionProceeds = web3.utils.toBN(0)

      // create 5 piggies, auction, and settle
      return sequentialPromise([
        () => Promise.resolve(tokenInstance.balanceOf(user01, {from: user01})),

        () => Promise.resolve(piggyInstance.getERC20Balance(user01, tokenInstance.address, {from: user01})),
        () => Promise.resolve(piggyInstance.getERC20Balance(user02, tokenInstance.address, {from: user01})),
        () => Promise.resolve(piggyInstance.getERC20Balance(user03, tokenInstance.address, {from: user01})),

        () => Promise.resolve(piggyInstance.createPiggy(params[0],params[1],params[2],params[3],
                params[4],params[5],params[6],params[7],params[8],params[9], {from: user01})),
        () => Promise.resolve(piggyInstance.createPiggy(params[0],params[1],params[2],params[3],
                params[4],params[5],params[6],params[7],params[8],params[9], {from: user01})),

        () => Promise.resolve(piggyInstance.startAuction(tokenIds[1],startPrice,reservePrice,
                auctionLength,timeStep,priceStep,{from: user01})),
        () => Promise.resolve(piggyInstance.startAuction(tokenIds[2],startPrice,reservePrice,
                auctionLength,timeStep,priceStep,{from: user01})),

        () => Promise.resolve(piggyInstance.bidOnPiggyAuction(tokenIds[1], oracleFee, {from: user02})), //[8]
        () => Promise.resolve(piggyInstance.bidOnPiggyAuction(tokenIds[2], oracleFee, {from: user03})), //[9]

        () => Promise.resolve(piggyInstance.getAuctionDetails(tokenIds[1], {from: user03})), //[10]
        () => Promise.resolve(piggyInstance.getAuctionDetails(tokenIds[2], {from: user03})), //[11]

        () => Promise.resolve(piggyInstance.satisfyPiggyAuction(tokenIds[1], zeroNonce, {from: user01})), //[12]
        () => Promise.resolve(piggyInstance.satisfyPiggyAuction(tokenIds[2], zeroNonce, {from: user02})), //[13]

        () => Promise.resolve(piggyInstance.requestSettlementPrice(tokenIds[1], oracleFee, {from: user01})), // [14]
        () => Promise.resolve(piggyInstance.requestSettlementPrice(tokenIds[2], oracleFee, {from: user02})), // [15]

        () => Promise.resolve(piggyInstance.settlePiggy(tokenIds[1], {from: user01})), // [16]
        () => Promise.resolve(piggyInstance.settlePiggy(tokenIds[2], {from: user01})), // [17]

        () => Promise.resolve(piggyInstance.getERC20Balance(user01, tokenInstance.address, {from: user01})), // [18]
      ])
      .then(result => {
        // ERC20 balance accounting should be collateral from all piggies
        originalBalance = result[0]

        spBalanceUser01 = result[1]
        spBalanceUser02 = result[2]
        spBalanceUser03 = result[3]

        auctionProceeds = auctionProceeds.add(result[12].logs[1].args.paidPremium)
          .add(result[13].logs[1].args.paidPremium).add(result[14].logs[1].args.paidPremium)
          .add(result[15].logs[1].args.paidPremium).add(result[16].logs[1].args.paidPremium)

        erc20Balance = result[27]

        numOfTokens = web3.utils.toBN(tokenIds.length-1)

        assert.strictEqual(originalBalance.toString(), supply.toString(), "original token balance did not return correctly")
        assert.strictEqual(spBalanceUser01.toString(), "0", "original smartpiggies erc20 balance did not return zero")
        assert.strictEqual(spBalanceUser02.toString(), "0", "original smartpiggies erc20 balance did not return zero")
        assert.strictEqual(spBalanceUser03.toString(), "0", "original smartpiggies erc20 balance did not return zero")

        assert.strictEqual(erc20Balance.toString(), collateral.mul(numOfTokens).toString(), "writer balance did not return correctly");

        return sequentialPromise([
          () => Promise.resolve(tokenInstance.balanceOf(user01, {from: user01})),
          () => Promise.resolve(piggyInstance.claimPayout(tokenInstance.address, erc20Balance, {from: user01})),
          () => Promise.resolve(tokenInstance.balanceOf(user01, {from: user01})),
        ])
      })
      .then(result => {
        balanceBefore = web3.utils.toBN(result[0])
        balanceAfter = web3.utils.toBN(result[2])
        assert.strictEqual(balanceAfter.toString(), originalBalance.add(auctionProceeds).toString(), "final balance did not match original balance")
        assert.strictEqual(balanceAfter.toString(), balanceBefore.add(erc20Balance).toString(), "token balance did not update correctly")
      })
    }); //end test
  }); // end describe
}); // end test suite
