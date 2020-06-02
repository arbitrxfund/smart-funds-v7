pragma solidity ^0.6.0;

/*
  The SmartFund contract is what holds all the tokens and ether, and contains all the logic
  for calculating its value (and ergo profit), allows users to deposit/withdraw their funds,
  and calculates the fund managers cut of the funds profit among other things.
  The SmartFund gets the value of its token holdings (in Ether) and trades through the ExchangePortal
  contract. This means that as new exchange capabalities are added to new exchange portals, the
  SmartFund will be able to upgrade to a new exchange portal, and trade a wider variety of assets
  with a wider variety of exchanges. The SmartFund is also connected to a PermittedExchanges contract,
  which determines which exchange portals the SmartFund is allowed to connect to, restricting
  the fund owners ability to connect to a potentially malicious contract.
*/


import "../interfaces/ExchangePortalInterface.sol";
import "../interfaces/PoolPortalInterface.sol";
import "../interfaces/ConvertPortalInterface.sol";

import "../interfaces/PermittedExchangesInterface.sol";
import "../interfaces/PermittedPoolsInterface.sol";
import "../interfaces/PermittedConvertsInterface.sol";

import "../../zeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "../../zeppelin-solidity/contracts/access/Ownable.sol";
import "../../zeppelin-solidity/contracts/math/SafeMath.sol";
import "../../zeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";

abstract contract SmartFundCore is Ownable, IERC20 {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  // Total amount of ether or stable deposited by all users
  uint256 public totalWeiDeposited = 0;

  // Total amount of ether or stable withdrawn by all users
  uint256 public totalWeiWithdrawn = 0;

  // The Interface of the Exchange Portal
  ExchangePortalInterface public exchangePortal;

  // The Interface of pool portall
  PoolPortalInterface public poolPortal;

  // The Interface of convert portal
  ConvertPortalInterface public convertPortal;

  // The Smart Contract which stores the addresses of all the authorized Exchange Portals
  PermittedExchangesInterface public permittedExchanges;

  // The Smart Contract which stores the addresses of all the authorized Pools Portals
  PermittedPoolsInterface public permittedPools;

  // The Smart Contract which stores the addresses of all the authorized Converts Portals
  PermittedConvertsInterface public permittedConverts;

  // KyberExchange recognizes ETH by this address
  IERC20 constant internal ETH_TOKEN_ADDRESS = IERC20(0x00eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee);

  // For ERC20 compliance
  string public name;

  // The maximum amount of tokens that can be traded via the smart fund
  uint256 public MAX_TOKENS = 50;

  // Percentages are rounded to 3 decimal places
  uint256 public TOTAL_PERCENTAGE = 10000;

  // Address of the platform that takes a cut from the fund manager success cut
  address public platformAddress;

  // The percentage of earnings paid to the fund manager. 10000 = 100%
  // e.g. 10% is 1000
  uint256 public successFee;

  // The percentage of fund manager earnings paid to the platform. 10000 = 100%
  // e.g. 10% is 1000
  uint256 public platformFee;

  // An array of all the erc20 token addresses the smart fund holds
  address[] public tokenAddresses;

  // Boolean value that determines whether the fund accepts deposits from anyone or
  // only specific addresses approved by the manager
  bool public onlyWhitelist = false;

  // Mapping of addresses that are approved to deposit if the manager only want's specific
  // addresses to be able to invest in their fund
  mapping (address => bool) public whitelist;

  uint public version = 7;

  // the total number of shares in the fund
  uint256 public totalShares = 0;

  // Denomination of initial shares
  uint256 constant internal INITIAL_SHARES = 10 ** 18;

  // The earnings the fund manager has already cashed out
  uint256 public fundManagerCashedOut = 0;

  // COMPOUND ETH wrapper address
  address public cEther;

  // for ETH and USD fund this asset different
  address public coreFundAsset;

  // how many shares belong to each address
  mapping (address => uint256) public addressToShares;

  // so that we can easily check that we don't add duplicates to our array
  mapping (address => bool) public tokensTraded;

  // this is really only being used to more easily show profits, but may not be necessary
  // if we do a lot of this offchain using events to track everything
  // total `depositToken` deposited - total `depositToken` withdrawn
  mapping (address => int256) public addressesNetDeposit;

  // Events
  event Loan(
    address tokenAddress,
    uint256 tokenAmount,
    address underlyingAddress,
    uint256 underlyingAmount);

  event Redeem(
    address tokenAddress,
    uint256 tokenAmount,
    address underlyingAddress,
    uint256 underlyingAmount);

  event BuyPool(
    address poolAddress,
    uint256 poolAmount,
    address firstConnectorAddress,
    address secondConnectorAddress,
    uint256 firstConnectorBalance,
    uint256 secondConnectorBalance);

  event SellPool(
    address poolToken,
    uint256 amount,
    address firstConnectorAddress,
    address secondConnectorAddress,
    uint256 firstConnectorBalance,
    uint256 secondConnectorBalance);

  event Deposit(address indexed user, uint256 amount, uint256 sharesReceived, uint256 totalShares);
  event Withdraw(address indexed user, uint256 sharesRemoved, uint256 totalShares);
  event Trade(address src, uint256 srcAmount, address dest, uint256 destReceived);

  event SmartFundCreated(address indexed owner);

  // enum
  enum PortalType { Bancor, Uniswap }

  constructor(
    address _owner,
    string memory _name,
    uint256 _successFee,
    uint256 _platformFee,
    address _platformAddress,
    address _exchangePortalAddress,
    address _permittedExchangesAddress,
    address _permittedPoolsAddress,
    address _poolPortalAddress,
    address _convertPortalAddress,
    address _cEther,
    address _coreFundAsset,
    address _permittedConvertsAddress
  )public{
    // never allow a 100% fee
    require(_successFee < TOTAL_PERCENTAGE);
    require(_platformFee < TOTAL_PERCENTAGE);

    name = _name;
    successFee = _successFee;
    platformFee = _platformFee;

    if(_owner == address(0)){
      transferOwnership(msg.sender);
    }
    else{
      transferOwnership(_owner);
    }

    if(_platformAddress == address(0)){
      platformAddress = msg.sender;
    }
    else{
      platformAddress = _platformAddress;
    }

    // Initial Token is Ether
    tokenAddresses.push(address(ETH_TOKEN_ADDRESS));

    // Initial interfaces
    exchangePortal = ExchangePortalInterface(_exchangePortalAddress);
    permittedExchanges = PermittedExchangesInterface(_permittedExchangesAddress);
    permittedPools = PermittedPoolsInterface(_permittedPoolsAddress);
    poolPortal = PoolPortalInterface(_poolPortalAddress);
    convertPortal = ConvertPortalInterface(_convertPortalAddress);
    permittedConverts = PermittedConvertsInterface(_permittedConvertsAddress);

    cEther = _cEther;
    coreFundAsset = _coreFundAsset;

    emit SmartFundCreated(owner());
  }

  // virtual methods
  // USD and ETH based funds have different implements of this methods
  function calculateFundValue() public virtual view returns (uint256);
  function getTokenValue(IERC20 _token) public virtual view returns (uint256);


  /**
  * @dev Sends (_mul/_div) of every token (and ether) the funds holds to _withdrawAddress
  *
  * @param _mul                The numerator
  * @param _div                The denominator
  * @param _withdrawAddress    Address to send the tokens/ether to
  * @param _convert            if true, convert assets to base asset
  *
  * NOTE: _withdrawAddress changed from address to address[] arrays because balance calculation should be performed
  * once for all usesr who wants to withdraw from the current balance.
  *
  */
  function _withdraw(
    uint256[] memory _mul,
    uint256[] memory _div,
    address[] memory _withdrawAddress,
    bool _convert
    )
    internal
    returns (uint256)
  {
    for (uint8 i = 1; i < tokenAddresses.length; i++) {
      // Transfer that _mul/_div of each token we hold to the user
      IERC20 token = IERC20(tokenAddresses[i]);
      uint256 fundAmount = token.balanceOf(address(this));

      // Transfer ERC20 to _withdrawAddress
      for(uint8 j = 0; j < _withdrawAddress.length; j++){
        // calculate withdraw ERC20 share
        uint256 payoutAmount = fundAmount.mul(_mul[j]).div(_div[j]);
        // Check if need convert ERC20 to fund core asset
        if(_convert){
          // Convert ERC20
          tryConvertToCoreAsset(
            address(token),
            payoutAmount,
            coreFundAsset,
            _withdrawAddress[j]
          );
        }else{
          // Just withdarw ERC20
          token.transfer(_withdrawAddress[j], payoutAmount);
        }
      }
    }
    // Transfer ETH to _withdrawAddress
    uint256 etherBalance = address(this).balance;
    for(uint8 k = 0; k < _withdrawAddress.length; k++){
      // calculate withdraw ETH share
      uint256 etherPayoutAmount = (etherBalance).mul(_mul[k]).div(_div[k]);

      // Check if need convert ETH to fund core asset
      if(_convert && coreFundAsset != address(ETH_TOKEN_ADDRESS)){
        // Convert ETH
        tryConvertToCoreAsset(
         address(ETH_TOKEN_ADDRESS),
         etherPayoutAmount,
         coreFundAsset,
         _withdrawAddress[k]
        );
      }else{
        // Just withdarw ETH
        payable(_withdrawAddress[k]).transfer(etherPayoutAmount);
      }
    }
  }

  // helper which try convert input asset to core fund asset (ETH or USD)
  function tryConvertToCoreAsset(
    address _source,
    uint256 _amount,
    address _destanation,
    address _receiver
  )
    private
  {
    if(_source == address(ETH_TOKEN_ADDRESS)){
      try convertPortal.convert.value(_amount)(
        _source,
        _amount,
        _destanation,
        _receiver)
       {}
       catch{
        // if can't convert send ETH without convert
        payable(_receiver).transfer(_amount);
       }
    }
    else{
      IERC20(_source).approve(address(convertPortal), _amount);
      try convertPortal.convert(
        _source,
        _amount,
        _destanation,
        _receiver)
      {}
      catch{
        // if can't convert send ERC20 without convert
        IERC20(_source).transfer(_receiver, _amount);
      }
    }
 }

  /**
  * @dev Withdraws users fund holdings, sends (userShares/totalShares) of every held token
  * to msg.sender, defaults to 100% of users shares.
  *
  * @param _percentageWithdraw    The percentage of the users shares to withdraw.
  */
  function withdraw(uint256 _percentageWithdraw, bool _convert) external {
    require(totalShares != 0);

    uint256 percentageWithdraw = (_percentageWithdraw == 0) ? TOTAL_PERCENTAGE : _percentageWithdraw;

    uint256 addressShares = addressToShares[msg.sender];

    uint256 numberOfWithdrawShares = addressShares.mul(percentageWithdraw).div(TOTAL_PERCENTAGE);

    uint256 fundManagerCut;
    uint256 fundValue;

    // Withdraw the users share minus the fund manager's success fee
    (fundManagerCut, fundValue, ) = calculateFundManagerCut();

    uint256 withdrawShares = numberOfWithdrawShares.mul(fundValue.sub(fundManagerCut)).div(fundValue);

    // prepare call data for _withdarw
    address[] memory spenders = new address[](1);
    spenders[0] = msg.sender;

    uint256[] memory value = new uint256[](1);
    value[0] = totalShares;

    uint256[] memory cut = new uint256[](1);
    cut[0] = withdrawShares;

    // do withdraw
    _withdraw(cut, value, spenders,_convert);

    // Store the value we are withdrawing in ether
    uint256 valueWithdrawn = fundValue.mul(withdrawShares).div(totalShares);

    totalWeiWithdrawn = totalWeiWithdrawn.add(valueWithdrawn);
    addressesNetDeposit[msg.sender] -= int256(valueWithdrawn);

    // Subtract from total shares the number of withdrawn shares
    totalShares = totalShares.sub(numberOfWithdrawShares);
    addressToShares[msg.sender] = addressToShares[msg.sender].sub(numberOfWithdrawShares);

    emit Withdraw(msg.sender, numberOfWithdrawShares, totalShares);
  }

  /**
  * @dev Facilitates a trade of the funds holdings via the exchange portal
  *
  * @param _source            ERC20 token to convert from
  * @param _sourceAmount      Amount to convert (in _source token)
  * @param _destination       ERC20 token to convert to
  * @param _type              The type of exchange to trade with
  * @param _additionalArgs    Array of bytes32 additional arguments
  * @param _additionalData    For any size data (if not used set just 0x0)
  * @param _minReturn         Min expected amount of destination
  */
  function trade(
    IERC20 _source,
    uint256 _sourceAmount,
    IERC20 _destination,
    uint256 _type,
    bytes32[] calldata _additionalArgs,
    bytes calldata _additionalData,
    uint256 _minReturn
  ) external onlyOwner {
    require(_minReturn > 0, "min return should be more than 0");

    uint256 receivedAmount;

    if (_source == ETH_TOKEN_ADDRESS) {
      // Make sure fund contains enough ether
      require(address(this).balance >= _sourceAmount, "Not enough ETH");
      // Call trade on ExchangePortal along with ether
      receivedAmount = exchangePortal.trade.value(_sourceAmount)(
        _source,
        _sourceAmount,
        _destination,
        _type,
        _additionalArgs,
        _additionalData
      );
    } else {
      _source.approve(address(exchangePortal), _sourceAmount);
      receivedAmount = exchangePortal.trade(
        _source,
        _sourceAmount,
        _destination,
        _type,
        _additionalArgs,
        _additionalData
      );
    }

    require(receivedAmount >= _minReturn, "received amount can not be less than min return");

    _addToken(address(_destination));
    emit Trade(address(_source), _sourceAmount, address(_destination), receivedAmount);
  }


  /**
  * @dev buy pool via pool portal
  *
  * @param _amount        For Bancor amount it's relay, for Uniswap amount it's ETH
  * @param _type          type of pool (0 - Bancor, 1 - Uniswap)
  * @param _poolToken     address of relay for Bancor and exchange for Uniswap
  */
  function buyPool(
   uint256 _amount,
   uint _type,
   IERC20 _poolToken
  )
  external onlyOwner {
   // buy Bancor pool
   if(_type == uint(PortalType.Bancor))
    _buyBancorPool(_amount, _type, _poolToken);

   // buy Uniswap pool
   if(_type == uint(PortalType.Uniswap))
    _buyUniswapPool(_amount, _type, _poolToken);

    // Add pool as ERC20 for withdraw
    _addToken(address(_poolToken));
  }

  // Helper for buy Uniswap pool
  function _buyUniswapPool(
    uint256 _amount,
    uint _type,
    IERC20 _poolToken
  )
  private
  {
    // approve connector
    IERC20 token = IERC20(poolPortal.getTokenByUniswapExchange(address(_poolToken)));
    token.approve(address(poolPortal), token.balanceOf(address(this)));

    // buy pool via ETH amount payable
    (uint256 firstConnectorAmountSent,
    uint256 secondConnectorAmountSent,) = poolPortal.buyPool.value(_amount)(
     _amount,
     _type,
    _poolToken
    );

    // reset approve
    token.approve(address(poolPortal), 0);

    // emit event
    emit BuyPool(
      address(_poolToken),
      _amount,
      address(ETH_TOKEN_ADDRESS),
      address(token),
      firstConnectorAmountSent,
      secondConnectorAmountSent);
  }

  // Helper for buy Bancor pool
  function _buyBancorPool(
    uint256 _amount,
    uint _type,
    IERC20 _poolToken
  )
   private
  {
    // get connectors
    (IERC20 bancorConnector,
       IERC20 ercConnector) = poolPortal.getBancorConnectorsByRelay(address(_poolToken));

    // Approve all connectors to pool portal (pool calculates the required amount dynamicly)
    bancorConnector.approve(address(poolPortal), bancorConnector.balanceOf(address(this)));
    ercConnector.approve(address(poolPortal), ercConnector.balanceOf(address(this)));

    // buy pool(relay) via relay amount not payable
    // buy pool via ETH amount payable
    (uint256 firstConnectorAmountSent,
    uint256 secondConnectorAmountSent,) = poolPortal.buyPool(
     _amount,
     _type,
    _poolToken
    );

    // reset approve
    bancorConnector.approve(address(poolPortal), 0);
    ercConnector.approve(address(poolPortal), 0);

    // emit event
    emit BuyPool(
      address(_poolToken),
      _amount,
      address(bancorConnector),
      address(ercConnector),
      firstConnectorAmountSent,
      secondConnectorAmountSent);
  }


  /**
  * @dev sell pool via pool portal
  *
  * @param _amount        amount of Bancor relay or Uniswap exchange to sell
  * @param _type          type of pool (0 - Bancor, 1 - Uniswap)
  * @param _poolToken     address of Bancor relay or Uniswap exchange
  */
  function sellPool(
    uint256 _amount,
    uint _type,
    IERC20 _poolToken
  )
  external onlyOwner {
    // sell via Bancor
    if(_type == uint(PortalType.Bancor)){
      _sellBancorPool(_poolToken, _amount);
    }
    // sell via Uniswap
    else if(_type == uint(PortalType.Uniswap)){
      _sellUniswapPool(_poolToken, _amount);
    }
    else{
       revert("Unknown pool type");
    }
  }

  // Helper for sell Bancor pool
  function _sellBancorPool(IERC20 _poolToken, uint256 _amount)
   private
  {
    // get bancor connectors addresses
    (IERC20 bancorConnector,
      IERC20 ercConnector) = poolPortal.getBancorConnectorsByRelay(
        address(_poolToken));

     // approve
     _poolToken.approve(address(poolPortal), _amount);

     // sell
     (uint256 firstConnectorAmountReceive,
      uint256 secondConnectorAmountReceive,) = poolPortal.sellPool(
       _amount,
       uint(PortalType.Bancor),
      _poolToken
     );

    // add returned assets in fund as tokens (for case if manager removed this assets)
    _addToken(address(bancorConnector));
    _addToken(address(ercConnector));

    // event
    emit SellPool(
      address(_poolToken),
      _amount,
      address(bancorConnector),
      address(ercConnector),
      firstConnectorAmountReceive,
      secondConnectorAmountReceive);
  }

  // Helper sell Uniswap pool
  function _sellUniswapPool(IERC20 _poolToken, uint256 _amount)
   private
  {
    // extract Uniswap ERC20 connector
    address tokenAddress = poolPortal.getTokenByUniswapExchange(address(_poolToken));

    // approve
    _poolToken.approve(address(poolPortal), _amount);

    // sell
    (uint256 firstConnectorAmountReceive,
     uint256 secondConnectorAmountReceive,) = poolPortal.sellPool(
      _amount,
      uint(PortalType.Uniswap),
     _poolToken
    );

    // add returned asset to fund(for case if manager removed this asset)
    _addToken(tokenAddress);

    // event
    emit SellPool(
      address(_poolToken),
      _amount,
      address(ETH_TOKEN_ADDRESS),
      tokenAddress,
      firstConnectorAmountReceive,
      secondConnectorAmountReceive);
  }

  // return all tokens addresses from fund
  function getAllTokenAddresses() external view returns (address[] memory) {
    return tokenAddresses;
  }

  /**
  * @dev Adds a token to tokensTraded if it's not already there
  * @param _token    The token to add
  */
  function _addToken(address _token) internal {
    // don't add token to if we already have it in our list
    if (tokensTraded[_token] || (_token == address(ETH_TOKEN_ADDRESS)))
      return;

    tokensTraded[_token] = true;
    tokenAddresses.push(_token);
    uint256 tokenCount = tokenAddresses.length;

    // we can't hold more than MAX_TOKENS tokens
    require(tokenCount <= MAX_TOKENS);
  }

  /**
  * @dev Removes a token from tokensTraded
  *
  * @param _token         The address of the token to be removed
  * @param _tokenIndex    The index of the token to be removed
  *
  */
  function removeToken(address _token, uint256 _tokenIndex) public onlyOwner {
    require(_token != address(ETH_TOKEN_ADDRESS));
    require(tokensTraded[_token]);
    require(IERC20(_token).balanceOf(address(this)) == 0);
    require(tokenAddresses[_tokenIndex] == _token);

    tokensTraded[_token] = false;

    // remove token from array
    uint256 arrayLength = tokenAddresses.length - 1;
    tokenAddresses[_tokenIndex] = tokenAddresses[arrayLength];
    delete tokenAddresses[arrayLength];
    tokenAddresses.pop();
  }

  /**
  * @dev buy Compound cTokens
  *
  * @param _amount       amount of ERC20 or ETH
  * @param _cToken       cToken address
  */
  function compoundMint(uint256 _amount, address _cToken) external onlyOwner{
    uint256 receivedAmount;
    address underlying;

    if(_cToken == address(cEther)){
      underlying = address(ETH_TOKEN_ADDRESS);
      receivedAmount = exchangePortal.compoundMint.value(_amount)(
        _amount,
        _cToken
      );
    }else{
      underlying = exchangePortal.getCTokenUnderlying(_cToken);
      IERC20(underlying).approve(address(exchangePortal), _amount);
      receivedAmount = exchangePortal.compoundMint(
        _amount,
        _cToken
      );
    }

    _addToken(_cToken);

    emit Loan(_cToken, receivedAmount, underlying, _amount);
  }

  /**
  * @dev sell certain percent of Ctokens to Compound
  *
  * @param _percent      percent from 1 to 100
  * @param _cToken       cToken address
  */
  function compoundRedeemByPercent(uint256 _percent, address _cToken) external onlyOwner {
    // get cToken amount by percent
    uint256 amount = exchangePortal.getPercentFromCTokenBalance(
      _percent,
      _cToken,
      address(this)
    );

    // get underlying address
    address underlying = (_cToken == cEther)
    ? address(ETH_TOKEN_ADDRESS)
    : exchangePortal.getCTokenUnderlying(_cToken);

    // Approve
    IERC20(_cToken).approve(address(exchangePortal), amount);

    // Redeem
    uint256 receivedAmount = exchangePortal.compoundRedeemByPercent(
      _percent,
      _cToken
    );

    // Add token
    _addToken(underlying);

    // emit event
    emit Redeem(_cToken, amount, underlying, receivedAmount);
  }


  // get all fund data in one call
  function getSmartFundData() external view returns (
    address _owner,
    string memory _name,
    uint256 _totalShares,
    address[] memory _tokenAddresses,
    uint256 _successFee
  ) {
    _owner = owner();
    _name = name;
    _totalShares = totalShares;
    _tokenAddresses = tokenAddresses;
    _successFee = successFee;
  }

  /**
  * @dev Calculates the funds profit
  *
  * @return The funds profit in deposit token (Ether)
  */
  function calculateFundProfit() public view returns (int256) {
    uint256 fundValue = calculateFundValue();

    return int256(fundValue) + int256(totalWeiWithdrawn) - int256(totalWeiDeposited);
  }

  /**
  * @dev Calculates the amount of shares received according to ether deposited
  *
  * @param _amount    Amount of ether to convert to shares
  *
  * @return Amount of shares to be received
  */
  function calculateDepositToShares(uint256 _amount) public view returns (uint256) {
    uint256 fundManagerCut;
    uint256 fundValue;

    // If there are no shares in the contract, whoever deposits owns 100% of the fund
    // we will set this to 10^18 shares, but this could be any amount
    if (totalShares == 0)
      return INITIAL_SHARES;

    (fundManagerCut, fundValue, ) = calculateFundManagerCut();

    uint256 fundValueBeforeDeposit = fundValue.sub(_amount).sub(fundManagerCut);

    if (fundValueBeforeDeposit == 0)
      return 0;

    return _amount.mul(totalShares).div(fundValueBeforeDeposit);

  }


  /**
  * @dev Calculates the fund managers cut, depending on the funds profit and success fee
  *
  * @return fundManagerRemainingCut    The fund managers cut that they have left to withdraw
  * @return fundValue                  The funds current value
  * @return fundManagerTotalCut        The fund managers total cut of the profits until now
  */
  function calculateFundManagerCut() public view returns (
    uint256 fundManagerRemainingCut, // fm's cut of the profits that has yet to be cashed out (in `depositToken`)
    uint256 fundValue, // total value of fund (in `depositToken`)
    uint256 fundManagerTotalCut // fm's total cut of the profits (in `depositToken`)
  ) {
    fundValue = calculateFundValue();
    // The total amount of ether currently deposited into the fund, takes into account the total ether
    // withdrawn by investors as well as ether withdrawn by the fund manager
    // NOTE: value can be negative if the manager performs well and investors withdraw more
    // ether than they deposited
    int256 curtotalWeiDeposited = int256(totalWeiDeposited) - int256(totalWeiWithdrawn.add(fundManagerCashedOut));

    // If profit < 0, the fund managers totalCut and remainingCut are 0
    if (int256(fundValue) <= curtotalWeiDeposited) {
      fundManagerTotalCut = 0;
      fundManagerRemainingCut = 0;
    } else {
      // calculate profit. profit = current fund value - total deposited + total withdrawn + total withdrawn by fm
      uint256 profit = uint256(int256(fundValue) - curtotalWeiDeposited);
      // remove the money already taken by the fund manager and take percentage
      fundManagerTotalCut = profit.mul(successFee).div(TOTAL_PERCENTAGE);
      fundManagerRemainingCut = fundManagerTotalCut.sub(fundManagerCashedOut);
    }
  }

  /**
  * @dev Allows the fund manager to withdraw their cut of the funds profit
  */
  function fundManagerWithdraw(bool _convert) public onlyOwner {
    uint256 fundManagerCut;
    uint256 fundValue;

    (fundManagerCut, fundValue, ) = calculateFundManagerCut();

    uint256 platformCut = (platformFee == 0) ? 0 : fundManagerCut.mul(platformFee).div(TOTAL_PERCENTAGE);

    // prepare call data for _withdarw
    address[] memory spenders = new address[](2);
    spenders[0] = platformAddress;
    spenders[1] = owner();

    uint256[] memory value = new uint256[](2);
    value[0] = fundValue;
    value[1] = fundValue;

    uint256[] memory cut = new uint256[](2);
    cut[0] = platformCut;
    cut[1] = fundManagerCut - platformCut;

    // do withdraw
    _withdraw(cut, value, spenders, _convert);

    // add report
    fundManagerCashedOut = fundManagerCashedOut.add(fundManagerCut);
  }

  // calculate the current value of an address's shares in the fund
  function calculateAddressValue(address _address) public view returns (uint256) {
    if (totalShares == 0)
      return 0;

    return calculateFundValue().mul(addressToShares[_address]).div(totalShares);
  }

  // calculate the net profit/loss for an address in this fund
  function calculateAddressProfit(address _address) public view returns (int256) {
    uint256 currentAddressValue = calculateAddressValue(_address);

    return int256(currentAddressValue) - addressesNetDeposit[_address];
  }

  // This method was added to easily record the funds token balances, may (should?) be removed in the future
  function getFundTokenHolding(IERC20 _token) external view returns (uint256) {
    if (_token == ETH_TOKEN_ADDRESS)
      return address(this).balance;
    return _token.balanceOf(address(this));
  }

  /**
  * @dev Allows the manager to set whether or not only whitelisted addresses can deposit into
  * their fund
  *
  * @param _onlyWhitelist    boolean representing whether only whitelisted addresses can deposit
  */
  function setWhitelistOnly(bool _onlyWhitelist) external onlyOwner {
    onlyWhitelist = _onlyWhitelist;
  }

  /**
  * @dev Allows the fund manager to whitelist specific addresses to control
  * whos allowed to deposit into the fund
  *
  * @param _user       The user address to whitelist
  * @param _allowed    The status of _user, true means allowed to deposit, false means not allowed
  */
  function setWhitelistAddress(address _user, bool _allowed) external onlyOwner {
    whitelist[_user] = _allowed;
  }

  /**
  * @dev Allows the fund manager to connect to a new [poolPortal
  *
  * @param _newPoolPortal   The address of the new pool portal to use
  */
  function setNewPoolPortal(address _newPoolPortal) public onlyOwner {
    // Require that the new pool portal is permitted by permittedPools
    require(permittedPools.permittedAddresses(_newPoolPortal));

    poolPortal = PoolPortalInterface(_newPoolPortal);
  }

  /**
  * @dev Allows the fund manager to connect to a new exchange portal
  *
  * @param _newExchangePortalAddress    The address of the new exchange portal to use
  */
  function setNewExchangePortal(address _newExchangePortalAddress) public onlyOwner {
    // Require that the new exchange portal is permitted by permittedExchanges
    require(permittedExchanges.permittedAddresses(_newExchangePortalAddress));

    exchangePortal = ExchangePortalInterface(_newExchangePortalAddress);
  }

  /**
  * @dev Allows the fund manager to connect to a new convert portal
  *
  * @param _newConvertPortalAddress    The address of the new convert portal to use
  */
  function setNewConvertPortal(address _newConvertPortalAddress) public onlyOwner {
    // Require that the new exchange portal is permitted by permittedConverts
    require(permittedConverts.permittedAddresses(_newConvertPortalAddress));

    convertPortal = ConvertPortalInterface(_newConvertPortalAddress);
  }

  /**
  * @dev This method is present in the alpha testing phase in case for some reason there are funds
  * left in the SmartFund after all shares were withdrawn
  *
  * @param _token    The address of the token to withdraw
  */
  function emergencyWithdraw(address _token) external onlyOwner {
    require(totalShares == 0);
    if (_token == address(ETH_TOKEN_ADDRESS)) {
      msg.sender.transfer(address(this).balance);
    } else {
      IERC20(_token).transfer(msg.sender, IERC20(_token).balanceOf(address(this)));
    }
  }

  /**
  * @dev Approve 0 for a certain address
  *
  * NOTE: Some ERC20 has no standard approve logic, and not allow do new approve
  * if alredy approved.
  *
  * @param _token                   address of ERC20
  * @param _spender                 address of spender
  */
  function resetApprove(address _token, address _spender) external onlyOwner {
    IERC20(_token).approve(_spender, 0);
  }

  // Fallback payable function in order to be able to receive ether from other contracts
  fallback() external payable {}

  /**
    **************************** ERC20 Compliance ****************************
  **/

  // Note that addressesNetDeposit does not get updated when transferring shares, since
  // this is used for updating off-chain data it doesn't affect the smart contract logic,
  // but is an issue that currently exists

  event Transfer(address indexed from, address indexed to, uint256 value);

  event Approval(address indexed owner, address indexed spender, uint256 value);

  uint8 public decimals = 18;

  string public symbol = "FND";

  mapping (address => mapping (address => uint256)) internal allowed;

  /**
  * @dev Total number of shares in existence
  */
  function totalSupply() external override view returns (uint256) {
    return totalShares;
  }

  /**
  * @dev Gets the balance of the specified address.
  *
  * @param _who    The address to query the the balance of.
  *
  * @return A uint256 representing the amount owned by the passed address.
  */
  function balanceOf(address _who) external override view returns (uint256) {
    return addressToShares[_who];
  }

  /**
  * @dev Transfer shares for a specified address
  *
  * @param _to       The address to transfer to.
  * @param _value    The amount to be transferred.
  *
  * @return true upon success
  */
  function transfer(address _to, uint256 _value) external override returns (bool) {
    require(_to != address(0));
    require(_value <= addressToShares[msg.sender]);

    addressToShares[msg.sender] = addressToShares[msg.sender].sub(_value);
    addressToShares[_to] = addressToShares[_to].add(_value);
    emit Transfer(msg.sender, _to, _value);
    return true;
  }

  /**
   * @dev Transfer shares from one address to another
   *
   * @param _from     The address which you want to send tokens from
   * @param _to       The address which you want to transfer to
   * @param _value    The amount of shares to be transferred
   *
   * @return true upon success
   */
  function transferFrom(address _from, address _to, uint256 _value) external override returns (bool) {
    require(_to != address(0));
    require(_value <= addressToShares[_from]);
    require(_value <= allowed[_from][msg.sender]);

    addressToShares[_from] = addressToShares[_from].sub(_value);
    addressToShares[_to] = addressToShares[_to].add(_value);
    allowed[_from][msg.sender] = allowed[_from][msg.sender].sub(_value);
    emit Transfer(_from, _to, _value);
    return true;
  }

  /**
   * @dev Approve the passed address to spend the specified amount of shares on behalf of msg.sender.
   * Beware that changing an allowance with this method brings the risk that someone may use both the old
   * and the new allowance by unfortunate transaction ordering. One possible solution to mitigate this
   * race condition is to first reduce the spender's allowance to 0 and set the desired value afterwards:
   * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
   *
   * @param _spender    The address which will spend the funds.
   * @param _value      The amount of shares to be spent.
   *
   * @return true upon success
   */
  function approve(address _spender, uint256 _value) external override returns (bool) {
    allowed[msg.sender][_spender] = _value;
    emit Approval(msg.sender, _spender, _value);
    return true;
  }

  /**
   * @dev Function to check the amount of shares that an owner allowed to a spender.
   *
   * @param _owner      The address which owns the funds.
   * @param _spender    The address which will spend the funds.
   *
   * @return A uint256 specifying the amount of shares still available for the spender.
   */
  function allowance(address _owner, address _spender) external override view returns (uint256) {
    return allowed[_owner][_spender];
  }
}