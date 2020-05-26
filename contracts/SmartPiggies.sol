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

  function isNotFrozen()
    public
    view
    returns (bool)
  {
    return notFrozen;
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

  function getFeeAddress()
    public
    view
    returns (address)
  {
    return feeAddress;
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


contract UsingCompanion is UsingCooldown {
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


/** @title SmartPiggies: A Smart Option Standard
*/
contract SmartPiggies is UsingCompanion {
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

  struct DetailAuction {
    uint256 startBlock;
    uint256 expiryBlock;
    uint256 startPrice;
    uint256 reservePrice;
    uint256 timeStep;
    uint256 priceStep;
    bool auctionActive;
    bool satisfyInProgress;  // mutex guard to disallow ending an auction if a transaction to satisfy is in progress
  }

  struct Piggy {
    DetailAddresses addresses; // address details
    DetailUints uintDetails; // number details
    BoolFlags flags; // parameter switches
  }

  mapping (address => mapping(address => uint256)) private ERC20balances;
  mapping (address => uint256) private bidBalances;
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

  event OracleReturned(
    address indexed resolver,
    uint256 indexed tokenId,
    uint256 indexed price
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
    require(piggies[_tokenId].addresses.holder == msg.sender, "only holder can split");
    require(block.number < piggies[_tokenId].uintDetails.expiry, "cannot split expired token");
    require(!auctions[_tokenId].auctionActive, "auction active");
    require(!piggies[_tokenId].flags.hasBeenCleared, "piggy cleared");

    // assuming all checks have passed:

    // remove current token ID
    _removeTokenFromOwnedPiggies(msg.sender, _tokenId); // i.e. piggies[_tokenId].addresses.holder

    require(
      _constructPiggy(
        piggies[_tokenId].addresses.collateralERC,
        piggies[_tokenId].addresses.dataResolver,
        piggies[_tokenId].addresses.arbiter,
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
        piggies[_tokenId].addresses.collateralERC,
        piggies[_tokenId].addresses.dataResolver,
        piggies[_tokenId].addresses.arbiter,
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
    require(msg.sender == piggies[_tokenId].addresses.holder, "sender must be holder");
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
    require(msg.sender == piggies[_tokenId].addresses.holder, "sender must be holder");
    require(!auctions[_tokenId].auctionActive, "auction active");

    emit ReclaimAndBurn(msg.sender, _tokenId, piggies[_tokenId].flags.isRequest);
    // remove id from index mapping
    _removeTokenFromOwnedPiggies(piggies[_tokenId].addresses.holder, _tokenId);

    if (!piggies[_tokenId].flags.isRequest) {
      require(msg.sender == piggies[_tokenId].addresses.writer, "sender must own collateral");

      // keep collateralERC address
      address collateralERC = piggies[_tokenId].addresses.collateralERC;
      // keep collateral
      uint256 collateral = piggies[_tokenId].uintDetails.collateral;
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
    uint256 _priceStep
  )
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    uint256 _auctionExpiry = block.number.add(_auctionLength);
    require(piggies[_tokenId].addresses.holder == msg.sender, "sender must be holder");
    require(piggies[_tokenId].uintDetails.expiry > block.number, "piggy expired");
    require(piggies[_tokenId].uintDetails.expiry > _auctionExpiry, "auction cannot expire after token expiry");
    require(!piggies[_tokenId].flags.hasBeenCleared, "piggy cleared");
    require(!auctions[_tokenId].auctionActive, "auction active");

    // if we made it past the various checks, set the auction metadata up in auctions mapping
    auctions[_tokenId].startBlock = block.number;
    auctions[_tokenId].expiryBlock = _auctionExpiry;
    auctions[_tokenId].startPrice = _startPrice;
    auctions[_tokenId].reservePrice = _reservePrice;
    auctions[_tokenId].timeStep = _timeStep;
    auctions[_tokenId].priceStep = _priceStep;
    auctions[_tokenId].auctionActive = true;

    if (piggies[_tokenId].flags.isRequest) {
      // *** warning untrusted function call ***
      (bool success, bytes memory result) = attemptPaymentTransfer(
        piggies[_tokenId].addresses.collateralERC,
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
    require(piggies[_tokenId].addresses.holder == msg.sender, "sender must be holder");
    require(auctions[_tokenId].auctionActive, "auction not active");
    require(!auctions[_tokenId].satisfyInProgress, "auction is being satisfied");  // this should be added to other functions as well

    if (piggies[_tokenId].flags.isRequest) {
      uint256 _premiumToReturn = auctions[_tokenId].reservePrice;
      _clearAuctionDetails(_tokenId);

      // *** warning untrusted function call ***
      // refund the _reservePrice premium
      (bool success, bytes memory result) = address(piggies[_tokenId].addresses.collateralERC).call(
        abi.encodeWithSignature(
          "transfer(address,uint256)",
          msg.sender,
          _premiumToReturn
        )
      );
      bytes32 txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");
    }

    _clearAuctionDetails(_tokenId);
    emit EndAuction(msg.sender, _tokenId, piggies[_tokenId].flags.isRequest);
    return true;
  }

  function satisfyAuction(uint256 _tokenId, uint8 _rfpNonce)
    external
    whenNotFrozen
    nonReentrant
    returns (bool)
  {
    require(!auctions[_tokenId].satisfyInProgress, "auction is being satisfied");
    require(piggies[_tokenId].addresses.holder != msg.sender, "cannot satisfy auction; use endAuction");
    require(auctions[_tokenId].auctionActive, "auction not active");
    // if auction is "active" according to state but has expired, change state
    if (auctions[_tokenId].expiryBlock < block.number) {
      _clearAuctionDetails(_tokenId);
      return false;
    }
    // get linear auction premium; reserve price should be a ceiling or floor depending on whether this is an RFP or an option, respectively
    uint256 _auctionPremium = _getAuctionPrice(_tokenId);

    // lock mutex
    auctions[_tokenId].satisfyInProgress = true;

    bool success; // return bool from a token transfer
    bytes memory result; // return data from a token transfer
    bytes32 txCheck; // bytes32 check from a token transfer

    if (piggies[_tokenId].flags.isRequest) {
      // check RFP Nonce against auction front running
      require(_rfpNonce == piggies[_tokenId].uintDetails.rfpNonce, "RFP Nonce failed match");

      // *** warning untrusted function call ***
      // msg.sender needs to delegate reqCollateral
      (success, result) = attemptPaymentTransfer(
        piggies[_tokenId].addresses.collateralERC,
        msg.sender,
        address(this),
        piggies[_tokenId].uintDetails.reqCollateral
      );
      txCheck = abi.decode(result, (bytes32));
      if (!success || txCheck != TX_SUCCESS) {
        auctions[_tokenId].satisfyInProgress = false;
        return false;
      }
      // if the collateral transfer succeeded, reqCollateral gets set to collateral
      piggies[_tokenId].uintDetails.collateral = piggies[_tokenId].uintDetails.reqCollateral;
      // calculate adjusted premium (based on reservePrice) + possible change due back to current holder
      uint256 _change = 0;
      uint256 _adjPremium = _auctionPremium;
      if (_adjPremium > auctions[_tokenId].reservePrice) {
        _adjPremium = auctions[_tokenId].reservePrice;
      } else {
        _change = auctions[_tokenId].reservePrice.sub(_adjPremium);
      }
      // *** warning untrusted function call ***
      // current holder pays premium (via amount already delegated to this contract in startAuction)
      (success, result) = address(piggies[_tokenId].addresses.collateralERC).call(
        abi.encodeWithSignature(
          "transfer(address,uint256)",
          msg.sender,
          _adjPremium
        )
      );
      txCheck = abi.decode(result, (bytes32));
      require(success && txCheck == TX_SUCCESS, "token transfer failed");

      // current holder receives any change due
      if (_change > 0) {
        // *** warning untrusted function call ***
        (success, result) = address(piggies[_tokenId].addresses.collateralERC).call(
          abi.encodeWithSignature(
            "transfer(address,uint256)",
            piggies[_tokenId].addresses.holder,
            _change
          )
        );
        txCheck = abi.decode(result, (bytes32));
        require(success && txCheck == TX_SUCCESS, "token transfer failed");
      }
      // isRequest becomes false
      piggies[_tokenId].flags.isRequest = false;
      // msg.sender becomes writer
      piggies[_tokenId].addresses.writer = msg.sender;

      emit SatisfyAuction(
        msg.sender,
        _tokenId,
        _adjPremium,
        _change,
        _auctionPremium
      );

    } else {
      // calculate the adjusted premium based on reservePrice
      uint256 _adjPremium = _auctionPremium;
      if (_adjPremium < auctions[_tokenId].reservePrice) {
        _adjPremium = auctions[_tokenId].reservePrice;
      }
      // *** warning untrusted function call ***
      // msg.sender pays (adjusted) premium
      (success, result) = attemptPaymentTransfer(
        piggies[_tokenId].addresses.collateralERC,
        msg.sender,
        piggies[_tokenId].addresses.holder,
        _adjPremium
      );
      txCheck = abi.decode(result, (bytes32));
      if (!success || txCheck != TX_SUCCESS) {
        auctions[_tokenId].satisfyInProgress = false;
        return false;
      }
      // msg.sender becomes holder
      _internalTransfer(piggies[_tokenId].addresses.holder, msg.sender, _tokenId);

      emit SatisfyAuction(
        msg.sender,
        _tokenId,
        _adjPremium,
        0,
        _auctionPremium
      );

    }
    // auction is ended
    _clearAuctionDetails(_tokenId);
    // mutex released
    auctions[_tokenId].satisfyInProgress = false;
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
    require(!auctions[_tokenId].auctionActive, "auction active");
    require(!piggies[_tokenId].flags.hasBeenCleared, "piggy cleared");
    require(_tokenId != 0, "tokenId cannot be zero");

    // check if Euro require past expiry
    if (piggies[_tokenId].flags.isEuro) {
      require(piggies[_tokenId].uintDetails.expiry <= block.number, "cannot request price for European before expiry");
    }
    // check if American and less than expiry, only holder can call
    if (!piggies[_tokenId].flags.isEuro && (block.number < piggies[_tokenId].uintDetails.expiry))
    {
      require(msg.sender == piggies[_tokenId].addresses.holder, "only holder can settle American before expiry");
    }

    address dataResolver = piggies[_tokenId].addresses.dataResolver;
    uint8 requestType = uint8 (RequestType.Settlement);
    bytes memory payload = abi.encodeWithSignature(
      "fetchData(address,uint256,uint256,uint8)",
      msg.sender, _oracleFee, _tokenId, requestType
    );
    // *** warning untrusted function call ***
    //(bool success, bytes memory result) = address(dataResolver).call(
    //  abi.encodeWithSignature("fetchData(address,uint256,uint256)", msg.sender, _oracleFee, _tokenId)
    //);
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

  function _callback(
    uint256 _tokenId,
    uint256 _price,
    uint8 _requestType
  )
    public
  {
    require(msg.sender != address(0));
    // MUST restrict a call to only the resolver address
    require(msg.sender == piggies[_tokenId].addresses.dataResolver, "resolver callback address failed match");
    require(!piggies[_tokenId].flags.hasBeenCleared, "piggy cleared");
    piggies[_tokenId].uintDetails.settlementPrice = _price;
    piggies[_tokenId].flags.hasBeenCleared = true;

    // if abitration is set, lock piggy for cooldown period
    if (piggies[_tokenId].addresses.arbiter != address(0)) {
      piggies[_tokenId].uintDetails.arbitrationLock = block.number.add(cooldown);
    }

    emit OracleReturned(
      msg.sender,
      _tokenId,
      _price
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
    require(msg.sender == piggies[_tokenId].addresses.arbiter, "sender must be the arbiter");
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
    require(_from == piggies[_tokenId].addresses.holder, "from must be holder");
    require(_to != address(0), "recipient cannot be zero");
    _removeTokenFromOwnedPiggies(_from, _tokenId);
    _addTokenToOwnedPiggies(_to, _tokenId);
    piggies[_tokenId].addresses.holder = _to;
    emit TransferPiggy(_from, _to, _tokenId);
  }

  function _clearAuctionDetails(uint256 _tokenId)
    internal
  {
    auctions[_tokenId].startBlock = 0;
    auctions[_tokenId].expiryBlock = 0;
    auctions[_tokenId].startPrice = 0;
    auctions[_tokenId].reservePrice = 0;
    auctions[_tokenId].timeStep = 0;
    auctions[_tokenId].priceStep = 0;
    auctions[_tokenId].auctionActive = false;
  }

  // calculate the price for satisfaction of an auction
  // this is an interpolated linear price based on the supplied auction parameters at a resolution of 1 block
  function _getAuctionPrice(uint256 _tokenId)
    internal
    view
    returns (uint256)
  {

    uint256 _pStart = auctions[_tokenId].startPrice;
    uint256 _pDelta = (block.number).sub(auctions[_tokenId].startBlock).mul(auctions[_tokenId].priceStep).div(auctions[_tokenId].timeStep);
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

  function _resetPiggy(uint256 _tokenId)
    private
  {
    piggies[_tokenId].addresses.writer = address(0);
    piggies[_tokenId].addresses.holder = address(0);
    piggies[_tokenId].addresses.arbiter = address(0);
    piggies[_tokenId].addresses.collateralERC = address(0);
    piggies[_tokenId].addresses.dataResolver = address(0);
    piggies[_tokenId].addresses.writerProposedNewArbiter = address(0);
    piggies[_tokenId].addresses.holderProposedNewArbiter = address(0);
    piggies[_tokenId].uintDetails.collateral = 0;
    piggies[_tokenId].uintDetails.lotSize = 0;
    piggies[_tokenId].uintDetails.strikePrice = 0;
    piggies[_tokenId].uintDetails.expiry = 0;
    piggies[_tokenId].uintDetails.settlementPrice = 0;
    piggies[_tokenId].uintDetails.reqCollateral = 0;
    piggies[_tokenId].uintDetails.collateralDecimals = 0;
    piggies[_tokenId].uintDetails.arbitrationLock = 0;
    piggies[_tokenId].uintDetails.writerProposedPrice = 0;
    piggies[_tokenId].uintDetails.holderProposedPrice = 0;
    piggies[_tokenId].uintDetails.arbiterProposedPrice = 0;
    piggies[_tokenId].uintDetails.rfpNonce = 0;
    piggies[_tokenId].flags.isRequest = false;
    piggies[_tokenId].flags.isEuro = false;
    piggies[_tokenId].flags.isPut = false;
    piggies[_tokenId].flags.hasBeenCleared = false;
    piggies[_tokenId].flags.writerHasProposedNewArbiter = false;
    piggies[_tokenId].flags.holderHasProposedNewArbiter = false;
    piggies[_tokenId].flags.writerHasProposedPrice = false;
    piggies[_tokenId].flags.holderHasProposedPrice = false;
    piggies[_tokenId].flags.arbiterHasProposedPrice = false;
    piggies[_tokenId].flags.arbiterHasConfirmed = false;
    piggies[_tokenId].flags.arbitrationAgreement = false;
  }
}
