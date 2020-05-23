/**
SmartPiggies is an open source standard for
a free peer to peer global derivatives market

Copyright (C) 2020, SmartPiggies Inc.

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
    // admin is an administrator of the contact
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

  constructor()
    public
  {
    // 4blks/min * 60 min/hr * 24hrs/day * # days
    cooldown = 17280; // default 3 days
  }

  function setCooldown(uint256 _newCooldown)
    public
    onlyAdmin
    returns (bool)
  {
    cooldown = _newCooldown;
    return true;
  }
}


contract UsingAHelper is UsingCooldown {
  address public helperAddress;

  function setHelper(address _newAddress)
    public
    onlyAdmin
    returns (bool)
  {
    helperAddress = _newAddress;
    return true;
  }
}


/** @title SmartPiggies: A Smart Option Standard
*/
contract SmartPiggies is UsingAHelper {
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
/**
  struct DetailAddresses {
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
**/
  /**
   *  uint256 startBlock;
   *  uint256 expiryBlock;
   *  uint256 startPrice;
   *  uint256 reservePrice;
   *  uint256 timeStep;
   *  uint256 priceStep;
   *  uint256 limitPrice;
   *  uint256 oraclePrice;
   *  uint256 auctionPremium;
   *  address activeBidder;
   *  uint8 rfpNonce;
   *  bool auctionActive;
   *  bool bidLimitSet;
   *  bool bidLocked;
   *  bool bidCleared;
   *  bool satisfyInProgress;   // mutex guard to disallow ending an auction if a transaction to satisfy is in progress
   */

  struct DetailAuction {
    uint256[10] details;
    address activeBidder;
    uint8 rfpNonce;
    bool[4] flags;
  }

  struct Piggy {
    address[7] addresses; // address details
    uint256[10] uintDetails; // number details
    uint8[2] counters;
    bool[11] flags; // parameter switches
  }

  mapping (address => mapping(address => uint256)) private ERC20balances;
  mapping (address => mapping(uint256 => uint256)) private bidBalances;
  mapping (address => uint256[]) private ownedPiggies;
  mapping (uint256 => uint256) private ownedPiggiesIndex;
  mapping (uint256 => Piggy) private piggies;
  mapping (uint256 => DetailAuction) private auctions;

  /** Events
  */

  event CreatePiggy(
    address[] addresses,
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

  event CheckLimitPrice(
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
  constructor(address _piggyHelper)
    public
    Administered(msg.sender)
    Serviced(msg.sender)
  {
    //declarations here
    helperAddress = _piggyHelper;
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
    require(_amount < piggies[_tokenId].uintDetails[0], "amount not less than collateral");
    require(!piggies[_tokenId].flags[0], "cannot be RFP");
    require(piggies[_tokenId].uintDetails[0] > 0, "collateral must be greater than zero");
    require(msg.sender == piggies[_tokenId].addresses[1], "sender must be holder");
    require(block.number < piggies[_tokenId].uintDetails[4], "cannot split expired token");
    require(!auctions[_tokenId].flags[0], "cannot split token on auction");
    require(!piggies[_tokenId].flags[3], "cannot split cleared token");

    // assuming all checks have passed:

    // remove current token ID
    _removeTokenFromOwnedPiggies(msg.sender, _tokenId); // i.e. piggies[_tokenId].addresses.holder

    require(
      _constructPiggy(
        piggies[_tokenId].addresses[2],
        piggies[_tokenId].addresses[3],
        piggies[_tokenId].addresses[4],
        piggies[_tokenId].uintDetails[0].sub(_amount), // piggy with collateral less the amount
        piggies[_tokenId].uintDetails[1],
        piggies[_tokenId].uintDetails[2],
        piggies[_tokenId].uintDetails[4],
        _tokenId,
        piggies[_tokenId].flags[1],
        piggies[_tokenId].flags[2],
        false, // piggies[tokenId].flags.isRequest
        true // split piggy
      ),
      "create failed"
    ); // require this to succeed or revert, i.e. do not reset

    require(
      _constructPiggy(
        piggies[_tokenId].addresses[2],
        piggies[_tokenId].addresses[3],
        piggies[_tokenId].addresses[4],
        _amount,
        piggies[_tokenId].uintDetails[1],
        piggies[_tokenId].uintDetails[2],
        piggies[_tokenId].uintDetails[4],
        _tokenId,
        piggies[_tokenId].flags[1],
        piggies[_tokenId].flags[2],
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
    require(msg.sender == piggies[_tokenId].addresses[1], "sender must be holder");
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
    (bool success, bytes memory result) = address(helperAddress).delegatecall(payload);
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
    require(msg.sender == piggies[_tokenId].addresses[1], "sender must be holder");
    require(!auctions[_tokenId].flags[0], "token cannot be on auction");

    emit ReclaimAndBurn(msg.sender, _tokenId, piggies[_tokenId].flags[0]);
    // remove id from index mapping
    _removeTokenFromOwnedPiggies(piggies[_tokenId].addresses[1], _tokenId);

    if (!piggies[_tokenId].flags[0]) {
      require(msg.sender == piggies[_tokenId].addresses[0], "sender must own collateral to reclaim");

      // keep collateralERC address
      address collateralERC = piggies[_tokenId].addresses[2];
      // keep collateral
      uint256 collateral = piggies[_tokenId].uintDetails[0];
      // burn the token (zero out storage fields)
      _resetPiggy(_tokenId);

      // *** warning untrusted function call ***
      // return the collateral to sender
      (bool success, bytes memory result) = address(collateralERC).call(
        abi.encodeWithSignature(
          "transfer(address,uint256)",
          msg.sender,
          collateral
        )
      );
      bytes32 txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");
    }
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
    require(msg.sender == piggies[_tokenId].addresses[1], "sender must be holder");
    require(piggies[_tokenId].uintDetails[4] > block.number, "token must not be expired");
    require(piggies[_tokenId].uintDetails[4] > _auctionExpiry, "auction cannot expire after token expiry");
    require(!piggies[_tokenId].flags[3], "piggy cleared");
    require(!auctions[_tokenId].flags[0], "auction cannot be running");

    // if we made it past the various checks, set the auction metadata up in auctions mapping
    auctions[_tokenId].details[0] = block.number;
    auctions[_tokenId].details[1] = _auctionExpiry;
    auctions[_tokenId].details[2] = _startPrice;
    auctions[_tokenId].details[3] = _reservePrice;
    auctions[_tokenId].details[4] = _timeStep;
    auctions[_tokenId].details[5] = _priceStep;
    auctions[_tokenId].details[6] = _limitPrice;
    if (_bidLimitSet) {
        auctions[_tokenId].flags[1] = true;
    }
    auctions[_tokenId].flags[0] = true;

    if (piggies[_tokenId].flags[0]) {
      // *** warning untrusted function call ***
      (bool success, bytes memory result) = attemptPaymentTransfer(
        piggies[_tokenId].addresses[2],
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
    require(msg.sender == piggies[_tokenId].addresses[1], "sender must be holder");
    require(auctions[_tokenId].flags[0], "auction must be active");
    require(!auctions[_tokenId].flags[3], "auction is being satisfied");  // this should be added to other functions as well

    // set to reserve for RFP
    uint256 premiumToReturn = auctions[_tokenId].details[3];
    address bidder = auctions[_tokenId].activeBidder;
    //bool bidLocked = auctions[_tokenId].flags[2];

    bool success; // return bool from a token transfer
    bytes memory result; // return data from a token transfer
    bytes32 txCheck; // bytes32 check from a token transfer

    _clearAuctionDetails(_tokenId);
    // if bidding is locked and not an RFP

    if (bidder != address(0)) {
      if (piggies[_tokenId].flags[0]) {
        bidBalances[bidder][_tokenId] = 0;
        // return adjusted premium to bidder
        // *** warning untrusted function call ***
        (success, result) = address(piggies[_tokenId].addresses[2]).call(
          abi.encodeWithSignature(
            "transfer(address,uint256)",
            bidder,
            piggies[_tokenId].uintDetails[5] // return requested collateral
          )
        );
        txCheck = abi.decode(result, (bytes32));
        require(success && txCheck == TX_SUCCESS, "token transfer failed");

        if (bidBalances[msg.sender][_tokenId] > 0) {
          bidBalances[msg.sender][_tokenId] = 0;
          // if change from serverse price, return change to holder
          // *** warning untrusted function call ***
          (success, result) = address(piggies[_tokenId].addresses[2]).call(
            abi.encodeWithSignature(
              "transfer(address,uint256)",
              bidder,
              premiumToReturn
            )
          );
          txCheck = abi.decode(result, (bytes32));
          require(success && txCheck == TX_SUCCESS, "token transfer failed");
        }
      }
      // not RFP, return auction premium to bidder
      else {
        // reset premiumToReturn to bid balance
        premiumToReturn = bidBalances[bidder][_tokenId];
        bidBalances[bidder][_tokenId] = 0;
        //return auction premium to bidder
        // *** warning untrusted function call ***
        (success, result) = address(piggies[_tokenId].addresses[2]).call(
          abi.encodeWithSignature(
            "transfer(address,uint256)",
            bidder,
            premiumToReturn
          )
        );
        txCheck = abi.decode(result, (bytes32));
        require(success && txCheck == TX_SUCCESS, "token transfer failed");
      }
    }
    // if not on bid and RFP
    else if (piggies[_tokenId].flags[0]) {
      // *** warning untrusted function call ***
      // refund the _reservePrice premium
      (success, result) = address(piggies[_tokenId].addresses[2]).call(
        abi.encodeWithSignature(
          "transfer(address,uint256)",
          msg.sender,
          premiumToReturn
        )
      );
      txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");
    }
    emit EndAuction(msg.sender, _tokenId, piggies[_tokenId].flags[0]);
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
    require(auctions[_tokenId].flags[0], "auction must be running");
    require(piggies[_tokenId].addresses[1] != msg.sender, "cannot bid on your auction");
    require(!auctions[_tokenId].flags[3], "auction is being satisfied");
    //require(!auctions[_tokenId].flags[2], "auction bidding locked");
    require(auctions[_tokenId].activeBidder == address(0), "auction bidding locked");

    // set bidder
    auctions[_tokenId].activeBidder = msg.sender;
    // lock bidding
    //auctions[_tokenId].flags[2] = true;
    // set cooldown
    auctions[_tokenId].details[9] = block.number.add(cooldown);

    // get linear auction premium; reserve price should be a ceiling or floor depending on whether this is an RFP or an option, respectively
    uint256 auctionPremium = _getAuctionPrice(_tokenId);

    // calculate the adjusted premium based on reservePrice
    uint256 adjPremium = auctionPremium;
    if (adjPremium < auctions[_tokenId].details[3]) {
      adjPremium = auctions[_tokenId].details[3];
    }

    // save auction premium paid
    auctions[_tokenId].details[8] = adjPremium;
    // update bidder's balance
    bidBalances[msg.sender][_tokenId] = bidBalances[msg.sender][_tokenId].add(adjPremium);

    // *** warning untrusted function call ***
    // msg.sender pays (adjusted) premium
    (bool success, bytes memory result) = attemptPaymentTransfer(
      piggies[_tokenId].addresses[2],
      msg.sender,
      address(this),
      adjPremium
    );
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "token transfer failed");

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
    require(auctions[_tokenId].flags[0], "auction must be running");
    require(piggies[_tokenId].addresses[1] != msg.sender, "cannot bid on your auction");
    require(!auctions[_tokenId].flags[3], "auction is being satisfied");
    //require(!auctions[_tokenId].flags[2], "auction bidding locked");
    require(auctions[_tokenId].activeBidder == address(0), "auction bidding locked");

    // set bidder
    auctions[_tokenId].activeBidder = msg.sender;
    // lock bidding
    //auctions[_tokenId].flags[2] = true;
    // set cooldown
    auctions[_tokenId].details[9] = block.number.add(cooldown);
    // record current RFP nonce
    auctions[_tokenId].rfpNonce = piggies[_tokenId].counters[1];

    // get linear auction premium; reserve price should be a ceiling or floor depending on whether this is an RFP or an option, respectively
    uint256 adjPremium = _getAuctionPrice(_tokenId);
    uint256 change = 0;

    // set bidder's balance to collateral sent to contract to collateralize piggy
    bidBalances[msg.sender][_tokenId] = piggies[_tokenId].uintDetails[5];

    // calculate adjusted premium (based on reservePrice) + possible change due back to current holder
    if (adjPremium > auctions[_tokenId].details[3]) {
      adjPremium = auctions[_tokenId].details[3];
    } else {
      change = auctions[_tokenId].details[3].sub(adjPremium);
    }
    // update bidder's balance with owed premium
    bidBalances[msg.sender][_tokenId] = bidBalances[msg.sender][_tokenId].add(adjPremium);

    // set current holder's balance with the change
    bidBalances[piggies[_tokenId].addresses[1]][_tokenId] = change;

    // save auction premium paid
    auctions[_tokenId].details[8] = adjPremium;

    bool success; // return bool from a token transfer
    bytes memory result; // return data from a token transfer
    bytes32 txCheck; // bytes32 check from a token transfer

    // *** warning untrusted function call ***
    // msg.sender needs to delegate reqCollateral
    (success, result) = attemptPaymentTransfer(
      piggies[_tokenId].addresses[2],
      msg.sender,
      address(this),
      piggies[_tokenId].uintDetails[5]
    );
    txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "token transfer failed");

    checkLimitPrice(_tokenId, _oralceFee);

    return true;
  }

  function reclaimBid(uint256 _tokenId)
    external
    returns (bool)
  {
    // sender must be bidder on auction, implicit check that bid is locked
    require(msg.sender == auctions[_tokenId].activeBidder, "sender not bidder");
    // oracle didn't return
    require(!auctions[_tokenId].flags[2], "bid cleared");
    // past cooldown
    require(auctions[_tokenId].details[9] < block.number, "cooldown still active");

    // *** warning untrusted function call ***
    // refund the _reservePrice premium
    uint256 bidAmount = bidBalances[msg.sender][_tokenId];
    bidBalances[msg.sender][_tokenId] = 0;

    // clean up token bid
    _clearBid(_tokenId);

    (bool success, bytes memory result) = address(piggies[_tokenId].addresses[2]).call(
      abi.encodeWithSignature(
        "transfer(address,uint256)",
        msg.sender,
        bidAmount
      )
    );
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "token transfer failed");

    return true;
  }

  function satisfyPiggyAuction(uint256 _tokenId)
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    require(!auctions[_tokenId].flags[3], "auction is being satisfied"); // mutex MUST be first
    require(piggies[_tokenId].addresses[1] != msg.sender, "cannot satisfy your auction; use endAuction");
    require(auctions[_tokenId].flags[0], "auction must be active to satisfy");
    //use satisfyRFPAuction for RFP auctions
    require(!piggies[_tokenId].flags[0], "cannot satisfy auction; check piggy type");

    // if auction is "active" according to state but has expired, change state
    if (auctions[_tokenId].details[1] < block.number) {
      _clearAuctionDetails(_tokenId);
      return false;
    }

    // lock mutex
    auctions[_tokenId].flags[3] = true;

    uint256 auctionPremium = 0;
    uint256 adjPremium = 0;
    address previousHolder = piggies[_tokenId].addresses[1];
    bool success; // return bool from a token transfer
    bytes memory result; // return data from a token transfer
    bytes32 txCheck; // bytes32 check from a token transfer

    if (auctions[_tokenId].flags[1]) {
      require(auctions[_tokenId].flags[2], "auction must receive price check");

      // check price limit condition
      _checkBidPrice(
        piggies[_tokenId].flags[2],
        auctions[_tokenId].details[6],
        auctions[_tokenId].details[7]
      );

      // bidder becomes holder
      _internalTransfer(previousHolder, auctions[_tokenId].activeBidder, _tokenId);

      // included for event logging
      adjPremium = adjPremium = auctions[_tokenId].details[8];
      // update bidder's balance
      bidBalances[auctions[_tokenId].activeBidder][_tokenId] = 0;

      // optimistic clean up assuming no revert
      _clearAuctionDetails(_tokenId);

      // *** warning untrusted function call ***
      // previous holder/writer receives (adjusted) auction premium
      (success, result) = address(piggies[_tokenId].addresses[2]).call(
        abi.encodeWithSignature(
          "transfer(address,uint256)",
          previousHolder,
          adjPremium
        )
      );
      txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");
    }
    // auction didn't go through a bidding process
    else {
      auctionPremium = _getAuctionPrice(_tokenId);
      adjPremium = auctionPremium;

      if (adjPremium < auctions[_tokenId].details[3]) {
        adjPremium = auctions[_tokenId].details[3];
      }

      // msg.sender becomes holder
      _internalTransfer(previousHolder, msg.sender, _tokenId);

      // optimistic clean up assuming no revert
      _clearAuctionDetails(_tokenId);

      // *** warning untrusted function call ***
      // msg.sender pays (adjusted) premium
      (success, result) = attemptPaymentTransfer(
        piggies[_tokenId].addresses[2],
        msg.sender,
        previousHolder,
        adjPremium
      );
      txCheck = abi.decode(result, (bytes32));
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
    auctions[_tokenId].flags[3] = false;
    return true;
  }

  function satisfyRFPBidAuction(uint256 _tokenId)
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    require(!auctions[_tokenId].flags[3], "auction is being satisfied"); // mutex MUST be first
    require(piggies[_tokenId].addresses[1] != msg.sender, "cannot satisfy your auction; use endAuction");
    require(auctions[_tokenId].flags[0], "auction must be active to satisfy");
    //use satisfyPiggyAuction for piggy auctions
    require(piggies[_tokenId].flags[0], "cannot satisfy auction; check piggy type");
    require(auctions[_tokenId].flags[1], "bid auction not set");
    require(auctions[_tokenId].flags[2], "auction must receive price check");
    // make sure current rfpNonce matches rfpNonce for bid
    require(piggies[_tokenId].counters[1] == auctions[_tokenId].rfpNonce, "RFP Nonce failed match");

    // if auction is "active" according to state but has expired, change state
    if (auctions[_tokenId].details[1] < block.number) {
      _clearAuctionDetails(_tokenId);
      return false;
    }

    // lock mutex
    auctions[_tokenId].flags[3] = true;

    uint256 adjPremium;
    uint256 change;
    address holder = piggies[_tokenId].addresses[1];
    uint256 reserve = auctions[_tokenId].details[3];
    address bidder = auctions[_tokenId].activeBidder;

    bool success; // return bool from a token transfer
    bytes memory result; // return data from a token transfer
    bytes32 txCheck; // bytes32 check from a token transfer

    // optimistic clean up assuming no revert
    _clearAuctionDetails(_tokenId);

    // collateral transfer SHOULD succeed, reqCollateral gets set to collateral
    piggies[_tokenId].uintDetails[0] = piggies[_tokenId].uintDetails[5];
    // isRequest becomes false
    piggies[_tokenId].flags[0] = false;


    // active bidder becomes writer
    piggies[_tokenId].addresses[0] = bidder;

    adjPremium = auctions[_tokenId].details[8];

    // update bidBalances:
    // requested collateral moves to collateral, adjusted premium -> bidder
    bidBalances[bidder][_tokenId] = 0;
    // holder's premium -> bidder
    bidBalances[holder][_tokenId] = bidBalances[holder][_tokenId].sub(adjPremium);

      // current holder pays premium (via amount already delegated to this contract in startAuction)
      (success, result) = address(piggies[_tokenId].addresses[2]).call(
        abi.encodeWithSignature(
          "transfer(address,uint256)",
          bidder,
          adjPremium
        )
      );
      txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");

      // return any change to current holder
      if(adjPremium < reserve) {
        // update holder's bidding balance

        // *** warning untrusted function call ***
        (success, result) = address(piggies[_tokenId].addresses[2]).call(
          abi.encodeWithSignature(
            "transfer(address,uint256)",
            holder,
            reserve.sub(adjPremium)
          )
        );
        txCheck = abi.decode(result, (bytes32));
        require(success && txCheck == TX_SUCCESS, "token transfer failed");
      }

    emit SatisfyAuction(
      msg.sender,
      _tokenId,
      adjPremium,
      change,
      adjPremium.add(change)
    );

    // mutex released
    auctions[_tokenId].flags[3] = false;
    return true;
  }

  function satisfyRFPSpotAuction(uint256 _tokenId, uint8 _rfpNonce)
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    require(!auctions[_tokenId].flags[3], "auction is being satisfied");
    require(piggies[_tokenId].addresses[1] != msg.sender, "cannot satisfy your auction; use endAuction");
    require(auctions[_tokenId].flags[0], "auction must be active to satisfy");

    //use satisfyPiggyAuction for piggy auctions
    require(piggies[_tokenId].flags[0], "cannot satisfy auction; check piggy type");

    // if auction is "active" according to state but has expired, change state
    if (auctions[_tokenId].details[1] < block.number) {
      _clearAuctionDetails(_tokenId);
      return false;
    }

    // lock mutex
    auctions[_tokenId].flags[3] = true;

    uint256 adjPremium;
    uint256 change;

    bool success; // return bool from a token transfer
    bytes memory result; // return data from a token transfer
    bytes32 txCheck; // bytes32 check from a token transfer

    // collateral transfer SHOULD succeed, reqCollateral gets set to collateral
    piggies[_tokenId].uintDetails[0] = piggies[_tokenId].uintDetails[5];
    // isRequest becomes false
    piggies[_tokenId].flags[0] = false;

    // auction didn't go through a bidding process

      // make sure rfpNonce matches
      require(_rfpNonce == piggies[_tokenId].counters[1], "RFP Nonce failed match");

      // msg.sender becomes writer
      piggies[_tokenId].addresses[0] = msg.sender;

      adjPremium = _getAuctionPrice(_tokenId);

      // calculate adjusted premium (based on reservePrice) + possible change due back to current holder
      if (adjPremium > auctions[_tokenId].details[3]) {
        adjPremium = auctions[_tokenId].details[3];
      } else {
        change = auctions[_tokenId].details[3].sub(adjPremium);
      }

      // optimistic clean up assuming nothing reverts
      _clearAuctionDetails(_tokenId);

      // *** warning untrusted function call ***
      // msg.sender needs to delegate reqCollateral
      (success, result) = attemptPaymentTransfer(
        piggies[_tokenId].addresses[2],
        msg.sender,
        address(this),
        piggies[_tokenId].uintDetails[5]
      );
      txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");

      // *** warning untrusted function call ***
      // current holder pays premium (via amount already delegated to this contract in startAuction)
      (success, result) = address(piggies[_tokenId].addresses[2]).call(
        abi.encodeWithSignature(
          "transfer(address,uint256)",
          msg.sender,
          adjPremium
        )
      );
      txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");

      // current holder receives any change due
      if (change > 0) {
        // *** warning untrusted function call ***
        (success, result) = address(piggies[_tokenId].addresses[2]).call(
          abi.encodeWithSignature(
            "transfer(address,uint256)",
            piggies[_tokenId].addresses[1],
            change
          )
        );
        txCheck = abi.decode(result, (bytes32));
        require(success && txCheck == TX_SUCCESS, "token transfer failed");
      }

    emit SatisfyAuction(
      msg.sender,
      _tokenId,
      adjPremium,
      change,
      adjPremium.add(change)
    );

    // mutex released
    auctions[_tokenId].flags[3] = false;
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
    require(_tokenId != 0, "tokenId cannot be zero");
    require(!auctions[_tokenId].flags[0], "cannot clear while auction active");
    require(!piggies[_tokenId].flags[3], "piggy cleared");

    // check if Euro require past expiry
    if (piggies[_tokenId].flags[1]) {
      require(piggies[_tokenId].uintDetails[4] <= block.number, "cannot request price for European before expiry");
    }
    // check if American and less than expiry, only holder can call
    if (!piggies[_tokenId].flags[1] && (block.number < piggies[_tokenId].uintDetails[4]))
    {
      require(msg.sender == piggies[_tokenId].addresses[1], "only holder can settle American before expiry");
    }

    address dataResolver = piggies[_tokenId].addresses[3];
    uint8 requestType = uint8 (RequestType.Settlement);
    // *** warning untrusted function call ***
    bytes memory payload = abi.encodeWithSignature(
      "fetchData(address,uint256,uint256,uint8)",
      msg.sender, _oracleFee, _tokenId, requestType
    );
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

  function checkLimitPrice(uint256 _tokenId, uint256 _oracleFee)
    internal // declared as interanal else not visible to bid functions
    nonReentrant
    returns (bool)
  {
    require(msg.sender != address(0));
    require(_tokenId != 0, "tokenId cannot be zero");
    require(auctions[_tokenId].flags[0], "auction must be active");
    require(!piggies[_tokenId].flags[3], "piggy cleared");
    require(!auctions[_tokenId].flags[2], "bid cleared");

    address dataResolver = piggies[_tokenId].addresses[3];
    uint8 requestType = uint8 (RequestType.Bid);
    // *** warning untrusted function call ***
    bytes memory payload = abi.encodeWithSignature(
      "fetchData(address,uint256,uint256,uint8)",
      msg.sender, _oracleFee, _tokenId, requestType
    );
    (bool success, bytes memory result) = address(dataResolver).call(payload);
    bytes32 txCheck = abi.decode(result, (bytes32));
    require(success && txCheck == TX_SUCCESS, "call to resolver failed");

    emit CheckLimitPrice(
      msg.sender,
      _tokenId,
      _oracleFee,
      dataResolver
    );

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
    require(msg.sender == piggies[_tokenId].addresses[3], "resolver callback address failed match");
    require(!piggies[_tokenId].flags[3], "piggy cleared");

    // select request type
    if(_requestType == uint8 (RequestType.Settlement)) {
      piggies[_tokenId].uintDetails[3] = _price;
      piggies[_tokenId].flags[3] = true;

      // if abitration is set, lock piggy for cooldown period
      if (piggies[_tokenId].addresses[4] != address(0)) {
        piggies[_tokenId].uintDetails[6] = block.number.add(cooldown);
      }
    }
    if (_requestType == uint8 (RequestType.Bid)) {
      require(!auctions[_tokenId].flags[2], "bid cleared");
      auctions[_tokenId].details[7] = _price;
      auctions[_tokenId].flags[2] = true;
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
     (bool success, bytes memory result) = address(helperAddress).delegatecall(payload);
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
    require(_amount <= ERC20balances[msg.sender][_paymentToken], "balance less than requested amount");
    ERC20balances[msg.sender][_paymentToken] = ERC20balances[msg.sender][_paymentToken].sub(_amount);

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
    (bool success, bytes memory result) = address(helperAddress).delegatecall(payload);
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
    require(msg.sender == piggies[_tokenId].addresses[4], "sender must be arbiter");
    piggies[_tokenId].flags[9] = true;

    emit ArbiterConfirmed(msg.sender, _tokenId);
    return true;
  }

  function thirdPartyArbitrationSettlement(uint256 _tokenId, uint256 _proposedPrice)
    public
    returns (bool)
  {
    bytes memory payload = abi.encodeWithSignature("thirdPartyArbitrationSettlement(uint256,uint256)",_tokenId,_proposedPrice);
    (bool success, bytes memory result) = address(helperAddress).delegatecall(payload);
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
    return ERC20balances[_owner][_erc20];
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
    (bool success, bytes memory result) = address(helperAddress).delegatecall(payload);
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
    require(_from == piggies[_tokenId].addresses[1], "from must be holder");
    require(_to != address(0), "receiving address cannot be zero");
    _removeTokenFromOwnedPiggies(_from, _tokenId);
    _addTokenToOwnedPiggies(_to, _tokenId);
    piggies[_tokenId].addresses[1] = _to;
    emit TransferPiggy(_from, _to, _tokenId);
  }

  function _checkBidPrice(bool isPut, uint256 limitPrice, uint256 oraclePrice)
    internal
    pure
  {
    // check price limit condition
    if(isPut) {
        // if put
        require(limitPrice < oraclePrice, "price limit violated");
    } else {
        // if call
        require(oraclePrice < limitPrice, "price limit violated");
    }
  }

  // calculate the price for satisfaction of an auction
  // this is an interpolated linear price based on the supplied auction parameters at a resolution of 1 block
  function _getAuctionPrice(uint256 _tokenId)
    internal
    view
    returns (uint256)
  {

    uint256 _pStart = auctions[_tokenId].details[2];
    uint256 _pDelta = (block.number).sub(auctions[_tokenId].details[0]).mul(auctions[_tokenId].details[5]).div(auctions[_tokenId].details[4]);
    if (piggies[_tokenId].flags[0]) {
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
    bool _isPut = piggies[_tokenId].flags[2];
    uint256 _strikePrice = piggies[_tokenId].uintDetails[2];
    uint256 _exercisePrice = piggies[_tokenId].uintDetails[3];
    uint256 _lotSize = piggies[_tokenId].uintDetails[1];
    uint8 _decimals = piggies[_tokenId].counters[0];

    if (_isPut && (_strikePrice > _exercisePrice)) {
      _payout = _strikePrice.sub(_exercisePrice);
    }
    if (!_isPut && (_exercisePrice > _strikePrice)) {
      _payout = _exercisePrice.sub(_strikePrice);
    }
    _payout = _payout.mul(10**uint256(_decimals)).mul(_lotSize).div(100);
    return _payout;
  }

  function _clearBid(uint256 _tokenId)
    internal
  {
    auctions[_tokenId].details[7] = 0;
    auctions[_tokenId].details[8] = 0;
    auctions[_tokenId].details[9] = 0;
    auctions[_tokenId].activeBidder = address(0);
    auctions[_tokenId].rfpNonce = 0;
    auctions[_tokenId].flags[1] = false;
    //auctions[_tokenId].flags[2] = false;
    auctions[_tokenId].flags[2] = false;
  }

  function _clearAuctionDetails(uint256 _tokenId)
    internal
  {
    auctions[_tokenId].details[0] = 0;
    auctions[_tokenId].details[1] = 0;
    auctions[_tokenId].details[2] = 0;
    auctions[_tokenId].details[3] = 0;
    auctions[_tokenId].details[4] = 0;
    auctions[_tokenId].details[5] = 0;
    auctions[_tokenId].details[6] = 0;
    auctions[_tokenId].flags[0] = false;
    _clearBid(_tokenId);
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

  function _resetPiggy(uint256 _tokenId)
    private
  {
    piggies[_tokenId].addresses[0] = address(0);
    piggies[_tokenId].addresses[1] = address(0);
    piggies[_tokenId].addresses[2] = address(0);
    piggies[_tokenId].addresses[3] = address(0);
    piggies[_tokenId].addresses[4] = address(0);
    piggies[_tokenId].addresses[5] = address(0);
    piggies[_tokenId].addresses[6] = address(0);
    piggies[_tokenId].uintDetails[0] = 0;
    piggies[_tokenId].uintDetails[1] = 0;
    piggies[_tokenId].uintDetails[2] = 0;
    piggies[_tokenId].uintDetails[4] = 0;
    piggies[_tokenId].uintDetails[3] = 0;
    piggies[_tokenId].uintDetails[5] = 0;
    piggies[_tokenId].uintDetails[6] = 0;
    piggies[_tokenId].uintDetails[7] = 0;
    piggies[_tokenId].uintDetails[8] = 0;
    piggies[_tokenId].uintDetails[9] = 0;
    piggies[_tokenId].counters[0] = 0;
    piggies[_tokenId].counters[1] = 0;
    piggies[_tokenId].flags[0] = false;
    piggies[_tokenId].flags[1] = false;
    piggies[_tokenId].flags[2] = false;
    piggies[_tokenId].flags[3] = false;
    piggies[_tokenId].flags[4] = false;
    piggies[_tokenId].flags[5] = false;
    piggies[_tokenId].flags[6] = false;
    piggies[_tokenId].flags[7] = false;
    piggies[_tokenId].flags[8] = false;
    piggies[_tokenId].flags[9] = false;
    piggies[_tokenId].flags[10] = false;
  }
}
