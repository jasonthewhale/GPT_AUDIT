// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {ERC165Checker} from "lib/openzeppelin-contracts/contracts/utils/introspection/ERC165Checker.sol";
import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {IERC721Enumerable} from "lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

// @dev Solmate's ERC20 is used instead of OZ's ERC20 so we can use safeTransferLib for cheaper safeTransfers for
// ETH and ERC20 tokens
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";

import {PotionPool} from "./PotionPool.sol";
import {PotionPair} from "./PotionPair.sol";
import {PotionRouter} from "./PotionRouter.sol";
import {PotionPairETH} from "./PotionPairETH.sol";
import {IPotionPairRegistry, RegisteredPairParams} from "./IPotionPairRegistry.sol";
import {ICurve} from "./bonding-curves/ICurve.sol";
import {PotionPairERC20} from "./PotionPairERC20.sol";
import {PotionPairCloner} from "./lib/PotionPairCloner.sol";
import {IPotionPairFactoryLike} from "./IPotionPairFactoryLike.sol";
import {PotionPairEnumerableETH} from "./PotionPairEnumerableETH.sol";
import {PotionPairEnumerableERC20} from "./PotionPairEnumerableERC20.sol";
import {PotionPairMissingEnumerableETH} from "./PotionPairMissingEnumerableETH.sol";
import {PotionPairMissingEnumerableERC20} from "./PotionPairMissingEnumerableERC20.sol";

contract PotionPairFactory is Ownable, IPotionPairFactoryLike {
    using PotionPairCloner for address;
    using SafeTransferLib for address payable;
    using SafeTransferLib for ERC20;

    bytes4 private constant INTERFACE_ID_ERC721_ENUMERABLE =
        type(IERC721Enumerable).interfaceId;

    uint256 internal constant MAX_PROTOCOL_FEE = 0.10e18; // 10%, must <= 1 - MAX_FEE

    PotionPairEnumerableETH public immutable enumerableETHTemplate;
    PotionPairMissingEnumerableETH
        public immutable missingEnumerableETHTemplate;
    PotionPairEnumerableERC20 public immutable enumerableERC20Template;
    PotionPairMissingEnumerableERC20
        public immutable missingEnumerableERC20Template;
    address payable public override protocolFeeRecipient;

    // Units are in base 1e18
    uint256 public override protocolFeeMultiplier;

    mapping(ICurve => bool) public bondingCurveAllowed;
    mapping(address => bool) public override callAllowed;
    struct RouterStatus {
        bool allowed;
        bool wasEverAllowed;
    }
    mapping(PotionRouter => RouterStatus) public override routerStatus;

    IPotionPairRegistry public pairRegistry;

    event NewPair(address pairAddress, address poolAddress);
    event TokenDeposit(address pairAddress);
    event NFTDeposit(address pairAddress);
    event ProtocolFeeRecipientUpdate(address recipientAddress);
    event ProtocolFeeMultiplierUpdate(uint256 newMultiplier);
    event BondingCurveStatusUpdate(ICurve bondingCurve, bool isAllowed);
    event CallTargetStatusUpdate(address target, bool isAllowed);
    event RouterStatusUpdate(PotionRouter router, bool isAllowed);
    event RegistryStatusUpdate(IPotionPairRegistry router);

    constructor(
        PotionPairEnumerableETH _enumerableETHTemplate,
        PotionPairMissingEnumerableETH _missingEnumerableETHTemplate,
        PotionPairEnumerableERC20 _enumerableERC20Template,
        PotionPairMissingEnumerableERC20 _missingEnumerableERC20Template,
        address payable _protocolFeeRecipient,
        uint256 _protocolFeeMultiplier
    ) {
        enumerableETHTemplate = _enumerableETHTemplate;
        missingEnumerableETHTemplate = _missingEnumerableETHTemplate;
        enumerableERC20Template = _enumerableERC20Template;
        missingEnumerableERC20Template = _missingEnumerableERC20Template;
        protocolFeeRecipient = _protocolFeeRecipient;

        require(_protocolFeeMultiplier <= MAX_PROTOCOL_FEE, "Fee too large");
        protocolFeeMultiplier = _protocolFeeMultiplier;
    }

    /**
     * External functions
     */

    /**
        @notice Creates a pair contract using EIP-1167.
        @param _nft The NFT contract of the collection the pair trades
        @param _bondingCurve The bonding curve for the pair to price NFTs, must be whitelisted
        @param _assetRecipient The address that will receive the assets traders give during trades.
                              If set to address(0), assets will be sent to the pool address.
                              Not available to TRADE pools. 
        @param _fee The fee taken by the LP in each trade.
        @param _initialNFTIDs The list of IDs of NFTs to transfer from the sender to the pair
        @return pair The new pair
     */
    struct CreateETHPairParams {
        string poolName;
        string poolSymbol;
        IERC721 nft;
        ICurve bondingCurve;
        uint96 fee;
        uint96 specificNftFee;
        uint32 reserveRatio;
        bool supportRoyalties;
        uint256[] initialNFTIDs;
        string metadataURI;
    }

    function createPairETH(CreateETHPairParams calldata params)
        external
        payable
        returns (PotionPairETH pair, PotionPool pool)
    {
        require(
            bondingCurveAllowed[params.bondingCurve],
            "Bonding curve not whitelisted"
        );

        // Check to see if the NFT supports Enumerable to determine which template to use
        address template;
        try
            IERC165(address(params.nft)).supportsInterface(
                INTERFACE_ID_ERC721_ENUMERABLE
            )
        returns (bool isEnumerable) {
            template = isEnumerable
                ? address(enumerableETHTemplate)
                : address(missingEnumerableETHTemplate);
        } catch {
            template = address(missingEnumerableETHTemplate);
        }

        pair = PotionPairETH(
            payable(
                template.cloneETHPair(this, params.bondingCurve, params.nft)
            )
        );

        pool = new PotionPool(pair, params.poolName, params.poolSymbol);

        _registerPairOrFail(msg.sender, params.nft, pair, pool);

        _initializePairETH(
            pair,
            pool,
            params.nft,
            params.fee,
            params.specificNftFee,
            params.reserveRatio,
            params.supportRoyalties,
            params.initialNFTIDs,
            params.metadataURI
        );

        emit NewPair(address(pair), address(pool));
    }

    /**
        @notice Creates a pair contract using EIP-1167.
        @param _nft The NFT contract of the collection the pair trades
        @param _bondingCurve The bonding curve for the pair to price NFTs, must be whitelisted
        @param _assetRecipient The address that will receive the assets traders give during trades.
                                If set to address(0), assets will be sent to the pool address.
                                Not available to TRADE pools.
        @param _fee The fee taken by the LP in each trade.
        @param _initialNFTIDs The list of IDs of NFTs to transfer from the sender to the pair
        @param _initialTokenBalance The initial token balance sent from the sender to the new pair
        @return pair The new pair
     */
    struct CreateERC20PairParams {
        string poolName;
        string poolSymbol;
        ERC20 token;
        IERC721 nft;
        ICurve bondingCurve;
        uint96 fee;
        uint96 specificNftFee;
        uint32 reserveRatio;
        bool supportRoyalties;
        uint256[] initialNFTIDs;
        uint256 initialTokenBalance;
        string metadataURI;
    }

    function createPairERC20(CreateERC20PairParams calldata params)
        external
        returns (PotionPairERC20 pair, PotionPool pool)
    {
        require(
            bondingCurveAllowed[params.bondingCurve],
            "Bonding curve not whitelisted"
        );

        // Check to see if the NFT supports Enumerable to determine which template to use
        address template;
        try
            IERC165(address(params.nft)).supportsInterface(
                INTERFACE_ID_ERC721_ENUMERABLE
            )
        returns (bool isEnumerable) {
            template = isEnumerable
                ? address(enumerableERC20Template)
                : address(missingEnumerableERC20Template);
        } catch {
            template = address(missingEnumerableERC20Template);
        }

        pair = PotionPairERC20(
            payable(
                template.cloneERC20Pair(
                    this,
                    params.bondingCurve,
                    params.nft,
                    params.token
                )
            )
        );

        pool = new PotionPool(pair, params.poolName, params.poolSymbol);

        _registerPairOrFail(msg.sender, params.nft, pair, pool);

        _initializePairERC20(InitializePairERC20Params(
            pair,
            pool,
            params.token,
            params.nft,
            params.fee,
            params.specificNftFee,
            params.reserveRatio,
            params.supportRoyalties,
            params.initialNFTIDs,
            params.initialTokenBalance,
            params.metadataURI
        ));

        emit NewPair(address(pair), address(pool));
    }

    /**
        @notice Checks if an address is a PotionPair. Uses the fact that the pairs are EIP-1167 minimal proxies.
        @param potentialPair The address to check
        @param variant The pair variant (NFT is enumerable or not, pair uses ETH or ERC20)
        @return True if the address is the specified pair variant, false otherwise
     */
    function isPair(address potentialPair, PairVariant variant)
        public
        view
        override
        returns (bool)
    {
        if (variant == PairVariant.ENUMERABLE_ERC20) {
            return
                PotionPairCloner.isERC20PairClone(
                    address(this),
                    address(enumerableERC20Template),
                    potentialPair
                );
        } else if (variant == PairVariant.MISSING_ENUMERABLE_ERC20) {
            return
                PotionPairCloner.isERC20PairClone(
                    address(this),
                    address(missingEnumerableERC20Template),
                    potentialPair
                );
        } else if (variant == PairVariant.ENUMERABLE_ETH) {
            return
                PotionPairCloner.isETHPairClone(
                    address(this),
                    address(enumerableETHTemplate),
                    potentialPair
                );
        } else if (variant == PairVariant.MISSING_ENUMERABLE_ETH) {
            return
                PotionPairCloner.isETHPairClone(
                    address(this),
                    address(missingEnumerableETHTemplate),
                    potentialPair
                );
        } else {
            // invalid input
            return false;
        }
    }

    /**
        @notice Allows receiving ETH in order to receive protocol fees
     */
    receive() external payable {}

    /**
     * Admin functions
     */

    /**
        @notice Withdraws the ETH balance to the protocol fee recipient.
        Only callable by the owner.
     */
    function withdrawETHProtocolFees() external onlyOwner {
        protocolFeeRecipient.safeTransferETH(address(this).balance);
    }

    /**
        @notice Withdraws ERC20 tokens to the protocol fee recipient. Only callable by the owner.
        @param token The token to transfer
        @param amount The amount of tokens to transfer
     */
    function withdrawERC20ProtocolFees(ERC20 token, uint256 amount)
        external
        onlyOwner
    {
        token.safeTransfer(protocolFeeRecipient, amount);
    }

    /**
        @notice Changes the protocol fee recipient address. Only callable by the owner.
        @param _protocolFeeRecipient The new fee recipient
     */
    function changeProtocolFeeRecipient(address payable _protocolFeeRecipient)
        external
        onlyOwner
    {
        require(_protocolFeeRecipient != address(0), "0 address");
        protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdate(_protocolFeeRecipient);
    }

    /**
        @notice Changes the protocol fee multiplier. Only callable by the owner.
        @param _protocolFeeMultiplier The new fee multiplier, 18 decimals
     */
    function changeProtocolFeeMultiplier(uint256 _protocolFeeMultiplier)
        external
        onlyOwner
    {
        require(_protocolFeeMultiplier <= MAX_PROTOCOL_FEE, "Fee too large");
        protocolFeeMultiplier = _protocolFeeMultiplier;
        emit ProtocolFeeMultiplierUpdate(_protocolFeeMultiplier);
    }

    /**
        @notice Sets the whitelist status of a bonding curve contract. Only callable by the owner.
        @param bondingCurve The bonding curve contract
        @param isAllowed True to whitelist, false to remove from whitelist
     */
    function setBondingCurveAllowed(ICurve bondingCurve, bool isAllowed)
        external
        onlyOwner
    {
        bondingCurveAllowed[bondingCurve] = isAllowed;
        emit BondingCurveStatusUpdate(bondingCurve, isAllowed);
    }

    /**
        @notice Sets the whitelist status of a contract to be called arbitrarily by a pair.
        Only callable by the owner.
        @param target The target contract
        @param isAllowed True to whitelist, false to remove from whitelist
     */
    function setCallAllowed(address payable target, bool isAllowed)
        external
        onlyOwner
    {
        // ensure target is not / was not ever a router
        if (isAllowed) {
            require(
                !routerStatus[PotionRouter(target)].wasEverAllowed,
                "Can't call router"
            );
        }

        callAllowed[target] = isAllowed;
        emit CallTargetStatusUpdate(target, isAllowed);
    }

    /**
        @notice Updates the router whitelist. Only callable by the owner.
        @param _router The router
        @param isAllowed True to whitelist, false to remove from whitelist
     */
    function setRouterAllowed(PotionRouter _router, bool isAllowed)
        external
        onlyOwner
    {
        // ensure target is not arbitrarily callable by pairs
        if (isAllowed) {
            require(!callAllowed[address(_router)], "Can't call router");
        }
        routerStatus[_router] = RouterStatus({
            allowed: isAllowed,
            wasEverAllowed: true
        });

        emit RouterStatusUpdate(_router, isAllowed);
    }

    /**
        @notice Updates the registry. Only callable by the owner.
        @param _pairRegistry The registry to use. Set to address(0) to disable.
     */
    function setRegistry(IPotionPairRegistry _pairRegistry) external onlyOwner {
        pairRegistry = _pairRegistry;

        emit RegistryStatusUpdate(_pairRegistry);
    }

    /**
     * Internal functions
     */

    function _initializePairETH(
        PotionPairETH _pair,
        PotionPool _pool,
        IERC721 _nft,
        uint96 _fee,
        uint96 _specificNftFee,
        uint32 _reserveRatio,
        bool _supportRoyalties,
        uint256[] calldata _initialNFTIDs,
        string calldata _metadataURI
    ) internal {
        // initialize pair
        _pair.initialize(
            msg.sender,
            address(_pool),
            _fee,
            _specificNftFee,
            _reserveRatio,
            _supportRoyalties,
            _metadataURI
        );

        // transfer initial ETH to pair
        payable(address(_pair)).safeTransferETH(msg.value);

        // transfer initial NFTs from sender to pair
        uint256 numNFTs = _initialNFTIDs.length;
        for (uint256 i; i < numNFTs; ) {
            _nft.safeTransferFrom(
                msg.sender,
                address(_pair),
                _initialNFTIDs[i]
            );

            unchecked {
                ++i;
            }
        }
    }

    struct InitializePairERC20Params{
        PotionPairERC20 pair;
        PotionPool pool;
        ERC20 token;
        IERC721 nft;
        uint96 fee;
        uint96 specificNftFee;
        uint32 reserveRatio;
        bool supportRoyalties;
        uint256[] initialNFTIDs;
        uint256 initialTokenBalance;
        string metadataURI;
    }

    function _initializePairERC20(InitializePairERC20Params memory params) internal {
        // initialize pair
        params.pair.initialize(
            msg.sender,
            address(params.pool),
            params.fee,
            params.specificNftFee,
            params.reserveRatio,
            params.supportRoyalties,
            params.metadataURI
        );

        // transfer initial tokens to pair
        params.token.safeTransferFrom(
            msg.sender,
            address(params.pair),
            params.initialTokenBalance
        );

        // transfer initial NFTs from sender to pair
        uint256 numNFTs = params.initialNFTIDs.length;
        for (uint256 i; i < numNFTs; ) {
            params.nft.safeTransferFrom(
                msg.sender,
                address(params.pair),
                params.initialNFTIDs[i]
            );

            unchecked {
                ++i;
            }
        }
    }

    function _registerPairOrFail(
        address _creator,
        IERC721 _nft,
        PotionPair _pair,
        PotionPool _pool
    ) internal {
        // if pair registry is set, require pair to be registered.
        if (address(pairRegistry) == address(0)) {
            return;
        }

        bool registered = pairRegistry.registerPair(
            RegisteredPairParams({
                nft: address(_nft),
                pair: address(_pair),
                pool: address(_pool),
                creator: _creator
            })
        );
        // register pair
        require(registered, "Pool registration failed");
    }

    /** 
      @dev Used to deposit NFTs into a pair after creation and emit an event for indexing (if recipient is indeed a pair)
    */
    function depositNFTs(
        IERC721 _nft,
        uint256[] calldata ids,
        address recipient
    ) external {
        // transfer NFTs from caller to recipient
        uint256 numNFTs = ids.length;
        for (uint256 i; i < numNFTs; ) {
            _nft.safeTransferFrom(msg.sender, recipient, ids[i]);

            unchecked {
                ++i;
            }
        }
        if (
            isPair(recipient, PairVariant.ENUMERABLE_ERC20) ||
            isPair(recipient, PairVariant.ENUMERABLE_ETH) ||
            isPair(recipient, PairVariant.MISSING_ENUMERABLE_ERC20) ||
            isPair(recipient, PairVariant.MISSING_ENUMERABLE_ETH)
        ) {
            emit NFTDeposit(recipient);
        }
    }

    /**
      @dev Used to deposit ERC20s into a pair after creation and emit an event for indexing (if recipient is indeed an ERC20 pair and the token matches)
     */
    function depositERC20(
        ERC20 token,
        address recipient,
        uint256 amount
    ) external {
        token.safeTransferFrom(msg.sender, recipient, amount);
        if (
            isPair(recipient, PairVariant.ENUMERABLE_ERC20) ||
            isPair(recipient, PairVariant.MISSING_ENUMERABLE_ERC20)
        ) {
            if (token == PotionPairERC20(recipient).token()) {
                emit TokenDeposit(recipient);
            }
        }
    }
}