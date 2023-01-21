// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

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
                                                                               
██████╗░░█████╗░████████╗██╗░█████╗░███╗░░██╗
██╔══██╗██╔══██╗╚══██╔══╝██║██╔══██╗████╗░██║
██████╔╝██║░░██║░░░██║░░░██║██║░░██║██╔██╗██║
██╔═══╝░██║░░██║░░░██║░░░██║██║░░██║██║╚████║
██║░░░░░╚█████╔╝░░░██║░░░██║╚█████╔╝██║░╚███║
╚═╝░░░░░░╚════╝░░░░╚═╝░░░╚═╝░╚════╝░╚═╝░░╚══╝

██████╗░██████╗░░█████╗░████████╗░█████╗░░█████╗░░█████╗░██╗░░░░░
██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔══██╗██╔══██╗██╔══██╗██║░░░░░
██████╔╝██████╔╝██║░░██║░░░██║░░░██║░░██║██║░░╚═╝██║░░██║██║░░░░░
██╔═══╝░██╔══██╗██║░░██║░░░██║░░░██║░░██║██║░░██╗██║░░██║██║░░░░░
██║░░░░░██║░░██║╚█████╔╝░░░██║░░░╚█████╔╝╚█████╔╝╚█████╔╝███████╗
╚═╝░░░░░╚═╝░░╚═╝░╚════╝░░░░╚═╝░░░░╚════╝░░╚════╝░░╚════╝░╚══════╝

@author: @10xdegen
*/

import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "lib/openzeppelin-contracts/contracts/security/Pausable.sol";
import {IERC2981} from "lib/openzeppelin-contracts/contracts/interfaces/IERC2981.sol";

import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

import {OwnableWithTransferCallback} from "./lib/OwnableWithTransferCallback.sol";
import {ReentrancyGuard} from "./lib/ReentrancyGuard.sol";
import {SimpleAccessControl} from "./lib/SimpleAccessControl.sol";

import {ICurve} from "./bonding-curves/ICurve.sol";
import {CurveErrorCodes} from "./bonding-curves/CurveErrorCodes.sol";

import {PotionRouter} from "./PotionRouter.sol";
import {IPotionPairFactoryLike} from "./IPotionPairFactoryLike.sol";

import {FixedPointMathLib} from "lib/solmate/src/utils/FixedPointMathLib.sol";

/// @title The base contract for an NFT/TOKEN AMM pair
/// @author Original work by boredGenius and 0xmons, modified by 10xdegen.
/// @notice This implements the core swap logic from NFT to TOKEN
abstract contract PotionPair is
    OwnableWithTransferCallback,
    ReentrancyGuard,
    SimpleAccessControl,
    Pausable
{
    using FixedPointMathLib for uint256;

    /**
     Storage
   */

    // role required to withdaw from pairs
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    // 90%, must <= 1 - MAX_PROTOCOL_FEE (set in PotionPairFactory)
    uint256 public constant MAX_FEE = 0.90e18;

    // Minium number of fungible tokens to allow trading.
    uint256 public constant MIN_TOKEN_LIQUIDITY = 1e3;

    // Minium number of NFTs to allow trading.
    uint256 public constant MIN_NFT_LIQUIDITY = 1;

    // The fee that is charged when swapping any NFTs for tokens.
    // Units are in base 1e18
    uint96 public fee;

    // The fee that is charged when buying specific NFTs from the pair.
    uint96 public specificNftFee;

    // The reserve ratio of the fungible token to NFTs in the pool.
    // Max value 1000000 (=100%)
    uint32 public reserveRatio;

    // trading fees accrued by the contract.
    // subtracted from token balance of contract when calculating
    // the balance of reserve tokens in the pair.
    uint256 public accruedFees;

    // The minimum spot price. Used if the bonding curve falls below this price.
    uint256 public minSpotPrice;

    // The maximum spot price. Used if the bonding curve moves above this price.
    uint256 public maxSpotPrice;

    // Whether or not to charge royalty on sales. Requires the NFT to implement the EIP-2981 royalty standard.
    bool public supportRoyalties;

    // An optional metadata URI for the pair.
    string public metadataURI;

    /**
     Modifiers
   */

    modifier onlyWithdrawer() {
        require(hasRole(WITHDRAWER_ROLE, msg.sender));
        _;
    }

    /**
     Events
   */

    event BuyNFTs(address indexed caller, uint256 numNfts, uint256 totalCost);

    event SellNFTs(
        address indexed caller,
        uint256[] nftIds,
        uint256 totalRevenue
    );
    event NFTDeposit(address sender, uint256[] ids);
    event TokenDeposit(address sender, uint256 amount);
    event TokenWithdrawal(address receiver, uint256 amount, uint256 asFees);
    event NFTWithdrawal(address receiver, uint256[] ids);
    event FeeUpdate(uint96 newFee, uint96 newSpecificNftFee);

    /**
     Parameterized Errors
   */
    error BondingCurveError(CurveErrorCodes.Error error);

    /**
     initializer
   */

    /**
      @notice Called during pair creation to set initial parameters
      @dev Only called once by factory to initialize.
      We verify this by making sure that the current owner is address(0). 
      The Ownable library we use disallows setting the owner to be address(0), so this condition
      should only be valid before the first initialize call. 
      @param _owner The owner of the pair
      @param _fee The initial % fee taken by the pair
      @param _specificNftFee The fee charged for purchasing specific NFTs from the pair.
      @param _reserveRatio The weight of the fungible token in the pool
      @param _supportRoyalties Whether or not the pool should enforce the EIP-2981 NFT royalty standard on swaps.
     */
    function initialize(
        address _owner,
        address _withdrawer,
        uint96 _fee,
        uint96 _specificNftFee,
        uint32 _reserveRatio,
        bool _supportRoyalties,
        string calldata _metadataURI
    ) external payable {
        require(owner() == address(0), "Initialized");
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        _setRoleAdmin(WITHDRAWER_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(WITHDRAWER_ROLE, _withdrawer);

        require(_fee < MAX_FEE, "Trade fee must be less than 90%");
        fee = _fee;
        specificNftFee = _specificNftFee;
        reserveRatio = _reserveRatio;
        metadataURI = _metadataURI;

        // check if NFT implements EIP-2981 royalty standard
        supportRoyalties =
            _supportRoyalties &&
            nft().supportsInterface(type(IERC2981).interfaceId);
    }

    /**
     * View functions
     */

    /**
        @dev Used as read function to query the bonding curve for buy pricing info
        @param numNFTs The number of NFTs to buy from the pair
        @param specific Whether to buy specific NFTs from the pair (incurs additional fee)
     */
    function getBuyNFTQuote(uint256 numNFTs, bool specific)
        external
        view
        returns (
            uint256 inputAmount,
            uint256 tradeFee,
            uint256 protocolFee
        )
    {
        return _getBuyNFTQuote(numNFTs, MIN_NFT_LIQUIDITY, specific);
    }

    /**
        @dev Used as read function to query the bonding curve for sell pricing info
        @param numNFTs The number of NFTs to sell to the pair
     */
    function getSellNFTQuote(uint256 numNFTs)
        public
        view
        returns (
            uint256 outputAmount,
            uint256 tradeFee,
            uint256 protocolFee
        )
    {
        (outputAmount, tradeFee, protocolFee, , ) = _getSellNFTQuote(
            numNFTs,
            MIN_TOKEN_LIQUIDITY
        );
    }

    /**
        @notice Returns all NFT IDs held by the pool
        @param maxQuantity The maximum number of NFT IDs to return. Ignored if 0.
        @return nftIds list of NFT IDs held by the pool
     */
    function getAllHeldIds(uint256 maxQuantity)
        external
        view
        virtual
        returns (uint256[] memory nftIds);

    /**
        @notice Returns the pair's variant (NFT is enumerable or not, pair uses ETH or ERC20)
     */
    function pairVariant()
        public
        pure
        virtual
        returns (IPotionPairFactoryLike.PairVariant);

    function factory() public pure returns (IPotionPairFactoryLike _factory) {
        uint256 paramsLength = _immutableParamsLength();
        assembly {
            _factory := shr(
                0x60,
                calldataload(sub(calldatasize(), paramsLength))
            )
        }
    }

    /**
        @notice Returns the type of bonding curve that parameterizes the pair
     */
    function bondingCurve() public pure returns (ICurve _bondingCurve) {
        uint256 paramsLength = _immutableParamsLength();
        assembly {
            _bondingCurve := shr(
                0x60,
                calldataload(add(sub(calldatasize(), paramsLength), 20))
            )
        }
    }

    /**
        @notice Returns the NFT collection that parameterizes the pair
     */
    function nft() public pure returns (IERC721 _nft) {
        uint256 paramsLength = _immutableParamsLength();
        assembly {
            _nft := shr(
                0x60,
                calldataload(add(sub(calldatasize(), paramsLength), 40))
            )
        }
    }

    /**
        @notice Returns the pair's total fungible token balance (either ETH or ERC20)
     */
    function fungibleTokenBalance() public view virtual returns (uint256);

    /**
        @notice Returns the balances of each token in the pair.
     */
    function getBalances()
        public
        view
        returns (uint256 nftBalance, uint256 tokenBalance)
    {
        nftBalance = nft().balanceOf(address(this));
        tokenBalance = fungibleTokenBalance();
    }

    /**
     * External state-changing functions
     */

    /**
        @notice Sends token to the pair in exchange for any `numNFTs` NFTs
        @dev To compute the amount of token to send, call bondingCurve.getBuyInfo.
        This swap function is meant for users who are ID agnostic
        @param numNFTs The number of NFTs to purchase
        @param maxExpectedTokenInput The maximum acceptable cost from the sender. If the actual
        amount is greater than this value, the transaction will be reverted.
        @param nftRecipient The recipient of the NFTs
        @param isRouter True if calling from PotionRouter, false otherwise. Not used for
        ETH pairs.
        @param routerCaller If isRouter is true, ERC20 tokens will be transferred from this address. Not used for
        ETH pairs.
        @return inputAmount The amount of token used for purchase
     */
    function swapTokenForAnyNFTs(
        uint256 numNFTs,
        uint256 maxExpectedTokenInput,
        address nftRecipient,
        bool isRouter,
        address routerCaller
    )
        external
        payable
        virtual
        nonReentrant
        whenNotPaused
        returns (uint256 inputAmount)
    {
        // Store locally to remove extra calls
        IPotionPairFactoryLike _factory = factory();
        IERC721 _nft = nft();

        // Input validation
        {
            require(
                (numNFTs > 0) && (numNFTs <= _nft.balanceOf(address(this))),
                "Ask for > 0 and <= balanceOf NFTs"
            );
        }

        // Call bonding curve for pricing information
        uint256 tradeFee;
        uint256 protocolFee;

        // get the quote
        (inputAmount, tradeFee, protocolFee) = _getBuyNFTQuote(
            numNFTs,
            MIN_NFT_LIQUIDITY + 1,
            false
        );

        // Revert if input is more than expected
        require(inputAmount <= maxExpectedTokenInput, "In too many tokens");

        _pullTokenInputAndPayProtocolFee(
            inputAmount,
            isRouter,
            routerCaller,
            _factory,
            protocolFee
        );

        _sendAnyNFTsToRecipient(_nft, nftRecipient, numNFTs);

        _refundTokenToSender(inputAmount);

        // increment collected trading fees
        accruedFees += tradeFee;

        emit BuyNFTs(msg.sender, numNFTs, inputAmount);
    }

    /**
        @notice Sends token to the pair in exchange for a specific set of NFTs
        @dev To compute the amount of token to send, call bondingCurve.getBuyInfo
        This swap is meant for users who want specific IDs. Also higher chance of
        reverting if some of the specified IDs leave the pool before the swap goes through.
        @param nftIds The list of IDs of the NFTs to purchase
        @param maxExpectedTokenInput The maximum acceptable cost from the sender. If the actual
        amount is greater than this value, the transaction will be reverted.
        @param nftRecipient The recipient of the NFTs
        @param isRouter True if calling from PotionRouter, false otherwise. Not used for
        ETH pairs.
        @param routerCaller If isRouter is true, ERC20 tokens will be transferred from this address. Not used for
        ETH pairs.
        @return inputAmount The amount of token used for purchase
     */
    // TODO(10xdegen): Add a fee / option for this.
    function swapTokenForSpecificNFTs(
        uint256[] calldata nftIds,
        uint256 maxExpectedTokenInput,
        address nftRecipient,
        bool isRouter,
        address routerCaller
    ) external payable virtual nonReentrant whenNotPaused returns (uint256) {
        // Store locally to remove extra calls
        IPotionPairFactoryLike _factory = factory();

        // Input validation
        {
            require((nftIds.length > 0), "Must ask for > 0 NFTs");
        }

        // get the quote
        (
            uint256 inputAmount,
            uint256 tradeFee,
            uint256 protocolFee
        ) = _getBuyNFTQuote(nftIds.length, MIN_NFT_LIQUIDITY + 1, true);
        // Revert if input is more than expected
        require(inputAmount <= maxExpectedTokenInput, "In too many tokens");

        // increment collected trading fees
        accruedFees += tradeFee;

        _pullTokenInputAndPayProtocolFee(
            inputAmount,
            isRouter,
            routerCaller,
            _factory,
            protocolFee
        );

        _sendSpecificNFTsToRecipient(nft(), nftRecipient, nftIds);

        _refundTokenToSender(inputAmount);

        emit BuyNFTs(msg.sender, nftIds.length, inputAmount);

        return inputAmount;
    }

    /**
        @notice Sends a set of NFTs to the pair in exchange for token
        @dev To compute the amount of token to that will be received, call bondingCurve.getSellInfo.
        @param nftIds The list of IDs of the NFTs to sell to the pair
        @param minExpectedTokenOutput The minimum acceptable token received by the sender. If the actual
        amount is less than this value, the transaction will be reverted.
        @param tokenRecipient The recipient of the token output
        @param isRouter True if calling from PotionRouter, false otherwise. Not used for
        ETH pairs.
        @param routerCaller If isRouter is true, ERC20 tokens will be transferred from this address. Not used for
        ETH pairs.
        @return outputAmount The amount of token received
     */
    function swapNFTsForToken(
        uint256[] calldata nftIds,
        uint256 minExpectedTokenOutput,
        address payable tokenRecipient,
        bool isRouter,
        address routerCaller
    )
        external
        virtual
        nonReentrant
        whenNotPaused
        returns (uint256 outputAmount)
    {
        // Store locally to remove extra calls
        IPotionPairFactoryLike _factory = factory();

        // Input validation
        {
            require(nftIds.length > 0, "Must ask for > 0 NFTs");
        }

        uint256 tradeFee;
        uint256 protocolFee;
        uint256 royalty;
        address royaltyRecipient;
        // always ensure this is 1 more than the token liquidity in the pool, for the curve
        (
            outputAmount,
            tradeFee,
            protocolFee,
            royalty,
            royaltyRecipient
        ) = _getSellNFTQuote(nftIds.length, MIN_TOKEN_LIQUIDITY + 1);

        // Revert if output is too little
        require(
            outputAmount >= minExpectedTokenOutput,
            "Out too little tokens"
        );

        // increment collected trading fees
        accruedFees += tradeFee;

        // send fungible payments
        // 1. output
        _sendTokenOutput(tokenRecipient, outputAmount);
        // 2. protocol.
        _payProtocolFeeFromPair(_factory, protocolFee);
        // 3. royalty
        if (royalty > 0) {
            _sendTokenOutput(payable(royaltyRecipient), royalty);
        }

        _takeNFTsFromSender(
            msg.sender,
            nft(),
            nftIds,
            _factory,
            isRouter,
            routerCaller
        );

        emit SellNFTs(msg.sender, nftIds, outputAmount);
    }

    /**
      Pool Functions
     */

    /**
        @notice Deposits the NFTs to the pair from the specified address. Should only be called by LP contract.
        @param sender The address sending the token to transfer
        @param nftIds The nfts to deposit
     */
    function depositNfts(address sender, uint256[] calldata nftIds)
        public
        whenNotPaused
    {
        IERC721 _nft = nft();
        uint256 balance = _nft.balanceOf(sender);
        // for (uint256 i = 0; i < nftIds.length; i++) {
        //     address owner = _nft.ownerOf(nftIds[i]);
        // }
        require(balance >= nftIds.length, "Not enough NFTs");

        IPotionPairFactoryLike _factory = factory();
        _takeNFTsFromSender(sender, _nft, nftIds, _factory, false, address(0));
    }

    /**
        @notice Withdraws the NFTs from the pair to the specified address. onlyRole(WITHDRAWER) is in the implemented function.
        @param receiver The address to receive the token to transfer
        @param nftIds The nfts to witdraw
     */
    function withdrawNfts(address receiver, uint256[] calldata nftIds)
        external
        virtual;

    /**
        @notice Safely Deposits the Fungible tokens to the pair from the caller.
        @param from The address to pull the token from.
        @param amount The amount of tokens to deposit.
     */
    function depositFungibleTokens(address from, uint256 amount)
        external
        payable
        virtual;

    /**
        @notice Withdraws the Fungible tokens from the pair to the specified address. 
        @dev can only be called by WITHDRAWER.
        @param receiver The address to receive the token to transfer
        @param amount The amount of tokens to witdraw
        @param fromFees Whether the caller is withdrawing fees or not.
     */
    function withdrawFungibleTokens(
        address receiver,
        uint256 amount,
        uint256 fromFees
    ) external onlyWithdrawer {
        require(amount + fromFees > 0, "Amount must be greater than 0");
        if (fromFees > 0) {
            require(
                fromFees <= accruedFees,
                "FromFees Amount must be less than or equal to fees"
            );
            accruedFees -= fromFees;
        }
        require(
            amount <= fungibleTokenBalance(),
            "Amount must be less than or equal to balance + accrued fees"
        );
        _withdrawFungibleTokens(receiver, amount + fromFees);
        emit TokenWithdrawal(receiver, amount, fromFees);
    }

    /**
      Admin Functions
     */

    /**
        @notice Grants or Revokes the WITHDRAWER role to the specified address.
        @param account The new LP fee percentage, 18 decimals
        @param enabled The new LP fee percentage, 18 decimals
     */
    function setWithdrawerRole(address account, bool enabled)
        external
        onlyOwner
    {
        if (enabled) {
            grantRole(WITHDRAWER_ROLE, account);
        } else {
            revokeRole(WITHDRAWER_ROLE, account);
        }
    }

    /**
        @notice Updates the fees taken by the LP. Only callable by the owner.
        Only callable if the pool is a Trade pool. Reverts if the fee is >=
        MAX_FEE.
        @param newFee The new LP fee percentage, 18 decimals
        @param newSpecificNftFee The new LP fee percentage, 18 decimals
     */
    function changeFee(uint96 newFee, uint96 newSpecificNftFee)
        external
        onlyOwner
    {
        require(newFee < MAX_FEE, "Trade fee must be less than 90%");
        if (fee != newFee || specificNftFee != newSpecificNftFee) {
            fee = newFee;
            specificNftFee = newSpecificNftFee;
            emit FeeUpdate(newFee, newSpecificNftFee);
        }
    }

    /**
        @notice Updates the optional Metadata URI associated with the pair.
        @param _metadataURI The new metadata URI
     */
    function setMetadataURI(string memory _metadataURI) external onlyOwner {
        metadataURI = _metadataURI;
    }

    /**
     * Internal functions
     */

    /**
        @notice Pulls the token input of a trade from the trader and pays the protocol fee.
        @param inputAmount The amount of tokens to be sent
        @param isRouter Whether or not the caller is PotionRouter
        @param routerCaller If called from PotionRouter, store the original caller
        @param _factory The PotionPairFactory which stores PotionRouter allowlist info
        @param protocolFee The protocol fee to be paid
     */
    function _pullTokenInputAndPayProtocolFee(
        uint256 inputAmount,
        bool isRouter,
        address routerCaller,
        IPotionPairFactoryLike _factory,
        uint256 protocolFee
    ) internal virtual;

    /**
        @notice Sends excess tokens back to the caller (if applicable)
        @dev We send ETH back to the caller even when called from PotionRouter because we do an aggregate slippage check for certain bulk swaps. (Instead of sending directly back to the router caller) 
        Excess ETH sent for one swap can then be used to help pay for the next swap.
     */
    function _refundTokenToSender(uint256 inputAmount) internal virtual;

    /**
        @notice Sends protocol fee (if it exists) back to the PotionPairFactory from the pair
     */
    function _payProtocolFeeFromPair(
        IPotionPairFactoryLike _factory,
        uint256 protocolFee
    ) internal virtual;

    /**
        @notice Sends tokens to a recipient
        @param tokenRecipient The address receiving the tokens
        @param outputAmount The amount of tokens to send
     */
    function _sendTokenOutput(
        address payable tokenRecipient,
        uint256 outputAmount
    ) internal virtual;

    /**
        @notice Sends some number of NFTs to a recipient address, ID agnostic
        @dev Even though we specify the NFT address here, this internal function is only 
        used to send NFTs associated with this specific pool.
        @param _nft The address of the NFT to send
        @param nftRecipient The receiving address for the NFTs
        @param numNFTs The number of NFTs to send  
     */
    function _sendAnyNFTsToRecipient(
        IERC721 _nft,
        address nftRecipient,
        uint256 numNFTs
    ) internal virtual;

    /**
        @notice Sends specific NFTs to a recipient address
        @dev Even though we specify the NFT address here, this internal function is only 
        used to send NFTs associated with this specific pool.
        @param _nft The address of the NFT to send
        @param nftRecipient The receiving address for the NFTs
        @param nftIds The specific IDs of NFTs to send  
     */
    function _sendSpecificNFTsToRecipient(
        IERC721 _nft,
        address nftRecipient,
        uint256[] calldata nftIds
    ) internal virtual;

    /**
        @notice Takes NFTs from the caller and sends them into the pair's asset recipient
        @dev This is used by the PotionPair's swapNFTForToken function. 
        @param _nft The NFT collection to take from
        @param nftIds The specific NFT IDs to take
        @param isRouter True if calling from PotionRouter, false otherwise. Not used for
        ETH pairs.
        @param routerCaller If isRouter is true, ERC20 tokens will be transferred from this address. Not used for
        ETH pairs.
     */
    function _takeNFTsFromSender(
        address sender,
        IERC721 _nft,
        uint256[] calldata nftIds,
        IPotionPairFactoryLike _factory,
        bool isRouter,
        address routerCaller
    ) internal virtual {
        {
            address _assetRecipient = address(this);
            uint256 numNFTs = nftIds.length;

            if (isRouter) {
                // Verify if router is allowed
                PotionRouter router = PotionRouter(payable(sender));
                (bool routerAllowed, ) = _factory.routerStatus(router);
                require(routerAllowed, "Not router");

                // Call router to pull NFTs
                // If more than 1 NFT is being transfered, we can do a balance check instead of an ownership check, as pools are indifferent between NFTs from the same collection
                if (numNFTs > 1) {
                    uint256 beforeBalance = _nft.balanceOf(_assetRecipient);
                    for (uint256 i = 0; i < numNFTs; ) {
                        router.pairTransferNFTFrom(
                            _nft,
                            routerCaller,
                            _assetRecipient,
                            nftIds[i],
                            pairVariant()
                        );

                        unchecked {
                            ++i;
                        }
                    }
                    require(
                        (_nft.balanceOf(_assetRecipient) - beforeBalance) ==
                            numNFTs,
                        "NFTs not transferred"
                    );
                } else {
                    router.pairTransferNFTFrom(
                        _nft,
                        routerCaller,
                        _assetRecipient,
                        nftIds[0],
                        pairVariant()
                    );
                    require(
                        _nft.ownerOf(nftIds[0]) == _assetRecipient,
                        "NFT not transferred"
                    );
                }
            } else {
                // Pull NFTs directly from sender
                for (uint256 i; i < numNFTs; ) {
                    _nft.safeTransferFrom(sender, _assetRecipient, nftIds[i]);

                    unchecked {
                        ++i;
                    }
                }
            }
        }
    }

    /**
     * internal read functions
     */

    /**
        @dev Used internally to handle calling curve. Important edge case to handle
        when we are calling the method while receiving an eth payment.
     */
    function _getBuyNFTQuote(
        uint256 numNFTs,
        uint256 minNftLiquidity,
        bool specific
    )
        internal
        view
        returns (
            uint256 inputAmount,
            uint256 tradeFee,
            uint256 protocolFee
        )
    {
        require(numNFTs > 0, "Must buy at least 1 NFT");
        // get balances
        (uint256 nftBalance, uint256 tokenBalance) = getBalances();
        require(
            numNFTs + minNftLiquidity <= nftBalance,
            "INSUFFICIENT_NFT_LIQUIDITY"
        );

        // need to subtract the msg.value from balance to get the actual balance before payment
        tokenBalance -= msg.value;

        // if token balance > 0 , first check the price with hte bonding curve
        // if bonding curve == 0, we use min price (fallback)
        if (tokenBalance > 0) {
            // if no nft balance this will revert
            CurveErrorCodes.Error error;
            (error, inputAmount) = bondingCurve().getBuyInfo(
                numNFTs,
                nftBalance, // calculate position on the bonding curve based on circulating supply
                tokenBalance,
                reserveRatio
            );
            // Revert if bonding curve had an error
            if (error != CurveErrorCodes.Error.OK) {
                revert BondingCurveError(error);
            }
        }

        // Account for the specific nft fee, if a specific nft is being bought
        if (specific) {
            inputAmount += inputAmount.fmul(
                specificNftFee,
                FixedPointMathLib.WAD
            );
        }

        // Account for the trade fee
        tradeFee = inputAmount.fmul(fee, FixedPointMathLib.WAD);

        // Add the protocol fee to the required input amount
        protocolFee = inputAmount.fmul(
            factory().protocolFeeMultiplier(),
            FixedPointMathLib.WAD
        );

        inputAmount += tradeFee;
        inputAmount += protocolFee;

        return (inputAmount, tradeFee, protocolFee);
    }

    /**
        @dev Used as read function to query the bonding curve for sell pricing info
        @param numNFTs The number of NFTs to sell to the pair
     */
    function _getSellNFTQuote(uint256 numNFTs, uint256 minTokenLiquidity)
        public
        view
        returns (
            uint256 outputAmount,
            uint256 tradeFee,
            uint256 protocolFee,
            uint256 royalty,
            address royaltyRecipient
        )
    {
        require(numNFTs > 0, "Must sell at least 1 NFT");

        // get balances
        (uint256 nftBalance, uint256 tokenBalance) = getBalances();

        CurveErrorCodes.Error error;
        (error, outputAmount) = bondingCurve().getSellInfo(
            numNFTs,
            nftBalance,
            tokenBalance,
            reserveRatio
        );
        // Revert if bonding curve had an error
        if (error != CurveErrorCodes.Error.OK) {
            revert BondingCurveError(error);
        }

        // Account for the trade fee, only for Trade pools
        tradeFee = outputAmount.fmul(fee, FixedPointMathLib.WAD);

        // Add the protocol fee to the required input amount
        protocolFee = outputAmount.fmul(
            factory().protocolFeeMultiplier(),
            FixedPointMathLib.WAD
        );

        outputAmount -= tradeFee;
        outputAmount -= protocolFee;

        if (supportRoyalties) {
            (royaltyRecipient, royalty) = IERC2981(address(nft())).royaltyInfo(
                0,
                outputAmount
            );
            outputAmount -= royalty;
        }

        require(
            outputAmount + minTokenLiquidity < tokenBalance,
            "INSUFFICIENT__TOKEN_LIQUIDITY"
        );
    }

    /**
        @dev Used internally to grab pair parameters from calldata, see PotionPairCloner for technical details
     */
    function _immutableParamsLength() internal pure virtual returns (uint256);

    /**
        @notice Withdraws the Fungible tokens from the pair to the specified address. onlyRole(WITHDRAWER) is in the implemented function.
        @param receiver The address to receive the token to transfer
        @param amount The amount of tokens to witdraw
     */
    function _withdrawFungibleTokens(address receiver, uint256 amount)
        internal
        virtual;

    /**
     * Owner functions
     */

    /**
        @notice Rescues a specified set of NFTs owned by the pair to the specified address. Only callable by the owner.
        @dev If the NFT is the pair's collection, we also remove it from the id tracking (if the NFT is missing enumerable).
        @param receiver The receiver address to rescue the NFTs to
        @param a The NFT to transfer
        @param nftIds The list of IDs of the NFTs to send to the owner
     */
    function rescueERC721(
        address receiver,
        IERC721 a,
        uint256[] calldata nftIds
    ) external virtual;

    /**
        @notice Rescues ERC20 tokens from the pair to the owner. Only callable by the owner.
        @param receiver The receiver to transfer the tokens to
        @param a The token to transfer
        @param amount The amount of tokens to send to the owner
     */
    function rescueERC20(
        address receiver,
        ERC20 a,
        uint256 amount
    ) external virtual;

    /**
        @notice Allows the pair to make arbitrary external calls to contracts
        whitelisted by the protocol. Only callable by the owner.
        @param target The contract to call
        @param data The calldata to pass to the contract
     */
    function call(address payable target, bytes calldata data)
        external
        onlyOwner
    {
        IPotionPairFactoryLike _factory = factory();
        require(_factory.callAllowed(target), "Target must be whitelisted");
        (bool result, ) = target.call{value: 0}(data);
        require(result, "Call failed");
    }

    /**
        @notice Allows owner to batch multiple calls, forked from: https://github.com/boringcrypto/BoringSolidity/blob/master/contracts/BoringBatchable.sol 
        @dev Intended for withdrawing/altering pool pricing in one tx, only callable by owner, cannot change owner
        @param calls The calldata for each call to make
        @param revertOnFail Whether or not to revert the entire tx if any of the calls fail
     */
    function multicall(bytes[] calldata calls, bool revertOnFail)
        external
        onlyOwner
    {
        for (uint256 i; i < calls.length; ) {
            (bool success, bytes memory result) = address(this).delegatecall(
                calls[i]
            );
            if (!success && revertOnFail) {
                revert(_getRevertMsg(result));
            }

            unchecked {
                ++i;
            }
        }

        // Prevent multicall from malicious frontend sneaking in ownership change
        require(
            owner() == msg.sender,
            "Ownership cannot be changed in multicall"
        );
    }

    /**
      @param _returnData The data returned from a multicall result
      @dev Used to grab the revert string from the underlying call
     */
    function _getRevertMsg(bytes memory _returnData)
        internal
        pure
        returns (string memory)
    {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "Transaction reverted silently";

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }
}
