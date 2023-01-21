// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

/**                                                                                 
          ..........                                                            
          ..........                                                            
          .....*****.....                                                       
          .....*****.....                                                       
          .....**********....................                                   
          .....**********....................                                   
               .....********************(((((..........                         
               .....********************(((((..........                         
          .....***************(((((((((((((((((((((((((.....                    
          .....***************(((((((((((((((((((((((((.....                    
               .....*****((((((((((((((((((((***************.....               
               .....*****((((((((((((((((((((***************.....               
          .....***************(((((((((((((((((((((((((((((((((((.....          
          .....***************(((((((((((((((((((((((((((((((((((.....          
     ......................................................................     
     ......................................................................     
     .....%%%%%%%%%%%%%%%*****@@@@@@@@@@(((((((((((((((@@@@@@@@@@.....          
     .....%%%%%%%%%%%%%%%*****@@@@@@@@@@(((((((((((((((@@@@@@@@@@.....          
          .....@@@@@@@@@@*****..........(((((((((((((((..........               
          .....@@@@@@@@@@*****..........(((((((((((((((..........               
     .....@@@@@@@@@@**********..........(((((((((((((((..........               
     .....@@@@@@@@@@**********..........(((((((((((((((..........               
          .....@@@@@@@@@@***************((((((((((((((((((((..........          
          .....@@@@@@@@@@***************((((((((((((((((((((..........          
          .....@@@@@@@@@@@@@@@*****(((((((((((((((((((((((((.....               
          .....@@@@@@@@@@@@@@@*****(((((((((((((((((((((((((.....               
     .....@@@@@@@@@@@@@@@@@@@@@@@@@**********(((((**********@@@@@.....          
     .....@@@@@@@@@@@@@@@@@@@@@@@@@**********(((((**********@@@@@.....          
.....@@@@@@@@@@@@@@@@@@@@(((((@@@@@(((((((((((((((((((((((((@@@@@@@@@@.....     
.....@@@@@@@@@@@@@@@@@@@@(((((@@@@@(((((((((((((((((((((((((@@@@@@@@@@.....     
          .....@@@@@.....(((((((((((((((((((((((((((((((((((.....               
          .....@@@@@.....(((((((((((((((((((((((((((((((((((.....               
               .....(((((((((((((((((((((((((((((((((((.....                    
               .....(((((((((((((((((((((((((((((((((((.....                    
          .....((((((((((((((((((((((((((((((((((((((((.....                    
          .....((((((((((((((((((((((((((((((((((((((((.....                    
     .....**************************************************.....               
     .....**************************************************.....               
     ............................................................               
     ............................................................    
 @@@@@@@             @@   @@                                  
/@@////@@           /@@  //                                   
/@@   /@@  @@@@@@  @@@@@@ @@  @@@@@@  @@@@@@@                 
/@@@@@@@  @@////@@///@@/ /@@ @@////@@//@@///@@                
/@@////  /@@   /@@  /@@  /@@/@@   /@@ /@@  /@@                
/@@      /@@   /@@  /@@  /@@/@@   /@@ /@@  /@@                
/@@      //@@@@@@   //@@ /@@//@@@@@@  @@@  /@@                
//        //////     //  //  //////  ///   //                 
 @@@@@@@                    @@                              @@
/@@////@@                  /@@                             /@@
/@@   /@@ @@@@@@  @@@@@@  @@@@@@  @@@@@@   @@@@@   @@@@@@  /@@
/@@@@@@@ //@@//@ @@////@@///@@/  @@////@@ @@///@@ @@////@@ /@@
/@@////   /@@ / /@@   /@@  /@@  /@@   /@@/@@  // /@@   /@@ /@@
/@@       /@@   /@@   /@@  /@@  /@@   /@@/@@   @@/@@   /@@ /@@
/@@      /@@@   //@@@@@@   //@@ //@@@@@@ //@@@@@ //@@@@@@  @@@
//       ///     //////     //   //////   /////   //////  /// 
*/

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { SafeMath } from "lib/openzeppelin-contracts/contracts/utils/math/SafeMath.sol";
import { FixedPointMathLib } from "./lib/FixedPointMathLibV2.sol";
import { PotionPair } from "./PotionPair.sol";

/**
  @author 10xdegen
  @notice Potion Liquidity Pool implementation.
  @dev Inspired by the ERC4626 tokenized vault adapted for use with Potion (modified sudoswap) trading pairs.
  
  The vault's backing assset is the underlying PotionPair.
  The quanitity of the backing asset is equal to the sum of the quantity of NFTs that have been deposited into the pool.
  When shares of the pools are redeemed, they are conisdered redeemable for a non-determinstic NFT from the pool
  and the amounf of ETH in the pool divided by the quantity of NFTs.
  when a user mints an LP token they deposit 1 NFT and an equal amount of
  ETH/ERC20 in the pool (calculated based on the pricing logic of the pair).
  Each token is can be redeemed for 1 NFT and its ETH/ERC20 equivalent.


  If the pool liquidity is drained of NFTs, the remaining LP tokens will
  be redeemable for the equivalent of the NFTs in fungible tokens.

  This means that impermanent loss can mean loss of your NFTs!
  only deposit floor NFTs you would be comfortable selling.

  There is also no guarantee that the NFTs you deposited will be the ones you
  withdraw when you unstake. You have been warned.

  (Because everybody reads the contract, right?)

  - 10xdegen
*/
contract PotionPool is ERC20 {
  using SafeMath for uint256;
  using FixedPointMathLib for uint256;

  /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

  event Deposit(
    address indexed caller,
    address indexed receiver,
    address indexed owner,
    uint256[] nftIds,
    uint256 fungibleTokens,
    uint256 shares
  );

  event Withdraw(
    address indexed caller,
    address indexed receiver,
    address indexed owner,
    uint256[] nftIds,
    uint256 fungibleTokens,
    uint256 fromFees,
    uint256 shares
  );

  /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

  // The pair this LP is associated with.
  // Swaps are done directly via the pair (or router).
  // The Pool manages deposit/withdrawal
  // logic for the pair like a shared vault.
  PotionPair public immutable pair;

  // The initial number of shares minted per deposited NFT when the pool has accrued no fees.
  uint256 public constant SHARES_PER_NFT = 10**20;

  // The minimum nuber of NFTs a pair must hold to support trading.
  uint256 public constant MIN_NFT_LIQUIDITY = 1;

  /*//////////////////////////////////////////////////////////////
                             MUTABLE STATE
        //////////////////////////////////////////////////////////////*/

  /*//////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
        //////////////////////////////////////////////////////////////*/

  constructor(
    PotionPair _pair,
    string memory _name,
    string memory _symbol
  ) ERC20(_name, _symbol, 18) {
    pair = _pair;
  }

  /*//////////////////////////////////////////////////////////////
                        WRITE FUNCS
    //////////////////////////////////////////////////////////////*/

  /**
    @notice Deposits the NFTs and (fungible) Tokens to the vault. The token deposit must equal numNfts * nftSpotPrice(). Returns an LP token which is used to redeem assets from the vault.
    @param nftIds The list of NFT ids to deposit.
    @param tokens The amount of tokens to deposit. After the initial deposit, must be greater than getRequiredDeposit(nftIds.length).
    @param owner The owner of the NFTs and tokens to deposit.
    @param receiver The receiver of newly minted shares.
    @return shares The number of ERC20 vault shares minted.
  */
  function depositNFTsAndTokens(
    uint256[] memory nftIds,
    uint256 tokens,
    address owner,
    address receiver
  ) external payable returns (uint256 shares) {
    uint256 supply = totalSupply;
    uint256 numNfts = nftIds.length;
    shares = getSharesForAssets(numNfts);

    // in order to simplify deposit/withdrawal of fee rewards without staking,
    // we require the fee per share to be included in the deposit..
    if (supply > 0) {
      // require deposit to be 50/50 between NFTs and tokens+fees
      uint256 tokenEquivalent = getRequiredDeposit(numNfts);
      require(
        tokens >= tokenEquivalent,
        "Token deposit should be greater than getRequiredDeposit(numNfts)"
      );
      // calcualte shares
      require(shares != 0, "ZERO_SHARES");
    }

    // deposit NFTs
    pair.depositNfts(owner, nftIds);

    // deposit tokens
    pair.depositFungibleTokens{ value: msg.value }(owner, tokens);

    // mint tokens to depositor
    _mint(receiver, shares);
    emit Deposit(msg.sender, owner, receiver, nftIds, tokens, shares);
  }

  // returns the number of NFTs and fungible tokens withdrawn.
  // when the number of shares redeemed is less than the number required to withdraw an NFT,
  //
  // the remaining shares will converted to a sell order for the equivalent in NFTs.
  function redeemShares(
    uint256 shares,
    address receiver,
    address owner
  )
    public
    returns (
      uint256[] memory nftIds,
      uint256 tokens,
      uint256 fromFees
    )
  {
    require(shares <= totalSupply, "INSUFFICIENT_SHARES");

    // get quantities to redeem
    uint256 numNfts;
    uint256 protocolFee;
    (numNfts, tokens, fromFees, protocolFee) = getAssetsForShares(shares);

    // save gas on limited approvals
    if (msg.sender != owner) {
      uint256 allowed = allowance[owner][msg.sender];
      require(allowed >= shares, "INSUFFICIENT_ALLOWANCE");
      if (allowed != type(uint256).max)
        allowance[owner][msg.sender] = allowed.sub(shares);
    }

    // burn the owner's shares (must happen after calculating fees)
    _burn(owner, shares);

    // redeem the first N nfts
    // TODO randomize, or specify id for fee.
    // rarity sorting?
    if (numNfts > 0) {
      nftIds = pair.getAllHeldIds(numNfts);

      // Need to transfer before minting or ERC777s could reenter.
      pair.withdrawNfts(receiver, nftIds);
    }

    if (protocolFee > 0) {
      // send protocol fee to factory
      pair.withdrawFungibleTokens(address(pair.factory()), protocolFee, 0);
    }

    pair.withdrawFungibleTokens(owner, tokens, fromFees);

    // emit withdraw event
    emit Withdraw(
      msg.sender,
      receiver,
      owner,
      nftIds,
      tokens,
      fromFees,
      shares
    );
  }

  /*//////////////////////////////////////////////////////////////
                            READ FUNCS
    //////////////////////////////////////////////////////////////*/

  // get the equivalent value of NFTs in fungible tokens (for deposits/withdrawals).
  function getRequiredDeposit(uint256 numNfts)
    public
    view
    returns (uint256 total)
  {
    (uint256 nftBalance, uint256 tokenBalance) = pair.getBalances();

    return _getRequiredDeposit(numNfts, nftBalance, tokenBalance);
  }

  // returns the total value of assets held in the pool (in the fungible token).
  function getTotalValue() public view returns (uint256 tokenEquivalent) {
    (, uint256 tokenBalance) = pair.getBalances();
    uint256 feeBalance = pair.accruedFees();
    // we multiply token balance by 2 since the NFT value the is equal to the token balance.
    tokenEquivalent = tokenBalance.mul(2).add(feeBalance);
  }

  // returns the number of shares to mint for a deposit of the given amounts.
  function getSharesForAssets(uint256 numNfts)
    public
    view
    returns (uint256 shares)
  {
    uint256 supply = totalSupply;

    if (numNfts == 0) {
      return 0;
    }

    if (supply == 0) {
      // convert the nft into fractional shares internally.
      // shares can be redeemed for whole NFTs or fungible tokens.
      // the initial supplier determines the initial price / deposit ratio.
      return numNfts.mul(SHARES_PER_NFT);
    }

    // the shares minted is equal to the ratio between the value of deposit to the total value in the pool
    uint256 totalValue = getTotalValue();

    // depositValue = numNfts * spotPrice * 2
    // shares = depositValue / totalValue
    shares = getRequiredDeposit(numNfts.mul(2)).mul(supply).div(totalValue);
  }

  // returns the number of nfts and tokens redeemed by the given nuber of shares.
  function getAssetsForShares(uint256 shares)
    public
    view
    returns (
      uint256 numNfts,
      uint256 tokenAmount,
      uint256 fromFees,
      uint256 protocolFee
    )
  {
    if (shares == 0) {
      return (0, 0, 0, 0);
    }

    (uint256 nftBalance, uint256 tokenBalance) = pair.getBalances();
    uint256 feeBalance = pair.accruedFees();
    uint256 supply = totalSupply;
    uint256 totalValue = getTotalValue();

    // handle case where 100% of the pool is redeemed.
    if (shares == supply) {
      // redeem all NFTs and tokens
      return (nftBalance, tokenBalance, feeBalance, 0);
    }

    // calculate the pro-rata share of the pool NFTs.
    // we attempt to withdraw the maximum number of NFTs for the given shares, rounding up.
    numNfts = nftBalance.mulDivUp(shares, supply);

    // when few NFTs exist in the pool, rounding up may result in a value greater than the supplied shares.
    // we will round down in that case, and add the difference to the remainder.
    uint256 minShares = getSharesForAssets(numNfts);
    if (minShares > shares) {
      numNfts = numNfts.sub(1);
      minShares = getSharesForAssets(numNfts);
    }

    // when few NFTs exist in the pool, withdrawals may result in withdrawing the last NFT.
    // in that case, we will withdraw the equivalent value of the last NFT as fungible tokens.
    if (numNfts > nftBalance.sub(MIN_NFT_LIQUIDITY)) {
      numNfts = nftBalance.sub(MIN_NFT_LIQUIDITY);
      minShares = getSharesForAssets(numNfts);
    }

    // catch-all to prevent overflow.
    require(
      shares >= minShares,
      "internal error: share value is less than withdraw value"
    );

    // withdraw tokens equal to the value of the withdrawn NFTs.
    tokenAmount = _getRequiredDeposit(numNfts, nftBalance, tokenBalance);

    // calculate the value of the remainder to be withdrawn (as fungible tokens).
    // this remainder is redeemed as a fractional sale to the pool,
    // and the protocol fee is deducted.
    uint256 remainder;
    (remainder, protocolFee) = _calculateRemainder(
      shares,
      minShares,
      totalValue,
      supply
    );

    // remainders are redeemed first from fees, then from the pool.
    fromFees = FixedPointMathLib.min(remainder, feeBalance);

    tokenAmount = tokenAmount.add(remainder.sub(fromFees));
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL READ FUNCS
    //////////////////////////////////////////////////////////////*/

  // get the equivalent value of NFTs in fungible tokens (for deposits).
  // must equal the value of the NFTs in the pool.
  // the returned fee is included in the total, only used for internal calculations.
  function _getRequiredDeposit(
    uint256 numNfts,
    uint256 nftBalance,
    uint256 tokenBalance
  ) internal pure returns (uint256 total) {
    if (nftBalance == 0) {
      // the pool is being initialized, no min deposit required.
      return 0;
    }
    // simply equal to the ratio of assets in the pool.
    total = numNfts.mul(tokenBalance).div(nftBalance);
  }

  function _calculateRemainder(
    uint256 shares,
    uint256 minShares,
    uint256 totalValue,
    uint256 supply
  ) internal view returns (uint256 remainder, uint256 protocolFee) {
    // remainder redeemed from the remaining shares.
    remainder = shares.sub(minShares).mulDivDown(totalValue, supply);
    if (remainder == 0) {
      return (0, 0);
    }

    // there is a remainder, get the sale value & fee
    uint256 sellPrice;
    (sellPrice, , protocolFee) = pair.getSellNFTQuote(2);
    uint256 fungibleEquivalent = getRequiredDeposit(2);
    remainder = remainder.mul(sellPrice).div(fungibleEquivalent);
    protocolFee = protocolFee.mul(sellPrice).div(fungibleEquivalent);
  }
}
