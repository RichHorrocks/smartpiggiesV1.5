/**
SmartPiggies is an open source standard for
a free peer to peer global derivatives market

Copyright (C) 2019, Arief, Algya, Lee

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
**/
pragma solidity 0.5.17;
pragma experimental ABIEncoderV2;

// thank you openzeppelin for SafeMath
import "./SafeMath.sol";


contract Administered {
  mapping(address => bool) private administrators;
  constructor(address _admin) public {
    administrators[_admin] = true;
  }

  modifier onlyAdmin() {
    // admin is an administrator or owner
    require(msg.sender != address(0));
    require(administrators[msg.sender]);
    _;
  }

  function isAdministrator(address _admin)
    public
    view
    returns (bool)
  {
    return administrators[_admin];
  }

  function addAdministrator(address _newAdmin)
    public
    onlyAdmin
    returns (bool)
  {
    administrators[_newAdmin] = true;
    return true;
  }

  function deleteAdministrator(address _admin)
    public
    onlyAdmin
    returns (bool)
  {
    administrators[_admin] = false;
    return true;
  }
}


contract Freezable is Administered {
  bool public notFrozen;
  constructor() public {
    notFrozen = true;
  }

  event Frozen(address indexed from);
  event Unfrozen(address indexed from);

  modifier whenNotFrozen() {
  require(notFrozen, "contract frozen");
  _;
  }

  function freeze()
    public
    onlyAdmin
    returns (bool)
  {
    notFrozen = false;
    emit Frozen(msg.sender);
    return true;
  }

  function unfreeze()
    public
    onlyAdmin
    returns (bool)
  {
    notFrozen = true;
    emit Unfrozen(msg.sender);
    return true;
  }
}


contract Serviced is Freezable {
  using SafeMath for uint256;

  address payable public feeAddress;
  uint8   public feePercent;
  uint16  public feeResolution;

  constructor(address payable _feeAddress)
    public
  {
    feeAddress = _feeAddress;
    feePercent = 50;
    feeResolution = 10**4;
  }

  function setFeeAddress(address payable _newAddress)
    public
    onlyAdmin
    returns (bool)
  {
    feeAddress = _newAddress;
    return true;
  }

  function setFeePercent(uint8 _newFee)
    public
    onlyAdmin
    returns (bool)
  {
    feePercent = _newFee;
    return true;
  }

  function setFeeResolution(uint16 _newResolution)
    public
    onlyAdmin
    returns (bool)
  {
    require(_newResolution != 0);
    feeResolution = _newResolution;
    return true;
  }

  function _getFee(uint256 _value)
    internal
    view
    returns (uint256)
  {
    uint256 fee = _value.mul(feePercent).div(feeResolution);
    return fee;
  }
}


contract UsingCooldown is Serviced {
  uint256 public cooldown;
  uint256 public bidCooldown;

  constructor()
    public
  {
    // 4blks/min * 60 min/hr * 24hrs/day * # days
    cooldown = 3 days; // 17280; default 3 days
    bidCooldown = 1 days;
  }

  function setCooldown(uint256 _newCooldown)
    public
    onlyAdmin
    returns (bool)
  {
    cooldown = _newCooldown;
    return true;
  }

  function setBidCooldown(uint256 _newCooldown)
    public
    onlyAdmin
    returns (bool)
  {
    bidCooldown = _newCooldown;
    return true;
  }
}


contract UsingACompanion is UsingCooldown {
  address public companionAddress;

  function setHelper(address _newAddress)
    public
    onlyAdmin
    returns (bool)
  {
    companionAddress = _newAddress;
    return true;
  }
}


contract UsingConstants is UsingACompanion {
  /** Auction Detail
   *  details[0] - Start Block
   *  details[1] - Expiry Block
   *  details[2] - Start Price
   *  details[3] - Reserve Price
   *  details[4] - Time Step
   *  details[5] - Price Step
   *  details[6] - Limit Bid
   *  details[7] - Oracle Price
   *  details[8] - Auction Premium
   *  details[9] - Cooldown Period
   *  address    - Active Bidding Account
   *  uint8      - RFP Nonce
   *  flags[0]   - Auction Active
   *  flags[1]   - Bid Limit Set
   *  flags[2]   - Bid Cleared
   *  flags[3]   - Satisfy In Progress
  */
  uint8 constant START_BLOCK     = 0;
  uint8 constant EXPIRY_BLOCK    = 1;
  uint8 constant START_PRICE     = 2;
  uint8 constant RESERVE_PRICE   = 3;
  uint8 constant TIME_STEP       = 4;
  uint8 constant PRICE_STEP      = 5;
  uint8 constant LIMIT_PRICE     = 6;
  uint8 constant ORACLE_PRICE    = 7;
  uint8 constant AUCTION_PREMIUM = 8;
  uint8 constant COOLDOWN       = 9;

  uint8 constant AUCTION_ACTIVE     = 0;
  uint8 constant BID_LIMIT_SET       = 1;
  uint8 constant BID_CLEARED        = 2;
  uint8 constant SATISFY_IN_PROGRESS = 3; // mutex guard to disallow ending an auction if a transaction to satisfy is in progress
}


/** @title SmartPiggies: A Smart Option Standard
*/
contract SmartPiggies is UsingConstants {
  using SafeMath for uint256;

  enum RequestType { Bid, Settlement }
  bytes32 constant RTN_FALSE = bytes32(0x0000000000000000000000000000000000000000000000000000000000000000);
  bytes32 constant TX_SUCCESS = bytes32(0x0000000000000000000000000000000000000000000000000000000000000001);
  uint256 public tokenId;

  /**
   * @title Helps contracts guard against reentrancy attacks.
   * @author Remco Bloemen <remco@2π.com>, Eenae <alexey@mixbytes.io>
   * @dev If you mark a function `nonReentrant`, you should also
   * mark it `external`.
   */
  uint256 private _guardCounter;

  struct DetailAccounts {
    address writer;
    address holder;
    address collateralERC;
    address dataResolver;
    address arbiter;
    address writerProposedNewArbiter;
    address holderProposedNewArbiter;
  }

  struct DetailUints {
    uint256 collateral;
    uint256 lotSize;
    uint256 strikePrice;
    uint256 expiry;
    uint256 settlementPrice; //04.20.20 oil price is negative :9
    uint256 reqCollateral;
    uint256 arbitrationLock;
    uint256 writerProposedPrice;
    uint256 holderProposedPrice;
    uint256 arbiterProposedPrice;
    uint8 collateralDecimals;  // store decimals from ERC-20 contract
    uint8 rfpNonce;
  }

  struct BoolFlags {
    bool isRequest;
    bool isEuro;
    bool isPut;
    bool hasBeenCleared;  // flag whether the oracle returned a callback w/ price
    bool writerHasProposedNewArbiter;
    bool holderHasProposedNewArbiter;
    bool writerHasProposedPrice;
    bool holderHasProposedPrice;
    bool arbiterHasProposedPrice;
    bool arbiterHasConfirmed;
    bool arbitrationAgreement;
  }

  struct DetailAuction {
    uint256[10] details;
    address activeBidder;
    uint8 rfpNonce;
    bool[4] flags;
  }

  struct Piggy {
    DetailAccounts accounts; // address details
    DetailUints uintDetails; // number details
    BoolFlags flags; // parameter switches
  }

  mapping (address => mapping(address => uint256)) private ERC20Balances;
  mapping (address => mapping(uint256 => uint256)) private bidBalances;
  mapping (address => uint256[]) private ownedPiggies;
  mapping (uint256 => uint256) private ownedPiggiesIndex;
  mapping (uint256 => Piggy) private piggies;
  mapping (uint256 => DetailAuction) private auctions;

  /** Events
  */

  event CreatePiggy(
    address[] accounts,
    uint256[] ints,
    bool[] bools
  );

  event TransferPiggy(
    address indexed from,
    address indexed to,
    uint256 indexed tokenId
  );

  event UpdateRFP(
    address indexed from,
    uint256 indexed tokenId,
    uint8 indexed rfpNonce,
    address collateralERC,
    address dataResolver,
    address arbiter,
    uint256 reqCollateral,
    uint256 lotSize,
    uint256 strikePrice,
    uint256 expiry,
    bool isEuro,
    bool isPut
  );

  event ReclaimAndBurn(
    address indexed from,
    uint256 indexed tokenId,
    bool indexed RFP
  );

  event StartAuction(
    address indexed from,
    uint256 indexed tokenId,
    uint256 startPrice,
    uint256 reservePrice,
    uint256 auctionLength,
    uint256 timeStep,
    uint256 priceStep
  );

  event BidPlaced(
    address indexed bidder,
    uint256 indexed tokenId,
    uint256 indexed bid
  );

  event EndAuction(
    address indexed from,
    uint256 indexed tokenId,
    bool indexed RFP
  );

  event SatisfyAuction(
    address indexed from,
    uint256 indexed tokenId,
    uint256 paidPremium,
    uint256 change,
    uint256 auctionPremium
  );

  event RequestSettlementPrice(
    address indexed feePayer,
    uint256 indexed tokenId,
    uint256 oracleFee,
    address dataResolver
  );

  event OracleReturned(
    address indexed resolver,
    uint256 indexed tokenId,
    uint256 indexed price,
    uint8 requestType
  );

  event SettlePiggy(
   address indexed from,
   uint256 indexed tokenId,
   uint256 indexed holderPayout,
   uint256 writerPayout
  );

  event ClaimPayout(
    address indexed from,
    uint256 indexed amount,
    address indexed paymentToken
  );

  event ProposalRequest(
    address indexed from,
    uint256 indexed tokenId,
    uint256 indexed proposalAmount
  );

  event ArbiterSet(
    address indexed from,
    address indexed arbiter,
    uint256 indexed tokenId
  );

  event ArbiterConfirmed(
    address indexed arbiter,
    uint256 indexed tokenId
  );

  event PriceProposed(
    address indexed from,
    uint256 indexed tokenId,
    uint256 indexed proposedPrice
  );

  event ArbiterSettled(
    address indexed from,
    address arbiter,
    uint256 indexed tokenId,
    uint256 indexed exercisePrice
  );

  /**
    constructor should throw if various things aren't properly set
    also should throw if the contract is not delegated an amount of collateral designated
    in the reference ERC-20 which is >= the collateral value of the piggy
  */
  constructor(address _companion)
    public
    Administered(msg.sender)
    Serviced(msg.sender)
  {
    //declarations here
    companionAddress = _companion;
    _guardCounter = 1;
  }

  modifier nonReentrant() {
    // guard counter should be allowed to overflow
    _guardCounter += 1;
    uint256 localCounter = _guardCounter;
    _;
    require(localCounter == _guardCounter, "re-entered");
  }

  /** @notice Create a new token
      @param _collateralERC The address of the reference ERC-20 token to be used as collateral
      param _dataResolver The address of a service contract which will return the settlement price
      @param _collateral The amount of collateral for the option, denominated in units of the token
       at the `_collateralERC` address
      @param _lotSize A multiplier on the settlement price used to determine settlement claims
      @param _strikePrice The strike value of the option, in the same units as the settlement price
      @param _expiry The block height at which the option will expire
      @param _isEuro If true, the option can only be settled at or after `_expiry` is reached, else
       it can be settled at any time
      @param _isPut If true, the settlement claims will be calculated for a put option; else they
       will be calculated for a call option
      @param _isRequest If true, will create the token as an "RFP" / request for a particular option
  */
  function createPiggy(
    address _collateralERC,
    address _dataResolver,
    address _arbiter,
    uint256 _collateral,
    uint256 _lotSize,
    uint256 _strikePrice,
    uint256 _expiry,
    bool _isEuro,
    bool _isPut,
    bool _isRequest
  )
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    require(
      _collateralERC != address(0) &&
      _dataResolver != address(0),
      "address cannot be zero"
    );
    require(
      _collateral != 0 &&
      _lotSize != 0 &&
      _strikePrice != 0 &&
      _expiry != 0,
      "parameter cannot be zero"
    );

    require(
      _constructPiggy(
        _collateralERC,
        _dataResolver,
        _arbiter,
        _collateral,
        _lotSize,
        _strikePrice,
        _expiry,
        0,
        _isEuro,
        _isPut,
        _isRequest,
        false
      ),
      "create failed"
    );

    // *** warning untrusted function call ***
    // if not an RFP, make sure the collateral can be transferred
    if (!_isRequest) {
      (bool success, bytes memory result) = attemptPaymentTransfer(
        _collateralERC,
        msg.sender,
        address(this),
        _collateral
      );
      bytes32 txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");
    }

    return true;
  }

  /**
   * This will destroy the piggy and create two new piggies
   * the first created piggy will get the collateral less the amount
   * the second piggy will get the specified amount as collateral
   */
  function splitPiggy(
    uint256 _tokenId,
    uint256 _amount
  )
    public
    whenNotFrozen
    returns (bool)
  {
    require(_tokenId != 0, "tokenId cannot be zero");
    require(_amount != 0, "amount cannot be zero");
    require(_amount < piggies[_tokenId].uintDetails.collateral, "amount must be less than collateral");
    require(!piggies[_tokenId].flags.isRequest, "cannot be an RFP");
    require(piggies[_tokenId].uintDetails.collateral > 0, "collateral must be greater than zero");
    require(piggies[_tokenId].accounts.holder == msg.sender, "only holder can split");
    require(block.number < piggies[_tokenId].uintDetails.expiry, "cannot split expired token");
    require(!auctions[_tokenId].flags[AUCTION_ACTIVE], "auction active");
    require(!piggies[_tokenId].flags.hasBeenCleared, "piggy cleared");

    // assuming all checks have passed:

    // remove current token ID
    _removeTokenFromOwnedPiggies(msg.sender, _tokenId); // i.e. piggies[_tokenId].addresses.holder

    require(
      _constructPiggy(
        piggies[_tokenId].accounts.collateralERC,
        piggies[_tokenId].accounts.dataResolver,
        piggies[_tokenId].accounts.arbiter,
        piggies[_tokenId].uintDetails.collateral.sub(_amount), // piggy with collateral less the amount
        piggies[_tokenId].uintDetails.lotSize,
        piggies[_tokenId].uintDetails.strikePrice,
        piggies[_tokenId].uintDetails.expiry,
        _tokenId,
        piggies[_tokenId].flags.isEuro,
        piggies[_tokenId].flags.isPut,
        false, // piggies[tokenId].flags.isRequest
        true // split piggy
      ),
      "create failed"
    ); // require this to succeed or revert, i.e. do not reset

    require(
      _constructPiggy(
        piggies[_tokenId].accounts.collateralERC,
        piggies[_tokenId].accounts.dataResolver,
        piggies[_tokenId].accounts.arbiter,
        _amount,
        piggies[_tokenId].uintDetails.lotSize,
        piggies[_tokenId].uintDetails.strikePrice,
        piggies[_tokenId].uintDetails.expiry,
        _tokenId,
        piggies[_tokenId].flags.isEuro,
        piggies[_tokenId].flags.isPut,
        false, //piggies[tokenId].isRequest
        true //split piggy
      ),
      "create failed"
    ); // require this to succeed or revert, i.e. do not reset

    //clean up piggyId
    _resetPiggy(_tokenId);

    return true;
  }

  function transferFrom(address _from, address _to, uint256 _tokenId)
    public
  {
    require(msg.sender == piggies[_tokenId].accounts.holder, "sender must be holder");
    _internalTransfer(_from, _to, _tokenId);
  }

  function updateRFP(
    uint256 _tokenId,
    address _collateralERC,
    address _dataResolver,
    address _arbiter,
    uint256 _reqCollateral,
    uint256 _lotSize,
    uint256 _strikePrice,
    uint256 _expiry,
    bool _isEuro,  // MUST be specified
    bool _isPut    // MUST be specified
  )
    public
    whenNotFrozen
    returns (bool)
  {
    bytes memory payload = abi.encodeWithSignature("updateRFP(uint256,address,address,address,uint256,uint256,uint256,uint256,bool,bool)",
      _tokenId,_collateralERC,_dataResolver,_arbiter,
      _reqCollateral,_lotSize,_strikePrice,_expiry,
      _isEuro,_isPut);
    (bool success, bytes memory result) = address(companionAddress).delegatecall(payload);
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "update rfp failed");
    return true;
  }

  /** this function can be used to burn any token;
      if it is not an RFP, will return collateral before burning
  */
  function reclaimAndBurn(uint256 _tokenId)
    external
    nonReentrant
    returns (bool)
  {
    require(msg.sender == piggies[_tokenId].accounts.holder, "sender must be holder");
    require(!auctions[_tokenId].flags[AUCTION_ACTIVE], "auction active");

    if (!piggies[_tokenId].flags.isRequest) {
      require(msg.sender == piggies[_tokenId].accounts.writer, "sender must own collateral");

      // keep collateralERC address
      address collateralERC = piggies[_tokenId].accounts.collateralERC;
      // keep collateral
      uint256 collateral = piggies[_tokenId].uintDetails.collateral;

      ERC20Balances[msg.sender][collateralERC] = ERC20Balances[msg.sender][collateralERC].add(collateral);
    }
    emit ReclaimAndBurn(msg.sender, _tokenId, piggies[_tokenId].flags.isRequest);
    // remove id from index mapping
    _removeTokenFromOwnedPiggies(piggies[_tokenId].accounts.holder, _tokenId);
    // burn the token (zero out storage fields)
    _resetPiggy(_tokenId);
    return true;
  }

  function startAuction(
    uint256 _tokenId,
    uint256 _startPrice,
    uint256 _reservePrice,
    uint256 _auctionLength,
    uint256 _timeStep,
    uint256 _priceStep,
    uint256 _limitPrice,
    bool _bidLimitSet
  )
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    uint256 _auctionExpiry = block.number.add(_auctionLength);
    require(piggies[_tokenId].accounts.holder == msg.sender, "sender must be holder");
    require(piggies[_tokenId].uintDetails.expiry > block.number, "piggy expired");
    require(piggies[_tokenId].uintDetails.expiry > _auctionExpiry, "auction cannot expire after token expiry");
    require(!piggies[_tokenId].flags.hasBeenCleared, "piggy cleared");
    require(!auctions[_tokenId].flags[AUCTION_ACTIVE], "auction active");

    // if we made it past the various checks, set the auction metadata up in auctions mapping
    auctions[_tokenId].details[START_BLOCK] = block.number;
    auctions[_tokenId].details[EXPIRY_BLOCK] = _auctionExpiry;
    auctions[_tokenId].details[START_PRICE] = _startPrice;
    auctions[_tokenId].details[RESERVE_PRICE] = _reservePrice;
    auctions[_tokenId].details[TIME_STEP] = _timeStep;
    auctions[_tokenId].details[PRICE_STEP] = _priceStep;
    auctions[_tokenId].flags[AUCTION_ACTIVE] = true;

    if (_bidLimitSet) {
      auctions[_tokenId].details[LIMIT_PRICE] = _limitPrice;
      auctions[_tokenId].flags[BID_LIMIT_SET] = true;
    }

    if (piggies[_tokenId].flags.isRequest) {
      // *** warning untrusted function call ***
      (bool success, bytes memory result) = attemptPaymentTransfer(
        piggies[_tokenId].accounts.collateralERC,
        msg.sender,
        address(this),
        _reservePrice  // this should be the max the requestor is willing to pay in a reverse dutch auction
      );
      bytes32 txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");
    }

    emit StartAuction(
      msg.sender,
      _tokenId,
      _startPrice,
      _reservePrice,
      _auctionLength,
      _timeStep,
      _priceStep
    );

    return true;
  }

  function endAuction(uint256 _tokenId)
    external
    nonReentrant
    returns (bool)
  {
    require(msg.sender == piggies[_tokenId].accounts.holder, "sender must be holder");
    require(auctions[_tokenId].flags[AUCTION_ACTIVE], "auction not active");
    require(!auctions[_tokenId].flags[SATISFY_IN_PROGRESS], "auction is being satisfied");  // this should be added to other functions as well

    // set to reserve for RFP
    uint256 premiumToReturn = auctions[_tokenId].details[RESERVE_PRICE];
    address bidder = auctions[_tokenId].activeBidder;
    address collateralERC = piggies[_tokenId].accounts.collateralERC;

    if (bidder != address(0)) {
      if (piggies[_tokenId].flags.isRequest) {

        // reset bidding balances
        bidBalances[bidder][_tokenId] = 0;
        bidBalances[msg.sender][_tokenId] = 0;

        // return requested collateral to filler
        ERC20Balances[bidder][collateralERC] =
          ERC20Balances[bidder][collateralERC].add(piggies[_tokenId].uintDetails.reqCollateral);

        // if RFP get back your reserve
        ERC20Balances[msg.sender][collateralERC] =
          ERC20Balances[msg.sender][collateralERC].add(premiumToReturn);

      }
      // not RFP, return auction premium to bidder
      else {
        // reset premiumToReturn to bid balance
        premiumToReturn = auctions[_tokenId].details[AUCTION_PREMIUM]; // <- make this: auctions[_tokenId].details[8]
        bidBalances[bidder][_tokenId] = 0;
        //return auction premium to bidder
        ERC20Balances[bidder][collateralERC] =
          ERC20Balances[bidder][collateralERC].add(premiumToReturn);
      }
    }
    else if (piggies[_tokenId].flags.isRequest) {
      // refund the reserve price premium
      ERC20Balances[msg.sender][collateralERC] =
        ERC20Balances[msg.sender][collateralERC].add(premiumToReturn);
    }

    _clearAuctionDetails(_tokenId);
    emit EndAuction(msg.sender, _tokenId, piggies[_tokenId].flags.isRequest);
    return true;
  }

  function bidOnPiggyAuction(
    uint256 _tokenId,
    uint256 _oralceFee
  )
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    // require token on auction
    require(auctions[_tokenId].flags[AUCTION_ACTIVE], "auction must be running");
    require(msg.sender != piggies[_tokenId].accounts.holder, "cannot bid on your auction");
    require(!auctions[_tokenId].flags[SATISFY_IN_PROGRESS], "auction is being satisfied");
    //require(!auctions[_tokenId].flags[2], "auction bidding locked");
    require(auctions[_tokenId].activeBidder == address(0), "auction bidding locked");

    // set bidder
    auctions[_tokenId].activeBidder = msg.sender;
    // lock bidding
    //auctions[_tokenId].flags[2] = true;
    // set cooldown
    auctions[_tokenId].details[COOLDOWN] = block.number.add(bidCooldown);

    // get linear auction premium; reserve price should be a ceiling or floor depending on whether this is an RFP or an option, respectively
    // calculate the adjusted premium based on reservePrice
    uint256 adjPremium = _getAuctionPrice(_tokenId);
    if (adjPremium < auctions[_tokenId].details[RESERVE_PRICE]) {
      adjPremium = auctions[_tokenId].details[RESERVE_PRICE];
    }

    // save auction premium paid
    auctions[_tokenId].details[AUCTION_PREMIUM] = adjPremium;
    // update bidder's balance
    bidBalances[msg.sender][_tokenId] = bidBalances[msg.sender][_tokenId].add(adjPremium);

    // *** warning untrusted function call ***
    // msg.sender pays (adjusted) premium
    (bool success, bytes memory result) = attemptPaymentTransfer(
      piggies[_tokenId].accounts.collateralERC,
      msg.sender,
      address(this),
      adjPremium
    );
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "token transfer failed");

    emit BidPlaced(msg.sender, _tokenId, adjPremium);
    checkLimitPrice(_tokenId, _oralceFee);
    return true;
  }

  function bidOnRequestAuction(
    uint256 _tokenId,
    uint256 _oralceFee
  )
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    // require token on auction
    require(auctions[_tokenId].flags[AUCTION_ACTIVE], "auction must be running");
    require(msg.sender != piggies[_tokenId].accounts.holder, "cannot bid on your auction");
    require(!auctions[_tokenId].flags[SATISFY_IN_PROGRESS], "auction is being satisfied");
    require(auctions[_tokenId].activeBidder == address(0), "auction bidding locked"); // if address is not zero, bid is active

    // set bidder
    auctions[_tokenId].activeBidder = msg.sender; // used to check that bidding is locked
    // set cooldown
    auctions[_tokenId].details[COOLDOWN] = block.number.add(bidCooldown);
    // record current RFP nonce
    auctions[_tokenId].rfpNonce = piggies[_tokenId].uintDetails.rfpNonce;

    // get linear auction premium; reserve price should be a ceiling or floor depending on whether this is an RFP or an option, respectively
    uint256 adjPremium = _getAuctionPrice(_tokenId);
    uint256 change = 0;

    // set bidder's balance to collateral sent to contract to collateralize piggy
    bidBalances[msg.sender][_tokenId] = piggies[_tokenId].uintDetails.reqCollateral;

    // calculate adjusted premium (based on reservePrice) + possible change due back to current holder
    if (adjPremium > auctions[_tokenId].details[RESERVE_PRICE]) {
      adjPremium = auctions[_tokenId].details[RESERVE_PRICE];
    } else {
      change = auctions[_tokenId].details[RESERVE_PRICE].sub(adjPremium);
    }
    // update bidder's balance with owed premium
    bidBalances[msg.sender][_tokenId] = bidBalances[msg.sender][_tokenId].add(adjPremium);

    // set current holder's balance with the change
    bidBalances[piggies[_tokenId].accounts.holder][_tokenId] = change;

    // save auction premium paid
    auctions[_tokenId].details[AUCTION_PREMIUM] = adjPremium;

    // *** warning untrusted function call ***
    // msg.sender needs to delegate reqCollateral
    (bool success, bytes memory result) = attemptPaymentTransfer(
      piggies[_tokenId].accounts.collateralERC,
      msg.sender,
      address(this),
      piggies[_tokenId].uintDetails.reqCollateral
    );
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "token transfer failed");

    emit BidPlaced(msg.sender, _tokenId, adjPremium);
    checkLimitPrice(_tokenId, _oralceFee);
    return true;
  }

  function reclaimBid(uint256 _tokenId)
    external
    returns (bool)
  {
    address bidder = auctions[_tokenId].activeBidder;
    // sender must be bidder on auction, implicit check that bid is locked
    require(msg.sender == bidder, "sender not bidder");
    // can't run this is the oracle returned
    require(!auctions[_tokenId].flags[BID_CLEARED], "bid cleared");
    // past cooldown
    require(auctions[_tokenId].details[COOLDOWN] < block.number, "cooldown still active");

    uint256 returnAmount;
    address collateralERC = piggies[_tokenId].accounts.collateralERC;

    //if RFP bidder gets reqested collateral back, holder gets reserve back
    if (piggies[_tokenId].flags.isRequest) {
      // return requested collateral to filler
      returnAmount = piggies[_tokenId].uintDetails.reqCollateral;
      bidBalances[bidder][_tokenId] = 0;

      ERC20Balances[bidder][collateralERC] =
      ERC20Balances[bidder][collateralERC].add(returnAmount);

      // return reserve to holder
      address holder = piggies[_tokenId].accounts.holder;
      returnAmount = auctions[_tokenId].details[RESERVE_PRICE];
      bidBalances[holder][_tokenId] = 0;

      ERC20Balances[holder][collateralERC] =
      ERC20Balances[holder][collateralERC].add(returnAmount);
    }
    else {
      // refund the _reservePrice premium
      returnAmount = auctions[_tokenId].details[AUCTION_PREMIUM];
      bidBalances[msg.sender][_tokenId] = 0;

      ERC20Balances[msg.sender][collateralERC] =
      ERC20Balances[msg.sender][collateralERC].add(returnAmount);
    }

    // clean up token bid
    _clearBid(_tokenId);

    return true;
  }

  function satisfyPiggyAuction(uint256 _tokenId)
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    require(!auctions[_tokenId].flags[SATISFY_IN_PROGRESS], "auction is being satisfied"); // mutex MUST be first
    require(auctions[_tokenId].flags[AUCTION_ACTIVE], "auction must be active to satisfy");
    //use satisfyRFPAuction for RFP auctions
    require(!piggies[_tokenId].flags.isRequest, "cannot satisfy auction; check piggy type");

    // if auction is "active" according to state but has expired, change state
    if (auctions[_tokenId].details[EXPIRY_BLOCK] < block.number) {
      _clearAuctionDetails(_tokenId);
      return false;
    }

    // lock mutex
    auctions[_tokenId].flags[SATISFY_IN_PROGRESS] = true;

    uint256 auctionPremium = 0;
    uint256 adjPremium = 0;
    address previousHolder = piggies[_tokenId].accounts.holder;

    if (auctions[_tokenId].flags[BID_LIMIT_SET]) {
      require(auctions[_tokenId].flags[BID_CLEARED], "auction must receive price check");

      // check price limit condition
      _checkBidPrice(
        piggies[_tokenId].flags.isPut,
        auctions[_tokenId].details[LIMIT_PRICE],
        auctions[_tokenId].details[ORACLE_PRICE]
      );

      // bidder becomes holder
      _internalTransfer(previousHolder, auctions[_tokenId].activeBidder, _tokenId);

      // included for event logging
      adjPremium = auctions[_tokenId].details[AUCTION_PREMIUM];
      // update bidder's balance
      bidBalances[auctions[_tokenId].activeBidder][_tokenId] = 0;

      // optimistic clean up assuming no revert
      _clearAuctionDetails(_tokenId);

      address collateralERC = piggies[_tokenId].accounts.collateralERC;

      // previous holder/writer receives (adjusted) auction premium
      ERC20Balances[previousHolder][collateralERC] =
      ERC20Balances[previousHolder][collateralERC].add(adjPremium);

    }
    // auction didn't go through a bidding process
    else {
      // can't satisfy your own auction
      require(msg.sender != piggies[_tokenId].accounts.holder, "cannot satisfy your auction; use endAuction");

      auctionPremium = _getAuctionPrice(_tokenId);
      adjPremium = auctionPremium;

      if (adjPremium < auctions[_tokenId].details[RESERVE_PRICE]) {
        adjPremium = auctions[_tokenId].details[RESERVE_PRICE];
      }

      // msg.sender becomes holder
      _internalTransfer(previousHolder, msg.sender, _tokenId);

      // optimistic clean up assuming no revert
      _clearAuctionDetails(_tokenId);

      // *** warning untrusted function call ***
      // msg.sender pays (adjusted) premium
      (bool success, bytes memory result) = attemptPaymentTransfer(
        piggies[_tokenId].accounts.collateralERC,
        msg.sender,
        previousHolder,
        adjPremium
      );
      bytes32 txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");
    }

      emit SatisfyAuction(
        msg.sender,
        _tokenId,
        adjPremium,
        0,
        auctionPremium
      );

    // mutex released
    auctions[_tokenId].flags[SATISFY_IN_PROGRESS] = false;
    return true;
  }

  function satisfyRFPBidAuction(uint256 _tokenId)
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    require(!auctions[_tokenId].flags[SATISFY_IN_PROGRESS], "auction is being satisfied"); // mutex MUST be first
    require(auctions[_tokenId].flags[AUCTION_ACTIVE], "auction must be active to satisfy");
    //use satisfyPiggyAuction for piggy auctions
    require(piggies[_tokenId].flags.isRequest, "cannot satisfy auction; check piggy type");
    require(auctions[_tokenId].flags[BID_LIMIT_SET], "bid auction not set");
    require(auctions[_tokenId].flags[BID_CLEARED], "auction must receive price check");
    // make sure current rfpNonce matches rfpNonce for bid
    require(piggies[_tokenId].uintDetails.rfpNonce == auctions[_tokenId].rfpNonce, "RFP Nonce failed match");

    // if auction is "active" according to state but has expired, change state
    if (auctions[_tokenId].details[EXPIRY_BLOCK] < block.number) {
      _clearAuctionDetails(_tokenId);
      return false;
    }

    // check price limit condition
    _checkBidPrice(
      piggies[_tokenId].flags.isPut,
      auctions[_tokenId].details[LIMIT_PRICE],
      auctions[_tokenId].details[ORACLE_PRICE]
    );

    // lock mutex
    auctions[_tokenId].flags[SATISFY_IN_PROGRESS] = true;

    uint256 adjPremium;
    //uint256 change;
    address holder = piggies[_tokenId].accounts.holder;
    uint256 reserve = auctions[_tokenId].details[RESERVE_PRICE];
    address bidder = auctions[_tokenId].activeBidder;

    // collateral transfer SHOULD succeed, reqCollateral gets set to collateral
    piggies[_tokenId].uintDetails.collateral = piggies[_tokenId].uintDetails.reqCollateral;
    // isRequest becomes false
    piggies[_tokenId].flags.isRequest = false;


    // active bidder becomes writer
    piggies[_tokenId].accounts.writer = bidder;

    adjPremium = auctions[_tokenId].details[AUCTION_PREMIUM];

    // update bidBalances:
    // requested collateral moves to collateral, adjusted premium -> bidder
    bidBalances[bidder][_tokenId] = 0;
    // holder's premium -> bidder
    bidBalances[holder][_tokenId] = 0; // was -> bidBalances[holder][_tokenId].sub(adjPremium)

    // current holder pays premium (via amount already delegated to this contract in startAuction)
    address collateralERC = piggies[_tokenId].accounts.collateralERC;
    ERC20Balances[bidder][collateralERC] =
      ERC20Balances[bidder][collateralERC].add(adjPremium);

    // return any change to current holder
    if(adjPremium < reserve) {
      // return any change during the bidding process
      ERC20Balances[holder][collateralERC] =
        ERC20Balances[holder][collateralERC].add(reserve.sub(adjPremium));
    }

    emit SatisfyAuction(
      msg.sender,
      _tokenId,
      adjPremium,
      reserve.sub(adjPremium), // change
      adjPremium // ???
    );

    // mutex released
    auctions[_tokenId].flags[SATISFY_IN_PROGRESS] = false;
    _clearAuctionDetails(_tokenId);
    return true;
  }

  function satisfyRFPSpotAuction(uint256 _tokenId, uint8 _rfpNonce)
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    require(!auctions[_tokenId].flags[SATISFY_IN_PROGRESS], "auction is being satisfied");
    require(msg.sender != piggies[_tokenId].accounts.holder, "cannot satisfy your auction; use endAuction");
    require(auctions[_tokenId].flags[AUCTION_ACTIVE], "auction must be active to satisfy");

    //use satisfyPiggyAuction for piggy auctions
    require(piggies[_tokenId].flags.isRequest, "cannot satisfy auction; check piggy type");

    // if auction is "active" according to state but has expired, change state
    if (auctions[_tokenId].details[EXPIRY_BLOCK] < block.number) {
      _clearAuctionDetails(_tokenId);
      return false;
    }

    // lock mutex
    auctions[_tokenId].flags[SATISFY_IN_PROGRESS] = true;

    uint256 adjPremium;
    uint256 change;

    // collateral transfer SHOULD succeed, reqCollateral gets set to collateral
    piggies[_tokenId].uintDetails.collateral = piggies[_tokenId].uintDetails.reqCollateral;
    // isRequest becomes false
    piggies[_tokenId].flags.isRequest = false;

    // auction didn't go through a bidding process

    // make sure rfpNonce matches
    require(_rfpNonce == piggies[_tokenId].uintDetails.rfpNonce, "RFP Nonce failed match");

    // msg.sender becomes writer
    piggies[_tokenId].accounts.writer = msg.sender;

    adjPremium = _getAuctionPrice(_tokenId);

    // calculate adjusted premium (based on reservePrice) + possible change due back to current holder
    if (adjPremium > auctions[_tokenId].details[RESERVE_PRICE]) {
      adjPremium = auctions[_tokenId].details[RESERVE_PRICE];
    } else {
      change = auctions[_tokenId].details[RESERVE_PRICE].sub(adjPremium);
    }

    address collateralERC = piggies[_tokenId].accounts.collateralERC;

    // *** warning untrusted function call ***
    // msg.sender needs to delegate reqCollateral
    (bool success, bytes memory result) = attemptPaymentTransfer(
      collateralERC,
      msg.sender,
      address(this),
      piggies[_tokenId].uintDetails.reqCollateral
    );
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "token transfer failed");

    // current holder pays premium (via amount already delegated to this contract in startAuction)
    ERC20Balances[msg.sender][collateralERC] =
      ERC20Balances[msg.sender][collateralERC].add(adjPremium);

    // current holder receives any change due
    if (change > 0) {
      address holder = piggies[_tokenId].accounts.holder;
      ERC20Balances[holder][collateralERC] =
        ERC20Balances[holder][collateralERC].add(change);
    }

    emit SatisfyAuction(
      msg.sender,
      _tokenId,
      adjPremium,
      change,
      adjPremium.add(change)
    );

    // mutex released
    auctions[_tokenId].flags[SATISFY_IN_PROGRESS] = false;
    _clearAuctionDetails(_tokenId);
    return true;
  }

  /** @notice Call the oracle to fetch the settlement price
      @dev Throws if `_tokenId` is not a valid token.
       Throws if `_oracle` is not a valid contract address.
       Throws if `onMarket(_tokenId)` is true.
       If `isEuro` is true for the specified token, throws if `_expiry` > block.number.
       If `isEuro` is true for the specified token, throws if `_priceNow` is true. [OR specify that it flips that to false always (?)]
       If `priceNow` is true, throws if block.number > `_expiry` for the specified token.
       If `priceNow` is false, throws if block.number < `_expiry` for the specified token.
       If `priceNow` is true, calls the oracle to request the `_underlyingNow` value for the token.
       If `priceNow` is false, calls the oracle to request the `_underlyingExpiry` value for the token.
       Depending on the oracle service implemented, additional state will need to be referenced in
       order to call the oracle, e.g. an endpoint to fetch. This state handling will need to be
       managed on an implementation basis for specific oracle services.
      @param _tokenId The identifier of the token
      @param _oracleFee Fee paid to oracle service
        A value needs to be provided for this function to succeed
        If the oracle doesn't need payment, include a positive garbage value
      @return The settlement price from the oracle to be used in `settleOption()`
   */
  function requestSettlementPrice(uint256 _tokenId, uint256 _oracleFee)
    external
    nonReentrant
    returns (bool)
  {
    require(msg.sender != address(0));
    require(!auctions[_tokenId].flags[AUCTION_ACTIVE], "auction active");
    require(!piggies[_tokenId].flags.hasBeenCleared, "piggy cleared");
    require(_tokenId != 0, "tokenId cannot be zero");

    // check if Euro require past expiry
    if (piggies[_tokenId].flags.isEuro) {
      require(piggies[_tokenId].uintDetails.expiry <= block.number, "cannot request price for European before expiry");
    }
    // check if American and less than expiry, only holder can call
    if (!piggies[_tokenId].flags.isEuro && (block.number < piggies[_tokenId].uintDetails.expiry))
    {
      require(msg.sender == piggies[_tokenId].accounts.holder, "only holder can settle American before expiry");
    }

    address dataResolver = piggies[_tokenId].accounts.dataResolver;
    uint8 request = uint8 (RequestType.Settlement);
    bytes memory payload = abi.encodeWithSignature(
      "fetchData(address,uint256,uint256,uint8)",
      msg.sender, _oracleFee, _tokenId, request
    );
    // *** warning untrusted function call ***
    (bool success, bytes memory result) = address(dataResolver).call(payload);
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "call to resolver failed");

    emit RequestSettlementPrice(
      msg.sender,
      _tokenId,
      _oracleFee,
      dataResolver
    );

    return true;
  }

  /**
   *  Note: this function makes an external call
   *  but does not have a reentrancy guard as calling the bid functions
   *  trip the guard
   */
  function checkLimitPrice(uint256 _tokenId, uint256 _oracleFee)
    internal // declared as interanal else not visible to bid functions
    returns (bool)
  {
    require(msg.sender != address(0));
    require(_tokenId != 0, "tokenId cannot be zero");
    require(auctions[_tokenId].flags[AUCTION_ACTIVE], "auction must be active");
    require(!piggies[_tokenId].flags.hasBeenCleared, "piggy cleared");
    require(!auctions[_tokenId].flags[BID_CLEARED], "bid cleared");

    address dataResolver = piggies[_tokenId].accounts.dataResolver;
    uint8 request = uint8 (RequestType.Bid);
    // *** warning untrusted function call ***
    bytes memory payload = abi.encodeWithSignature(
      "fetchData(address,uint256,uint256,uint8)",
      msg.sender, _oracleFee, _tokenId, request
    );
    (bool success, bytes memory result) = address(dataResolver).call(payload);
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "call to resolver failed");
  }

  function _callback(
    uint256 _tokenId,
    uint256 _price,
    uint8 _requestType
  )
    public
  {
    require(msg.sender != address(0));
    // MUST restrict a call to only the resolver address
    require(msg.sender == piggies[_tokenId].accounts.dataResolver, "resolver callback address failed match");
    require(!piggies[_tokenId].flags.hasBeenCleared, "piggy cleared");

    if (_requestType == uint8 (RequestType.Settlement)) {
      piggies[_tokenId].uintDetails.settlementPrice = _price;
      piggies[_tokenId].flags.hasBeenCleared = true;

      // if abitration is set, lock piggy for cooldown period
      if (piggies[_tokenId].accounts.arbiter != address(0)) {
        piggies[_tokenId].uintDetails.arbitrationLock = block.number.add(cooldown);
      }
    }
    if (_requestType == uint8 (RequestType.Bid)) {
      require(!auctions[_tokenId].flags[BID_CLEARED], "bid cleared");
      auctions[_tokenId].details[ORACLE_PRICE] = _price;
      auctions[_tokenId].flags[BID_CLEARED] = true;
    }

    emit OracleReturned(
      msg.sender,
      _tokenId,
      _price,
      _requestType
    );

  }

  /** @notice Calculate the settlement of ownership of option collateral
      @dev Throws if `_tokenId` is not a valid ERC-59 token.
       Throws if msg.sender is not one of: seller, owner of `_tokenId`.
       Throws if hasBeenCleared is true.
   */
   function settlePiggy(uint256 _tokenId)
     public
     returns (bool)
   {
     bytes memory payload = abi.encodeWithSignature("settlePiggy(uint256)",_tokenId);
     (bool success, bytes memory result) = address(companionAddress).delegatecall(payload);
     bytes32 txCheck = abi.decode(result, (bytes32));
     require(success && txCheck == TX_SUCCESS, "settle failed");
     return true;
   }

  // claim payout - pull payment
  // sends any reference ERC-20 which the claimant is owed (as a result of an auction or settlement)
  function claimPayout(address _paymentToken, uint256 _amount)
    external
    nonReentrant
    returns (bool)
  {
    require(msg.sender != address(0));
    require(_amount != 0, "amount cannot be zero");
    require(_amount <= ERC20Balances[msg.sender][_paymentToken], "balance less than requested amount");
    ERC20Balances[msg.sender][_paymentToken] = ERC20Balances[msg.sender][_paymentToken].sub(_amount);

    (bool success, bytes memory result) = address(_paymentToken).call(
      abi.encodeWithSignature(
        "transfer(address,uint256)",
        msg.sender,
        _amount
      )
    );
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "token transfer failed");

    emit ClaimPayout(
      msg.sender,
      _amount,
      _paymentToken
    );

    return true;
  }

  /** Arbitration mechanisms
  */

  function updateArbiter(uint256 _tokenId, address _newArbiter)
    public
    returns (bool)
  {
    bytes memory payload = abi.encodeWithSignature("updateArbiter(uint256,address)",_tokenId,_newArbiter);
    (bool success, bytes memory result) = address(companionAddress).delegatecall(payload);
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success, "arbiter update failed");
    require(txCheck == TX_SUCCESS || txCheck == RTN_FALSE);
    return (txCheck == TX_SUCCESS) ? true : false;
  }

  function confirmArbiter(uint256 _tokenId)
    public
    returns (bool)
  {
    require(msg.sender != address(0));
    require(msg.sender == piggies[_tokenId].accounts.arbiter, "sender must be the arbiter");
    piggies[_tokenId].flags.arbiterHasConfirmed = true;

    emit ArbiterConfirmed(msg.sender, _tokenId);
    return true;
  }

  function thirdPartyArbitrationSettlement(uint256 _tokenId, uint256 _proposedPrice)
    public
    returns (bool)
  {
    bytes memory payload = abi.encodeWithSignature("thirdPartyArbitrationSettlement(uint256,uint256)",_tokenId,_proposedPrice);
    (bool success, bytes memory result) = address(companionAddress).delegatecall(payload);
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success, "arbiter update failed");
    require(txCheck == TX_SUCCESS || txCheck == RTN_FALSE);
    return (txCheck == TX_SUCCESS) ? true : false;
  }

  /** Helper functions
  */
  // helper function to view piggy details
  function getDetails(uint256 _tokenId)
    public
    view
    returns (Piggy memory)
  {
    return piggies[_tokenId];
  }

  // helper function to view auction details
  function getAuctionDetails(uint256 _tokenId)
    public
    view
    returns (DetailAuction memory)
  {
    return auctions[_tokenId];
  }

  /** @notice Count the number of ERC-59 tokens owned by a particular address
      @dev ERC-59 tokens assigned to the zero address are considered invalid, and this
       function throws for queries about the zero address.
      @param _owner An address for which to query the balance of ERC-59 tokens
      @return The number of ERC-59 tokens owned by `_owner`, possibly zero
   */
  function getOwnedPiggies(address _owner)
    public
    view
    returns (uint256[] memory)
  {
    return ownedPiggies[_owner];
  }

  function getERC20Balance(address _owner, address _erc20)
    public
    view
    returns (uint256)
  {
    return ERC20Balances[_owner][_erc20];
  }

  /* Internal functions
  */

  function _constructPiggy(
    address _collateralERC,
    address _dataResolver,
    address _arbiter,
    uint256 _collateral,
    uint256 _lotSize,
    uint256 _strikePrice,
    uint256 _expiry,
    uint256 _splitTokenId,
    bool _isEuro,
    bool _isPut,
    bool _isRequest,
    bool _isSplit
  )
    internal
    returns (bool)
  {
    bytes memory payload = abi.encodeWithSignature("_constructPiggy(address,address,address,uint256,uint256,uint256,uint256,uint256,bool,bool,bool,bool)",
      _collateralERC,_dataResolver,_arbiter,_collateral,
      _lotSize,_strikePrice,_expiry,_splitTokenId,
      _isEuro,_isPut,_isRequest,_isSplit);
    (bool success, bytes memory result) = address(companionAddress).delegatecall(payload);
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "piggy create failed");
    return true;
  }

  /**
   * make sure the ERC-20 contract for collateral correctly reports decimals
   * suggested visibility external, set to interanl as other internal functions
   * use this
   *
   * Note: this function calls an external function and does NOT have a
   * reentrantcy guard, as create will trigger the guard
   *
   */
  function _getERC20Decimals(address _ERC20)
    internal
    returns (uint8)
  {
    // *** warning untrusted function call ***
    (bool success, bytes memory _decBytes) = address(_ERC20).call(
        abi.encodeWithSignature("decimals()")
      );
     require(success, "contract does not properly specify decimals");
     /**
         allow for uint256 range of decimals,
         if token contract saves decimals as uint256
         accept uint256 value.
         Cast return value before return to force uint8 spec
      */
     uint256 _ERCdecimals = abi.decode(_decBytes, (uint256));
     return uint8(_ERCdecimals); // explicit cast, possible loss of resolution
  }

  // internal transfer for transfers made on behalf of the contract
  function _internalTransfer(address _from, address _to, uint256 _tokenId)
    internal
  {
    require(_from == piggies[_tokenId].accounts.holder, "from must be holder");
    require(_to != address(0), "recipient cannot be zero");
    _removeTokenFromOwnedPiggies(_from, _tokenId);
    _addTokenToOwnedPiggies(_to, _tokenId);
    piggies[_tokenId].accounts.holder = _to;
    emit TransferPiggy(_from, _to, _tokenId);
  }

  function _checkBidPrice(bool isPut, uint256 limitPrice, uint256 oraclePrice)
    internal
    pure
  {
    // check price limit condition
    require(isPut ? limitPrice < oraclePrice : oraclePrice < limitPrice, "price limit violated");
  }

  // calculate the price for satisfaction of an auction
  // this is an interpolated linear price based on the supplied auction parameters at a resolution of 1 block
  function _getAuctionPrice(uint256 _tokenId)
    internal
    view
    returns (uint256)
  {

    uint256 _pStart = auctions[_tokenId].details[START_PRICE];
    uint256 _pDelta = (block.number).sub(
      auctions[_tokenId].details[START_BLOCK]
    ).mul(
      auctions[_tokenId].details[PRICE_STEP]
    ).div(
      auctions[_tokenId].details[TIME_STEP]
    );
    if (piggies[_tokenId].flags.isRequest) {
      return _pStart.add(_pDelta);
    } else {
      return (_pStart.sub(_pDelta));
    }
  }

  function _calculateLongPayout(uint256 _tokenId)
    internal
    view
    returns (uint256 _payout)
  {
    bool _isPut = piggies[_tokenId].flags.isPut;
    uint256 _strikePrice = piggies[_tokenId].uintDetails.strikePrice;
    uint256 _exercisePrice = piggies[_tokenId].uintDetails.settlementPrice;
    uint256 _lotSize = piggies[_tokenId].uintDetails.lotSize;
    uint8 _decimals = piggies[_tokenId].uintDetails.collateralDecimals;

    if (_isPut && (_strikePrice > _exercisePrice)) {
      _payout = _strikePrice.sub(_exercisePrice);
    }
    if (!_isPut && (_exercisePrice > _strikePrice)) {
      _payout = _exercisePrice.sub(_strikePrice);
    }
    _payout = _payout.mul(10**uint256(_decimals)).mul(_lotSize).div(100);
    return _payout;
  }

  /**
      For clarity this is a private helper function to reuse the
      repeated `transferFrom` calls to a token contract.
      The contract does still use address(ERC20Address).call("transfer(address,uint256)")
      when the contract is making transfers from itself back to users.
      `attemptPaymentTransfer` is used when collateral is approved by a user
      in the specified token contract, and this contract makes a transfer on
      the user's behalf, as `transferFrom` checks allowance before sending
      and this contract does not make approval transactions
   */
  function attemptPaymentTransfer(address _ERC20, address _from, address _to, uint256 _amount)
    private
    returns (bool, bytes memory)
  {
    // *** warning untrusted function call ***
    /**
    **  check the return data because compound violated the ERC20 standard for
    **  token transfers :9
    */
    (bool success, bytes memory result) = address(_ERC20).call(
      abi.encodeWithSignature(
        "transferFrom(address,address,uint256)",
        _from,
        _to,
        _amount
      )
    );
    return (success, result);
  }

  function _addTokenToOwnedPiggies(address _to, uint256 _tokenId)
    private
  {
    ownedPiggiesIndex[_tokenId] = ownedPiggies[_to].length;
    ownedPiggies[_to].push(_tokenId);
  }

  function _removeTokenFromOwnedPiggies(address _from, uint256 _tokenId)
    private
  {
    uint256 lastTokenIndex = ownedPiggies[_from].length.sub(1);
    uint256 tokenIndex = ownedPiggiesIndex[_tokenId];

    if (tokenIndex != lastTokenIndex) {
      uint256 lastTokenId = ownedPiggies[_from][lastTokenIndex];
      ownedPiggies[_from][tokenIndex] = lastTokenId;
      ownedPiggiesIndex[lastTokenId] = tokenIndex;
    }
    ownedPiggies[_from].length--;
  }

  function _clearBid(uint256 _tokenId)
    private
  {
    auctions[_tokenId].details[ORACLE_PRICE] = 0;
    auctions[_tokenId].details[AUCTION_PREMIUM] = 0;
    auctions[_tokenId].details[COOLDOWN] = 0;
    auctions[_tokenId].activeBidder = address(0);
    auctions[_tokenId].rfpNonce = 0;
    auctions[_tokenId].flags[BID_LIMIT_SET] = false;
    auctions[_tokenId].flags[BID_CLEARED] = false;
  }

  function _clearAuctionDetails(uint256 _tokenId)
    private
  {
    auctions[_tokenId].details[START_BLOCK] = 0;
    auctions[_tokenId].details[EXPIRY_BLOCK] = 0;
    auctions[_tokenId].details[START_PRICE] = 0;
    auctions[_tokenId].details[RESERVE_PRICE] = 0;
    auctions[_tokenId].details[TIME_STEP] = 0;
    auctions[_tokenId].details[PRICE_STEP] = 0;
    auctions[_tokenId].details[LIMIT_PRICE] = 0;
    auctions[_tokenId].flags[AUCTION_ACTIVE] = false;
    _clearBid(_tokenId);
  }

  function _resetPiggy(uint256 _tokenId)
    private
  {
    delete piggies[_tokenId];
  }
}
