pragma solidity ^0.8.18;

// SPDX-License-Identifier: BUSL-1.1

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {StakehouseAPI} from "@blockswaplab/stakehouse-solidity-api/contracts/StakehouseAPI.sol";
import {MainnetConstants, GoerliConstants} from "@blockswaplab/stakehouse-solidity-api/contracts/StakehouseAPI.sol";
import {IDataStructures} from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/IDataStructures.sol";
import {IAccountManager} from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/IAccountManager.sol";
import {IBalanceReporter} from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/IBalanceReporter.sol";
import {ISafeBox} from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/ISafeBox.sol";

import {IZEC} from "../interfaces/IZEC.sol";
import {GiantLP} from "./GiantLP.sol";
import {GiantPoolBase} from "./GiantPoolBase.sol";
import {GiantMevAndFeesPool} from "./GiantMevAndFeesPool.sol";
import {GiantSavETHVaultPool} from "./GiantSavETHVaultPool.sol";
import {LSDNFactory} from "./LSDNFactory.sol";
import {LiquidStakingManager} from "./LiquidStakingManager.sol";
import {LPToken} from "./LPToken.sol";
import {GiantLPDeployer} from "./GiantLPDeployer.sol";
import {Errors} from "./Errors.sol";

/// @notice A giant pool that can provide liquidity to any liquid staking network's staking funds vault
contract ZEC is
    IZEC,
    GiantPoolBase,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    StakehouseAPI
{
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice Representative EOA appointed by the ZEC committee
    /// @dev Recovery can be only called by DAO address for their own network
    address public zecRepresentative;

    /// @notice Blockswap DAO address
    address public blockswapDAO;

    /// @notice EOA representative appointed by the Blockswap DAO or the ZEC Committee
    address public eoaRepresentative;

    /// @notice Address of Fees and MEV Giant pool
    address feesAndMevGiantPool;

    /// @notice Address of SavETH Giant pool
    address savETHGiantPool;

    /// @notice Address of the SafeBox deployed for the Stakehouse Protocol
    address stakehouseSafeBox;

    /// @notice Address of the SafeBox deployed for the ZEC
    address zecSafeBox;

    /// @notice Rewards accumulated for ZEC Node operators
    uint256 public zecNodeOperatorPoolRewards;

    /// @notice Total amount of LP allocated to receive pro-rata MEV and fees rewards
    uint256 public totalLPAssociatedWithDerivativesMinted;

    /// @notice Total number of BLS public keys that can be staked via the ZEC
    /// @dev This can later be updated by the Blockswap DAO
    uint256 public ZEC_BLS_PUBLIC_KEY_LIMIT;

    /// @notice CIP bond amount to be deposited by node operator for every BLS public key proposed.
    uint256 public CIP_BOND;

    /// @notice Maximum number of BLS public keys that a node operator can propose
    uint256 public BLS_PUBLIC_KEY_PROPOSER_LIMIT;

    /// @notice Waiting time for a node operator before they can claim rewards
    uint256 public CLAIM_DELAY;

    /// @notice CIP Bond collected by the ZEC Committee from the node operators
    uint256 public cipBondCollected;

    /// @notice Precision used in rewards calculations for scaling up and down
    uint256 public constant PRECISION = 1e24;

    /// @notice Total accumulated ETH per share of LP<>KNOT that has minted derivatives scaled to 'PRECISION'
    uint256 public accumulatedETHPerLPShare;

    /// @notice Total ETH claimed by all users of the contract
    uint256 public totalClaimed;

    /// @notice Last total rewards seen by the contract
    uint256 public totalETHSeen;

    /// @notice Amount of ETH collected from rage quit which is available to be distributed
    uint256 public availableRagequitETH;

    /// @notice Number of BLS public keys introduced to the ZEC.
    /// @dev This decreases if a BLS public key is withdrawn without being staked
    uint256 public totalBLSPublicKeysProposed;

    /// @notice Total number of BLS public keys staked by ZEC Node operators and have minted derivatives
    uint256 public totalBLSPublicKeysProposedAndMinted;

    /// @notice mapping of ZEC committee members to the Liquid Staking Manager address of their LSD
    mapping(address => address) public isPartOfZECCommittee;

    /// @notice mapping of whitelisted Node oeprators to the Liquid Staking Manager address
    mapping(address => address) public isNodeOperatorWhitelisted;

    /// @notice Snapshotting pro-rata share of tokens for last claim by address
    mapping(address => uint256) public lastAccumulatedLPAtLastLiquiditySize;

    /// @notice mapping from node operator to number of BLS public keys proposed
    mapping(address => uint256) public numberOfBLSPublicKeysProposed;

    /// @notice mapping from node operator to number of BLS public keys proposed and minted
    mapping(address => uint256) public numberOfBLSPublicKeysProposedAndMinted;

    /// @notice mapping of BLS public key to its Node operator
    mapping(bytes => address) public nodeOperatorOfBLSPublicKey;

    /// @notice mapping from BLS public key to its CIP bond. Set to false if the CIP bond is already used
    mapping(bytes => bool) public isCIPBondValid;

    /// @notice How much historical ETH had accrued to the LP tokens at time of minting derivatives of a BLS key
    mapping(bytes => uint256)
        public accumulatedETHPerLPAtTimeOfMintingDerivatives;

    /// @notice Total ETH claimed by a given address for a given token
    mapping(address => mapping(address => uint256)) public claimed;

    /// @notice Amount of ETH claimed as rewards by the node operators from the zecNodeOperatorPoolRewards
    mapping(address => uint256) public ethClaimedByNodeOperators;

    /// @notice Timstamp when the BLS public key was registered in an LSD
    mapping(bytes => uint256) public registerBLSPublicKeyTimestamp;

    /// @notice Amount collected from rage quit for a BLS public key
    mapping(bytes => uint256) public ethCollectedFromRagequitOfBLSPublicKey;

    /// @notice Amount of ETH collected by a user for a BLS public key that has gone through rage quit
    mapping(bytes => mapping(address => uint256))
        public ethCollectedByUserFromRageQuitOFBLSPublicKey;

    /// @notice Timestamp when node operator applied for claiming rewards
    /// @dev The timestamp is reset to 0 once the node operator has claimed rewards
    mapping(address => uint256) public nodeOperatorClaimRewardsTimestamp;

    modifier onlyBlockswapDAO() {
        if (msg.sender != blockswapDAO) revert Errors.OnlyBlockswapDAO();
        _;
    }

    modifier onlyZECCommitteeOrBlockswapDAO() {
        if (
            msg.sender != blockswapDAO &&
            isPartOfZECCommittee[msg.sender] != address(0)
        ) revert Errors.OnlyZECCommitteeOrBlockswapDAO();
        _;
    }

    modifier onlyWhitelistedNodeOperator() {
        if (isNodeOperatorWhitelisted[msg.sender] == address(0))
            revert Errors.OnlyWhitelistedNodeOperator();
        _;
    }

    modifier onlyZECRepresentativeOrZECCommitteeOrBlockswapDAO() {
        if (
            msg.sender != blockswapDAO &&
            msg.sender != zecRepresentative &&
            isPartOfZECCommittee[msg.sender] != address(0)
        ) revert Errors.OnlyZECRepresentativeOrZECCommitteeOrBlockswapDAO();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function init(
        LSDNFactory _factory,
        address _lpDeployer,
        address _upgradeManager,
        address _blockswapDAO,
        uint256 _cipBondAmount,
        uint256 _nodeOperatorRewardsClaimDelay,
        uint256 _blsPublicKeyProposerLimit,
        uint256 _totalZecBLSPublicKeyLimit,
        address _feesAndMevGiantPool,
        address _savETHGiantPool,
        address _stakehouseSafeBox,
        address _zecSafeBox
    ) external virtual initializer {
        _init(
            _factory,
            _lpDeployer,
            _upgradeManager,
            _blockswapDAO,
            _cipBondAmount,
            _nodeOperatorRewardsClaimDelay,
            _blsPublicKeyProposerLimit,
            _totalZecBLSPublicKeyLimit,
            _feesAndMevGiantPool,
            _savETHGiantPool,
            _stakehouseSafeBox,
            _zecSafeBox
        );
        __ReentrancyGuard_init();
        __Pausable_init();
    }

    /// @dev Owner based upgrades
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /// @notice Allow the contract owner to trigger pausing of core features
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Allow the contract owner to trigger unpausing of core features
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Allow Blockswap DAO to increase the limit on total Mintable ZEC BLS Public keys
    /// @param _newLimit New limit on ZEC BLS Public keys
    function updatedTotalZecBLSPublicKeyLimit(
        uint256 _newLimit
    ) external onlyBlockswapDAO {
        require(_newLimit > 0, "New limit cannot be zero");
        require(totalBLSPublicKeysProposed < _newLimit, "New limit too low");

        ZEC_BLS_PUBLIC_KEY_LIMIT = _newLimit;
        emit TotalZecBLSPublicKeyLimitUpdated(_newLimit);
    }

    /// @notice Allow BlockswapDAO or the ZEC Committee member to update the DAO address when the the LSDs update their DAO address in the LSM
    /// @param _liquidStakingManagerAddress LSM of the LSD which has appointed the new DAO address
    /// @param _previousDAOAddress Previously registered DAO address which was the part of ZEC committee
    /// @param _newDAOAddress Newly appointed DAO address of the LSD which is a part of ZEC committee
    function updateDAOAddress(
        address _liquidStakingManagerAddress,
        address _previousDAOAddress,
        address _newDAOAddress
    ) external onlyZECCommitteeOrBlockswapDAO {
        require(
            isPartOfZECCommittee[_previousDAOAddress] != address(0),
            "DAO not a part of ZEC committee"
        );
        require(
            liquidStakingDerivativeFactory.isLiquidStakingManager(
                _liquidStakingManagerAddress
            ),
            "Unknown Liquid Staking Manager"
        );
        require(
            LiquidStakingManager(payable(_liquidStakingManagerAddress)).dao() ==
                _newDAOAddress,
            "DAO not associated with the LSD"
        );

        if (msg.sender != blockswapDAO) {
            require(
                _newDAOAddress == msg.sender,
                "Caller must be the DAO associated with the LSD"
            );
        }

        isPartOfZECCommittee[_previousDAOAddress] = address(0);
        isPartOfZECCommittee[_newDAOAddress] = _liquidStakingManagerAddress;

        emit DAOAddressUpdated(
            _liquidStakingManagerAddress,
            _newDAOAddress,
            _previousDAOAddress
        );
    }

    /// @notice Allow the Blockswap DAO or the ZEC Committee to appoint EOA representative for the ZEC proposed BLS public keys
    /// @param _eoaRepresentative Address of the newly appointed EOA representative
    function appointEOARepresentative(
        address _eoaRepresentative
    ) external onlyZECRepresentativeOrZECCommitteeOrBlockswapDAO {
        require(
            _eoaRepresentative != address(0),
            "EOA representative cannot be zero address"
        );

        eoaRepresentative = eoaRepresentative;
        emit NewEOARepresentativeAppointed(_eoaRepresentative);
    }

    /// @notice Allow BlockswapDAO to appoint an EOA which acts as a ZEC representative in case of key recovery
    /// @param _zecRepresentative Address of the ZEC representative
    function appointZECRepresentative(
        address _zecRepresentative
    ) external onlyBlockswapDAO {
        require(
            _zecRepresentative != address(0),
            "ZEC Representative address cannot be zero"
        );

        zecRepresentative = _zecRepresentative;
        emit NewZECRepresentativeAppointed(_zecRepresentative);
    }

    /// @notice Add new DAO address to ZEC committee. Can be only called by the Blockswap DAO
    /// @dev A DAO address can only register a single LSD of which they are DAO of
    /// @param _liquidStakingManagerAddress Liquid Staking Manager address that the DAO deployed or is owner of
    /// @param _dao DAO address to be added to the ZEC committee
    function addDAOToZECCommittee(
        address _liquidStakingManagerAddress,
        address _dao
    ) external onlyBlockswapDAO {
        require(
            liquidStakingDerivativeFactory.isLiquidStakingManager(
                _liquidStakingManagerAddress
            ),
            "Unknown Liquid Staking Manager"
        );
        require(
            LiquidStakingManager(payable(_liquidStakingManagerAddress)).dao() ==
                _dao,
            "DAO not associated with the LSD"
        );
        require(
            isPartOfZECCommittee[_dao] == address(0),
            "DAO already a part of ZEC committee"
        );

        isPartOfZECCommittee[_dao] = _liquidStakingManagerAddress;

        emit DAOAddedToZECCommittee(_dao, _liquidStakingManagerAddress);
    }

    /// @notice Remove an existing DAO address from the ZEC committee. Can only be called by the Blockswap DAO
    /// @param _dao DAO address to be removed from the ZEC committee
    function removeDAOFromZECCommittee(address _dao) external onlyBlockswapDAO {
        require(_dao != address(0), "DAO cannot be zero address");
        require(
            isPartOfZECCommittee[_dao] != address(0),
            "DAO not a part of ZEC committee"
        );

        isPartOfZECCommittee[_dao] = address(0);

        emit DAORemovedFromZECCommittee(_dao);
    }

    /// @notice Allow BlockswapDAO or the ZEC Committee to whitelist a node operator for an LSD
    /// @param _nodeOperator Address of the Node operator to be whitelisted
    /// @param _liquidStakingManagerAddress Address of the LSM of the LSD to which the node operator will be associated to
    function whitelistNodeOperators(
        address _nodeOperator,
        address _liquidStakingManagerAddress
    ) public onlyZECCommitteeOrBlockswapDAO {
        require(
            _nodeOperator != address(0),
            "Node operator address cannot be zero"
        );
        require(
            _liquidStakingManagerAddress != address(0),
            "Liquid Staking Manager address cannot be zero"
        );
        require(
            liquidStakingDerivativeFactory.isLiquidStakingManager(
                _liquidStakingManagerAddress
            ),
            "Unknown Liquid Staking Manager"
        );
        require(
            isNodeOperatorWhitelisted[_nodeOperator] == address(0),
            "Node operator is already whitelisted"
        );

        if (msg.sender == blockswapDAO) {
            require(
                isPartOfZECCommittee[msg.sender] ==
                    _liquidStakingManagerAddress,
                "DAO is not the owner of LSD provided"
            );
        }

        isNodeOperatorWhitelisted[_nodeOperator] = _liquidStakingManagerAddress;
        emit NodeOperatorWhitelisted(
            _nodeOperator,
            _liquidStakingManagerAddress
        );
    }

    /// @notice Allow Blockswap DAO or the ZEC Committee to whitelist node oeprators in batches to an LSD
    /// @param _nodeOperators Array of address of unique Node operators to be whitelisted
    /// @param _liquidStakingManagerAddress Address of the LSM of the LSD to wich the node operator will be associated to
    function batchWhitelistNodeOperators(
        address[] calldata _nodeOperators,
        address _liquidStakingManagerAddress
    ) external onlyZECCommitteeOrBlockswapDAO {
        require(
            _nodeOperators.length > 0,
            "Node operators array cannot be null"
        );

        for (uint256 i; i < _nodeOperators.length; ++i) {
            whitelistNodeOperators(
                _nodeOperators[i],
                _liquidStakingManagerAddress
            );
        }
    }

    /// @notice Allow ZEC committee or Blockswap DAO to ban a node operator from furhter being a part of ZEC or running ZEC BLS public keys
    /// @dev A banned node operator can still claim their existing rewards accrued
    function banNodeOperators(
        address _nodeOperator
    ) external onlyZECCommitteeOrBlockswapDAO {
        require(
            isNodeOperatorWhitelisted[_nodeOperator] != address(0),
            "Node operator is not a part of ZEC"
        );

        isNodeOperatorWhitelisted[_nodeOperator] = address(0);
        emit NodeOperatorBanned(_nodeOperator);
    }

    /// @notice Allow whitelisted Node operator to propose and register BLS public keys to the desired LSD
    /// @dev This function can only be called if theres enough ETH in ZEC and the other Giant pools
    /// @param _blsPublicKeys BLS public keys being proposed by the node operator
    /// @param _blsSignatures BLS Signatures associated with the BLS public keys
    /// @param _stakeGiantPoolFunds If set to true, allows ETH to be staked from the Giant pools.
    /// If set to false, node operator will have to separately go to the Giant pools to trigger staking of ETH
    function batchDepositETHForStaking(
        bytes[] memory _blsPublicKeys,
        bytes[] memory _blsSignatures,
        address _eoaRepresentative,
        bool _stakeGiantPoolFunds
    )
        external
        payable
        onlyWhitelistedNodeOperator
        whenContractNotPaused
        nonReentrant
    {
        uint256 numberOfBLSPublicKeys = _blsPublicKeys.length;
        require(
            numberOfBLSPublicKeys > 0,
            "BLS public key array cannot be null"
        );
        require(
            totalBLSPublicKeysProposed + numberOfBLSPublicKeys <=
                ZEC_BLS_PUBLIC_KEY_LIMIT,
            "BLS public key ZEC limit exceeded"
        );
        require(
            numberOfBLSPublicKeysProposed[msg.sender] + numberOfBLSPublicKeys <
                BLS_PUBLIC_KEY_PROPOSER_LIMIT,
            "BLS public key porposer limit exceeded"
        );
        require(
            idleETH / 4 >= numberOfBLSPublicKeys,
            "Not enough ETH for these many BLS public keys"
        );
        require(
            CIP_BOND * numberOfBLSPublicKeys == msg.value,
            "CIP Bond amount not satisfied"
        );

        updateAccumulatedETHPerLP();

        address liquidStakingManagerAddress = isNodeOperatorWhitelisted[
            msg.sender
        ];
        LiquidStakingManager liquidStakingManager = LiquidStakingManager(
            payable(liquidStakingManagerAddress)
        );

        liquidStakingManager.registerBLSPublicKeys{
            value: numberOfBLSPublicKeys * 4 ether
        }(_blsPublicKeys, _blsSignatures, _eoaRepresentative);

        for (uint i; i < numberOfBLSPublicKeys; ++i) {
            _onStake(_blsPublicKeys[i]);
            idleETH -= 4 ether;
            numberOfBLSPublicKeysProposed[msg.sender] += 1;
            totalBLSPublicKeysProposed += 1;
            isBLSPubKeyFundedByGiantPool[_blsPublicKeys[i]] = true;
            isCIPBondValid[_blsPublicKeys[i]] = true;
            cipBondCollected += CIP_BOND;
        }

        emit BLSPublicKeyDeposited(_blsPublicKeys, liquidStakingManagerAddress);

        if (_stakeGiantPoolFunds) {
            sendETHFromGiantPools(
                liquidStakingManagerAddress,
                _blsPublicKeys,
                _blsSignatures,
                false
            );
        } else {
            // Only store timestamps if the BLS public keys are not staked by node operator
            for (uint256 i; i < _blsPublicKeys.length; ++i) {
                registerBLSPublicKeyTimestamp[_blsPublicKeys[i]] = block
                    .timestamp;
            }
        }
    }

    /// @notice Allow ZEC committee to stake ETH for which BLS public key had already been registered by the ZEC node operator
    /// @param _liquidStakingManagerAddress Liquid Staking Manager address to stake the BLS public keys
    /// @param _blsPublicKeys Array of BLS public keys to be staked
    /// @param _blsSignatures Array of BLS public key signtures
    /// @param _appointNewEOARepresentative Boolean. False only if the node operator that registered the BLS Public key is calling the function. True otherwise.
    function sendETHFromGiantPools(
        address _liquidStakingManagerAddress,
        bytes[] memory _blsPublicKeys,
        bytes[] memory _blsSignatures,
        bool _appointNewEOARepresentative
    ) public payable whenContractNotPaused nonReentrant {
        require(
            _liquidStakingManagerAddress != address(0),
            "Liquid Staking Manager address cannot be zero"
        );

        uint256 numberOfBLSPublicKeys = _blsPublicKeys.length;
        require(
            numberOfBLSPublicKeys == _blsSignatures.length,
            "Unequal array provided"
        );

        LiquidStakingManager liquidStakingManager = LiquidStakingManager(
            payable(_liquidStakingManagerAddress)
        );

        if (_appointNewEOARepresentative) {
            for (uint256 i; i < numberOfBLSPublicKeys; ++i) {
                liquidStakingManager.rotateEOARepresentative(eoaRepresentative);
            }
        }

        require(
            numberOfBLSPublicKeys * 24 <=
                GiantSavETHVaultPool(payable(savETHGiantPool)).idleETH(),
            "Not enough ETH in Giant SavETH Pool"
        );
        require(
            numberOfBLSPublicKeys * 4 <=
                GiantMevAndFeesPool(payable(feesAndMevGiantPool)).idleETH(),
            "Not enough ETH in Giant SavETH Pool"
        );

        address[] memory savETHVaults;
        address[] memory stakingFundsVaults;
        uint256[] memory savETHTransactionAmounts;
        uint256[] memory feesAndMevETHTransactionAmounts;
        bytes[][] memory blsPublicKeys;
        uint256[][] memory listOfSavETHStakeAmounts;
        uint256[][] memory listOfFeesAndMevStakeAmounts;

        (
            savETHVaults,
            stakingFundsVaults,
            savETHTransactionAmounts,
            feesAndMevETHTransactionAmounts,
            blsPublicKeys,
            listOfSavETHStakeAmounts,
            listOfFeesAndMevStakeAmounts
        ) = _createInputParamsForStaking(
            numberOfBLSPublicKeys,
            liquidStakingManager,
            _blsPublicKeys
        );

        sendGiantPoolFunds(
            numberOfBLSPublicKeys,
            savETHVaults,
            stakingFundsVaults,
            savETHTransactionAmounts,
            feesAndMevETHTransactionAmounts,
            blsPublicKeys,
            listOfSavETHStakeAmounts,
            listOfFeesAndMevStakeAmounts
        );
    }

    /// @notice Allow anyone to callback ETH to the ZEC contract if the BLS public key hasn't been staked yet in an LSD
    /// @param _liquidStakingManagerAddress Liquid Staking Manager address to callback ETH from
    /// @param _blsPublicKey BLS public key assoicated with the funds
    function callBackETH(
        address _liquidStakingManagerAddress,
        bytes calldata _blsPublicKey
    ) external nonReentrant {
        require(
            liquidStakingDerivativeFactory.isLiquidStakingManager(
                _liquidStakingManagerAddress
            ),
            "Unknown Liquid Staking Manager"
        );
        require(
            nodeOperatorOfBLSPublicKey[_blsPublicKey] != address(0),
            "Unknown BLS public key"
        );
        require(
            registerBLSPublicKeyTimestamp[_blsPublicKey] + 1 hours >=
                block.timestamp,
            "Too early"
        );

        LiquidStakingManager liquidStakingManager = LiquidStakingManager(
            payable(_liquidStakingManagerAddress)
        );
        liquidStakingManager.withdrawETHForKnot(address(this), _blsPublicKey);

        // Eject BLS public key and assign funds to a new batch
        _onBringBackETHToGiantPool(_blsPublicKey);
        idleETH += 4 ether;

        // Mark CIP bond as invalid and refund it to the node operator
        isCIPBondValid[_blsPublicKey] = false;
        cipBondCollected -= CIP_BOND;
        totalBLSPublicKeysProposed -= 1;

        address nodeOperator = nodeOperatorOfBLSPublicKey[_blsPublicKey];
        _transferETH(nodeOperator, CIP_BOND);
        numberOfBLSPublicKeysProposed[nodeOperator] -= 1;
    }

    /// @notice Allow anyone to trigger staking of Giant pool ETH
    /// @param numberOfBLSPublicKeysToBeStaked Count of BLS public keys being staked
    /// @param _savETHVaults array of savETH vaults associated with the BLS public keys
    /// @param _stakingFundsVault array of staking funds vault associated with the BLS public keys
    /// @param _savETHTransactionAmounts amount of ETH being staked in each of the savETH vaults
    /// @param _feesAndMevETHTransactionAmounts amount of ETH being staked in each of the fees and MEV pools
    /// @param _blsPublicKeys 2 dimensional array of BLS public keys being staked in their respective LSDs
    /// @param _savETHStakeAmounts 2 dimensional array of amount of ETH to be sent for each BLS public key
    /// @param _feesAndMevStakeAmounts 2 dimensional array of amount of ETH to be sent for each BLS public key
    function sendGiantPoolFunds(
        uint256 numberOfBLSPublicKeysToBeStaked,
        address[] memory _savETHVaults,
        address[] memory _stakingFundsVault,
        uint256[] memory _savETHTransactionAmounts,
        uint256[] memory _feesAndMevETHTransactionAmounts,
        bytes[][] memory _blsPublicKeys,
        uint256[][] memory _savETHStakeAmounts,
        uint256[][] memory _feesAndMevStakeAmounts
    ) public whenContractNotPaused nonReentrant {
        uint256 len = _savETHVaults.length;
        GiantSavETHVaultPool giantSavETHVaultPool = GiantSavETHVaultPool(
            payable(savETHGiantPool)
        );
        GiantMevAndFeesPool giantMevAndFeesPool = GiantMevAndFeesPool(
            payable(feesAndMevGiantPool)
        );
        require(len == _stakingFundsVault.length, "Unequal array length");
        require(
            len == _savETHTransactionAmounts.length,
            "Unequal array length"
        );
        require(
            len == _feesAndMevETHTransactionAmounts.length,
            "Unequal array length"
        );
        require(len == _blsPublicKeys.length, "Unequal array length");
        require(len == _savETHStakeAmounts.length, "Unequal array length");
        require(len == _feesAndMevStakeAmounts.length, "Unequal array length");
        require(
            idleETH / 4 >= numberOfBLSPublicKeysToBeStaked,
            "Not enough ETH in ZEC Pool"
        );
        require(
            numberOfBLSPublicKeysToBeStaked * 24 <=
                giantSavETHVaultPool.idleETH(),
            "Not enough ETH in Giant SavETH Pool"
        );
        require(
            numberOfBLSPublicKeysToBeStaked * 4 <=
                giantMevAndFeesPool.idleETH(),
            "Not enough ETH in Giant SavETH Pool"
        );

        giantSavETHVaultPool.batchDepositETHForStaking(
            _savETHVaults,
            _savETHTransactionAmounts,
            _blsPublicKeys,
            _savETHStakeAmounts
        );

        giantMevAndFeesPool.batchDepositETHForStaking(
            _stakingFundsVault,
            _feesAndMevETHTransactionAmounts,
            _blsPublicKeys,
            _feesAndMevStakeAmounts
        );
    }

    /// @notice Allow ZEC representative, ZEC committee or Blockswap DAO to recover signing key of a BLS public key in case of ragequit or malicious activity
    /// @param _liquidStakingManagerAddress Address of the Liquid Staking Manager that the BLS public key is part of
    /// @param _blsPublicKey BLS public key to recover signing key for
    /// @param _hAesPublicKey Hybrid encryption public key that can unlock multiparty computation used for recovery
    function recoverSigningKeyViaStakehouseProtocol(
        address _liquidStakingManagerAddress,
        bytes calldata _blsPublicKey,
        bytes calldata _hAesPublicKey
    )
        external
        nonReentrant
        onlyZECRepresentativeOrZECCommitteeOrBlockswapDAO
        whenContractNotPaused
    {
        address nodeOperator = nodeOperatorOfBLSPublicKey[_blsPublicKey];
        require(nodeOperator != address(0), "BLS public key not a part of ZEC");

        LiquidStakingManager liquidStakingManager = LiquidStakingManager(
            payable(_liquidStakingManagerAddress)
        );

        // Mark CIP bond as invalid and send it to the Blockswap DAO
        // The Blockswap DAO will send it to whoever called the function
        // Node operator is not entitled for this refund
        isCIPBondValid[_blsPublicKey] = false;
        cipBondCollected -= CIP_BOND;
        _transferETH(blockswapDAO, CIP_BOND);

        liquidStakingManager.recoverSigningKey(
            stakehouseSafeBox,
            nodeOperator,
            _blsPublicKey,
            _hAesPublicKey
        );
    }

    /// @notice Allow ZEC representative, ZEC committee or Blockswap DAO to recover signing key of a BLS public key in case of ragequit or malicious activity
    /// @param _blsPublicKey BLS public key to recover signing key for
    /// @param _stakehouse Stakehouse Address that the BLS public key is part of
    /// @param _hAesPublicKey Hybrid encryption public key that can unlock multiparty computation used for recovery
    function recoverSigningKeyViaZEC(
        bytes calldata _blsPublicKey,
        address _stakehouse,
        bytes calldata _hAesPublicKey
    )
        external
        nonReentrant
        onlyZECRepresentativeOrZECCommitteeOrBlockswapDAO
        whenContractNotPaused
    {
        address nodeOperator = nodeOperatorOfBLSPublicKey[_blsPublicKey];
        require(nodeOperator != address(0), "BLS public key not a part of ZEC");

        ISafeBox safeBox = ISafeBox(zecSafeBox);

        safeBox.applyForDecryption(_blsPublicKey, _stakehouse, _hAesPublicKey);
    }

    /// @notice Allow the rage quit of a knot from the Stakehouse protocol
    /// @param _nodeOperator Address of the node operator  associated with the BLS public key
    function rageQuit(
        address _nodeOperator,
        bytes calldata _data
    )
        external
        payable
        onlyZECRepresentativeOrZECCommitteeOrBlockswapDAO
        nonReentrant
    {
        require(
            _nodeOperator != address(0),
            "Node operator address cannot be zero"
        );

        address liquidStakingManagerAddress = isNodeOperatorWhitelisted[
            _nodeOperator
        ];

        LiquidStakingManager liquidStakingManager = LiquidStakingManager(
            payable(liquidStakingManagerAddress)
        );

        liquidStakingManager.rageQuit(_nodeOperator, _data);
    }

    /// @notice Allow ZEC node operators to raise a request for claiming rewards
    /// @dev Node opeators can claim after 30 mins. of raising request. Once claimed rewards, counter goes back to 0.
    function applyForNodeOperatorClaimingRewards()
        external
        onlyWhitelistedNodeOperator
    {
        require(
            zecNodeOperatorPoolRewards > 0,
            "No ETH to claim. Apply after some time"
        );
        require(
            nodeOperatorClaimRewardsTimestamp[msg.sender] == 0,
            "Request for claiming already raised"
        );

        nodeOperatorClaimRewardsTimestamp[msg.sender] = block.timestamp;
        emit NodeOperatorAppliedForClaimingRewards(msg.sender);
    }

    /// @notice Claim rewards for LP holder
    /// @param _recipient Address that receives ETH rewards
    function claimRewards(
        address _recipient,
        address[] calldata _liquidStakingManagerAddresses,
        bytes[][] calldata _blsPublicKeys
    ) external whenContractNotPaused {
        require(
            totalLPAssociatedWithDerivativesMinted != 0,
            "No derivatives minted"
        );

        fetchZECRewards(_liquidStakingManagerAddresses, _blsPublicKeys);

        claimExistingRewards(_recipient);
    }

    /// @notice Fetch ZEC related accrued ETH rewards from Liquid Staking Manager
    /// @param _liquidStakingManagerAddresses Array of address of Liquid Staking Manager for all ZEC BLS public keys accruing rewards
    /// @param _blsPublicKeys 2D Array of ZEC BLS public keys to fetch rewards for
    function fetchZECRewards(
        address[] calldata _liquidStakingManagerAddresses,
        bytes[][] calldata _blsPublicKeys
    ) public whenContractNotPaused {
        _fetchZECRewards(_liquidStakingManagerAddresses, _blsPublicKeys);
        updateAccumulatedETHPerLP();
    }

    /// @notice Allow a user to claim their reward balance without fetching upstream ETH rewards (that are in syndicates)
    function claimExistingRewards(
        address _recipient
    ) public whenContractNotPaused nonReentrant {
        updateAccumulatedETHPerLP();
        _transferETH(
            _recipient,
            _distributeETHRewardsToUserForToken(
                msg.sender,
                address(lpTokenETH),
                _getTotalLiquidityInActiveRangeForUser(msg.sender),
                _recipient
            )
        );
    }

    /// @notice Total rewards received by this contract from the syndicate excluding idle ETH from LP depositors
    function totalRewardsReceived() public view returns (uint256) {
        return
            address(this).balance +
            totalClaimed -
            idleETH -
            cipBondCollected -
            availableRagequitETH;
    }

    /// @notice Distribute any new ETH received to LP holders
    function updateAccumulatedETHPerLP() public whenContractNotPaused {
        _updateAccumulatedETHPerLP(totalLPAssociatedWithDerivativesMinted);
    }

    /// @notice Get total liquidity that is in active reward range for user
    function getTotalLiquidityInActiveRangeForUser(
        address _user
    ) external view returns (uint256) {
        return _getTotalLiquidityInActiveRangeForUser(_user);
    }

    /// @notice Allow ETH to be deposited for a BLS public key after rage quit
    /// @dev This ETH should be available to claim for LP holders of the BLS public key
    /// @param _blsPublicKey BLS public key that has gone through rage quit
    function depositRagequitETH(bytes calldata _blsPublicKey) external payable {
        require(
            nodeOperatorOfBLSPublicKey[_blsPublicKey] != address(0),
            "BLS Public key not a part of ZEC"
        );

        ethCollectedFromRagequitOfBLSPublicKey[_blsPublicKey] += msg.value;
        availableRagequitETH += msg.value;

        emit ETHDepositedFromRagequit(_blsPublicKey, msg.value);
    }

    /// @notice Allow LP holders to claim ETH for the BLS public key they deposited ETH for
    /// @param _blsPublicKey Rage quit BLS public key
    /// @param _recipient Recipient address of the rage quit ETH
    /// @return Amount claimed by the user
    function claimRagequitETH(
        bytes calldata _blsPublicKey,
        address _recipient
    ) external nonReentrant returns (uint256) {
        require(
            nodeOperatorOfBLSPublicKey[_blsPublicKey] != address(0),
            "BLS Public key not a part of ZEC"
        );
        require(availableRagequitETH > 0, "No rage quit ETH found");
        require(
            ethCollectedFromRagequitOfBLSPublicKey[_blsPublicKey] > 0,
            "No claimable rage quit ETH for this BLS public key found"
        );

        uint256 batchId = allocatedWithdrawalBatchForBlsPubKey[_blsPublicKey];
        uint256 ethDeposited = totalETHFundedPerBatch[msg.sender][batchId];

        require(ethDeposited > 0, "No ETH deposited for this BLS public key");

        uint256 ethClaimed = ethCollectedByUserFromRageQuitOFBLSPublicKey[
            _blsPublicKey
        ][msg.sender];
        uint256 totalClaimableRagequitAmount = (ethCollectedFromRagequitOfBLSPublicKey[
                _blsPublicKey
            ] * ethDeposited) / batchSize;
        uint256 availableToClaim = totalClaimableRagequitAmount - ethClaimed;

        require(availableToClaim > 0, "Already claimed rage quit ETH");

        availableRagequitETH -= availableToClaim;
        ethCollectedByUserFromRageQuitOFBLSPublicKey[_blsPublicKey][
            msg.sender
        ] += availableToClaim;
        _transferETH(_recipient, availableToClaim);

        emit RagequitETHCollectedByUser(
            _blsPublicKey,
            msg.sender,
            _recipient,
            availableToClaim
        );
    }

    /// @notice Allow anyone to preview rewards accrued by a node operator
    /// @param _nodeOperator Address of the node operator
    /// @return uint256 claimableETH ETH: rewards accrued by the node operator
    /// @return bool claimable: true if wait time is over and allowed to claim. False otherwise.
    function previewNodeOperatorRewards(
        address _nodeOperator
    ) external view returns (uint256, bool) {
        return _previewNodeOperatorRewards(_nodeOperator);
    }

    /// @notice internal function to create array of input parameters for staking.
    function _createInputParamsForStaking(
        uint256 _numberOfBLSPublicKeys,
        LiquidStakingManager _liquidStakingManager,
        bytes[] memory _blsPublicKeys
    )
        internal
        returns (
            address[] memory,
            address[] memory,
            uint256[] memory,
            uint256[] memory,
            bytes[][] memory,
            uint256[][] memory,
            uint256[][] memory
        )
    {
        address savETHVault = address(_liquidStakingManager.savETHVault());
        address stakingFundsVault = address(
            _liquidStakingManager.stakingFundsVault()
        );

        address[] memory savETHVaults = new address[](1);
        savETHVaults[0] = savETHVault;

        address[] memory stakingFundsVaults = new address[](1);
        stakingFundsVaults[0] = stakingFundsVault;

        uint256[] memory savETHTransactionAmounts = new uint256[](1);
        savETHTransactionAmounts[0] = 24 ether * _numberOfBLSPublicKeys;

        uint256[] memory feesAndMevETHTransactionAmounts = new uint256[](1);
        feesAndMevETHTransactionAmounts[0] = 4 ether * _numberOfBLSPublicKeys;

        bytes[][] memory blsPublicKeys;
        blsPublicKeys[0] = _blsPublicKeys;

        uint256[][] memory listOfSavETHStakeAmounts;
        uint256[] memory savETHStakeAmounts = new uint256[](
            _numberOfBLSPublicKeys
        );

        uint256[][] memory listOfFeesAndMevStakeAmounts;
        uint256[] memory feesAndMevStakeAmounts = new uint256[](
            _numberOfBLSPublicKeys
        );

        for (uint256 i; i < _numberOfBLSPublicKeys; ++i) {
            savETHStakeAmounts[i] = 24 ether;
            feesAndMevStakeAmounts[i] = 4 ether;
        }

        listOfSavETHStakeAmounts[0] = savETHStakeAmounts;
        listOfFeesAndMevStakeAmounts[0] = feesAndMevStakeAmounts;

        return (
            savETHVaults,
            stakingFundsVaults,
            savETHTransactionAmounts,
            feesAndMevETHTransactionAmounts,
            blsPublicKeys,
            listOfSavETHStakeAmounts,
            listOfFeesAndMevStakeAmounts
        );
    }

    /// @notice Fetch ZEC related accrued rewards from the Liquid Staking Manager
    function _fetchZECRewards(
        address[] calldata _liquidStakingManagerAddresses,
        bytes[][] calldata _blsPublicKeys
    ) internal {
        uint256 arrayLength = _liquidStakingManagerAddresses.length;
        require(arrayLength != 0, "Null value provided");
        require(arrayLength == _blsPublicKeys.length, "Null value provided");

        for (uint256 i; i < arrayLength; ++i) {
            require(
                liquidStakingDerivativeFactory.isLiquidStakingManager(
                    _liquidStakingManagerAddresses[i]
                ),
                "Unknown Liquid Staking Manager address provided"
            );
            require(
                _blsPublicKeys[i].length != 0,
                "No value provided for BLS public keys"
            );
            LiquidStakingManager liquidStakingManager = LiquidStakingManager(
                payable(_liquidStakingManagerAddresses[i])
            );

            liquidStakingManager.claimRewardsAsNodeRunner(
                address(this),
                _blsPublicKeys[i]
            );
        }
    }

    /// @notice Allow liquid staking managers to notify the giant pool about derivatives minted for a key
    function _onMintDerivatives(
        bytes calldata _blsPublicKey
    ) internal override {
        // use this to update active liquidity range for distributing rewards
        address nodeOperator = nodeOperatorOfBLSPublicKey[_blsPublicKey];

        if (nodeOperator != address(0)) {
            // Capture accumulated LP at time of minting derivatives
            accumulatedETHPerLPAtTimeOfMintingDerivatives[
                _blsPublicKey
            ] = accumulatedETHPerLPShare;
            totalLPAssociatedWithDerivativesMinted += 4 ether;
            totalBLSPublicKeysProposedAndMinted += 1;
            numberOfBLSPublicKeysProposedAndMinted[nodeOperator] += 1;
        }
    }

    /// @dev Any due rewards from node running can be distributed to msg.sender if they have an LP balance
    function _distributeETHRewardsToUserForToken(
        address _user,
        address _token,
        uint256 _balance,
        address _recipient
    ) internal virtual returns (uint256) {
        require(_recipient == address(0), "Recipient cannot be zero address");
        uint256 balance = _balance;
        uint256 due;

        // Claimable rewards for Node operators
        if (isNodeOperatorWhitelisted[_user] != address(0)) {
            require(
                nodeOperatorClaimRewardsTimestamp[_user] + CLAIM_DELAY >=
                    block.timestamp,
                "Claiming not allowed yet"
            );

            uint256 ethClaimedSoFar = ethClaimedByNodeOperators[_user];
            uint256 ethProRataShare = (zecNodeOperatorPoolRewards *
                numberOfBLSPublicKeysProposedAndMinted[_user]) /
                totalBLSPublicKeysProposedAndMinted;

            if (ethClaimedSoFar < ethProRataShare) {
                uint256 claimableETH = ethProRataShare - ethClaimedSoFar;
                ethClaimedByNodeOperators[_user] += claimableETH;
                zecNodeOperatorPoolRewards -= claimableETH;
                nodeOperatorClaimRewardsTimestamp[_user] = 0;

                _transferETH(_recipient, claimableETH);

                emit RewardsClaimedByNodeOperator(
                    _user,
                    _recipient,
                    claimableETH
                );
            }
        }
        // Claimable rewards for LP holders
        else {
            if (balance > 0) {
                // Calculate how much ETH rewards the address is owed / due
                due =
                    ((accumulatedETHPerLPShare * balance) / PRECISION) -
                    _getTotalClaimedForUserAndToken(_user, _token, balance);
                if (due > 0) {
                    _increaseClaimedForUserAndToken(
                        _user,
                        _token,
                        due,
                        balance
                    );

                    totalClaimed += due;

                    emit ETHDistributed(_user, _recipient, due);
                }
            }
        }

        return due;
    }

    /// @dev Total claimed for a user and LP token needs to be based on when derivatives were minted so that pro-rated share is not earned too early causing phantom balances
    function _getTotalClaimedForUserAndToken(
        address _user,
        address _token,
        uint256 _currentBalance
    ) internal view returns (uint256) {
        uint256 claimedSoFar = claimed[_user][_token];

        // Handle the case where all LP is withdrawn or some derivatives are not minted
        if (_currentBalance == 0) revert Errors.InvalidAmount();

        if (claimedSoFar > 0) {
            claimedSoFar =
                (lastAccumulatedLPAtLastLiquiditySize[_user] *
                    _currentBalance) /
                PRECISION;
        } else {
            uint256 batchId = setOfAssociatedDepositBatches[_user].at(0);
            bytes memory blsPublicKey = allocatedBlsPubKeyForWithdrawalBatch[
                batchId
            ];
            claimedSoFar =
                (_currentBalance *
                    accumulatedETHPerLPAtTimeOfMintingDerivatives[
                        blsPublicKey
                    ]) /
                PRECISION;
        }

        // Either user has a claimed amount or their claimed amount needs to be based on accumulated ETH at time of minting derivatives
        return claimedSoFar;
    }

    /// @dev Use _getTotalClaimedForUserAndToken to correctly track and save total claimed by a user for a token
    function _increaseClaimedForUserAndToken(
        address _user,
        address _token,
        uint256 _increase,
        uint256 _balance
    ) internal {
        // _getTotalClaimedForUserAndToken will factor in accumulated ETH at time of minting derivatives
        lastAccumulatedLPAtLastLiquiditySize[_user] = accumulatedETHPerLPShare;
        claimed[_user][_token] =
            _getTotalClaimedForUserAndToken(_user, _token, _balance) +
            _increase;
    }

    /// @dev Internal logic for tracking accumulated ETH per share
    function _updateAccumulatedETHPerLP(uint256 _numOfShares) internal {
        if (_numOfShares > 0) {
            uint256 received = totalRewardsReceived();
            uint256 unprocessed = received - totalETHSeen;

            if (unprocessed > 0) {
                emit ETHReceived(unprocessed);

                // 20% of the rewards go to the Node operator
                uint256 nodeOperatorShare = (unprocessed * 2e24) / 1e24;

                // accumulated ETH per minted share is scaled to avoid precision loss. it is scaled down later
                accumulatedETHPerLPShare +=
                    ((unprocessed - nodeOperatorShare) * PRECISION) /
                    _numOfShares;

                zecNodeOperatorPoolRewards += nodeOperatorShare;

                totalETHSeen = received;
            }
        }
    }

    /// @notice Allow giant LP token to notify pool about transfers so the claimed amounts can be processed
    function beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _amount
    ) external whenContractNotPaused {
        if (msg.sender != address(lpTokenETH)) revert Errors.InvalidCaller();

        updateAccumulatedETHPerLP();

        // Make sure that `_from` gets total accrued before transfer as post transferred anything owed will be wiped
        if (_from != address(0)) {
            (
                uint256 activeLiquidityFrom,
                uint256 lpBalanceFromBefore
            ) = _distributePendingETHRewards(_from);
            if (lpTokenETH.balanceOf(_from) != lpBalanceFromBefore)
                revert Errors.ReentrancyCall();

            lastAccumulatedLPAtLastLiquiditySize[
                _from
            ] = accumulatedETHPerLPShare;
            claimed[_from][msg.sender] = activeLiquidityFrom == 0
                ? 0
                : (accumulatedETHPerLPShare * (activeLiquidityFrom - _amount)) /
                    PRECISION;
        }

        // Make sure that `_to` gets total accrued before transfer as post transferred anything owed will be wiped
        if (_to != address(0)) {
            (
                uint256 activeLiquidityTo,
                uint256 lpBalanceToBefore
            ) = _distributePendingETHRewards(_to);
            if (lpTokenETH.balanceOf(_to) != lpBalanceToBefore)
                revert Errors.ReentrancyCall();
            if (lpBalanceToBefore > 0) {
                claimed[_to][msg.sender] =
                    (accumulatedETHPerLPShare * (activeLiquidityTo + _amount)) /
                    PRECISION;
            } else {
                claimed[_to][msg.sender] =
                    (accumulatedETHPerLPShare * _amount) /
                    PRECISION;
            }

            lastAccumulatedLPAtLastLiquiditySize[
                _to
            ] = accumulatedETHPerLPShare;
        }
    }

    /// @dev Re-usable function for distributing rewards based on having an LP balance and active liquidity from minting derivatives
    function _distributePendingETHRewards(
        address _receiver
    )
        internal
        returns (
            uint256 activeLiquidityReceivingRewards,
            uint256 lpTokenETHBalance
        )
    {
        lpTokenETHBalance = lpTokenETH.balanceOf(_receiver);
        if (lpTokenETHBalance > 0) {
            activeLiquidityReceivingRewards = _getTotalLiquidityInActiveRangeForUser(
                _receiver
            );
            if (activeLiquidityReceivingRewards > 0) {
                _transferETH(
                    _receiver,
                    _distributeETHRewardsToUserForToken(
                        _receiver,
                        address(lpTokenETH),
                        activeLiquidityReceivingRewards,
                        _receiver
                    )
                );
            }
        }
    }

    /// @dev Utility for fetching total ETH that is eligble to receive rewards for a user
    function _getTotalLiquidityInActiveRangeForUser(
        address _user
    ) internal view returns (uint256) {
        uint256 totalLiquidityInActiveRangeForUser;
        uint256 totalNumOfBatches = setOfAssociatedDepositBatches[_user]
            .length();

        for (uint256 i; i < totalNumOfBatches; ++i) {
            uint256 batchId = setOfAssociatedDepositBatches[_user].at(i);

            if (
                !_isDerivativesMinted(
                    allocatedBlsPubKeyForWithdrawalBatch[batchId]
                )
            ) {
                // Derivatives are not minted for this batch so continue as elements in enumerable set are not guaranteed any order
                continue;
            }

            totalLiquidityInActiveRangeForUser += totalETHFundedPerBatch[_user][
                batchId
            ];
        }

        return totalLiquidityInActiveRangeForUser;
    }

    /// @dev Given a BLS pub key, whether derivatives are minted
    function _isDerivativesMinted(
        bytes memory _blsPubKey
    ) internal view returns (bool) {
        return
            getAccountManager().blsPublicKeyToLifecycleStatus(_blsPubKey) ==
            IDataStructures.LifecycleStatus.TOKENS_MINTED;
    }

    /// @dev preview ETH rewards accrued by node operator
    function _previewNodeOperatorRewards(
        address _nodeOperator
    ) internal view returns (uint256, bool) {
        require(
            isNodeOperatorWhitelisted[_nodeOperator] != address(0),
            "Not a ZEC node operator"
        );

        uint256 claimableETH;
        bool claimable;

        if (
            nodeOperatorClaimRewardsTimestamp[_nodeOperator] + CLAIM_DELAY >=
            block.timestamp
        ) {
            claimable = true;
        } else {
            claimable = false;
        }

        uint256 ethClaimedSoFar = ethClaimedByNodeOperators[_nodeOperator];
        uint256 ethProRataShare = (zecNodeOperatorPoolRewards *
            numberOfBLSPublicKeysProposedAndMinted[_nodeOperator]) /
            totalBLSPublicKeysProposedAndMinted;

        if (ethClaimedSoFar < ethProRataShare) {
            claimableETH = ethProRataShare - ethClaimedSoFar;
        }

        return (claimableETH, claimable);
    }

    /// @notice Allow anyone to slash BLS public keys which might be leaking.
    /// @dev If the BLS public key is slashed, the node operator rewards are used to top up the BLS public key
    /// @param _stakehouse Stakehouse address of the BLS public key
    /// @param _liquidStakingManagerAddress Liquid Staking Manager address that the BLS public key is part of
    /// @param _blsPublicKey BLS public key to be slashed
    /// @param _eth2Report Consensus layer report of the BLS public key
    /// @param _signatureMetadata EIP712 sugnature of the _eth2Report
    function slash(
        address _stakehouse,
        address _liquidStakingManagerAddress,
        bytes calldata _blsPublicKey,
        IDataStructures.ETH2DataReport calldata _eth2Report,
        IDataStructures.EIP712Signature calldata _signatureMetadata
    ) external {
        bool isSlashed = _slash(
            _stakehouse,
            _blsPublicKey,
            _eth2Report,
            _signatureMetadata
        );

        if (isSlashed) {
            // Get the current slashed amount which needs to be topped up
            uint256 currentSlashedAmount = getSlotRegistry()
                .currentSlashedAmountForKnot(_blsPublicKey);

            uint256 nodeOperatorRewards;
            address nodeOperator = nodeOperatorOfBLSPublicKey[_blsPublicKey];
            (nodeOperatorRewards, ) = _previewNodeOperatorRewards(nodeOperator);

            if (nodeOperatorRewards > 0) {
                uint256 topUpAmount;
                if (nodeOperatorRewards > currentSlashedAmount) {
                    topUpAmount = currentSlashedAmount;

                    // send rest of the reward amount to node operator and update the storage
                    uint256 remainingETH = nodeOperatorRewards - topUpAmount;

                    ethClaimedByNodeOperators[nodeOperator] += remainingETH;
                    zecNodeOperatorPoolRewards -= remainingETH;

                    _transferETH(nodeOperator, remainingETH);
                } else {
                    // since nodeOperatorRewards <= currentSlashedAmount, use all of the nodeOperatorRewards to top up
                    topUpAmount = nodeOperatorRewards;
                }

                ethClaimedByNodeOperators[nodeOperator] += topUpAmount;
                zecNodeOperatorPoolRewards -= topUpAmount;

                _topUpSlashedSlot{value: topUpAmount}(
                    _stakehouse,
                    _liquidStakingManagerAddress,
                    _blsPublicKey,
                    topUpAmount
                );
            }
        }
    }

    /// @notice Internal function for slashing a BLS public key
    /// @param _stakehouse Stakehouse address of the BLS public key
    /// @param _blsPublicKey BLS public key to be slashed
    /// @param _eth2Report Consensus layer report of the BLS public key
    /// @param _signatureMetadata EIP712 sugnature of the _eth2Report
    /// @return true if slashed, false otherwise
    function _slash(
        address _stakehouse,
        bytes calldata _blsPublicKey,
        IDataStructures.ETH2DataReport calldata _eth2Report,
        IDataStructures.EIP712Signature calldata _signatureMetadata
    ) internal returns (bool) {
        IDataStructures.ETH2DataReport memory lastReport = getAccountManager()
            .getLastKnownStateByPublicKey(_blsPublicKey);

        bool isSLOTReducing = (_eth2Report.activeBalance <
            (32 ether / 1 gwei) &&
            _eth2Report.activeBalance < lastReport.activeBalance);

        if (isSLOTReducing) {
            getBalanceReporter().slash(
                _stakehouse,
                _blsPublicKey,
                _eth2Report,
                _signatureMetadata
            );

            return true;
        } else {
            return false;
        }
    }

    /// @notice Allow anyone to top up a slashed ZEC BLS public key. Can be used in instances such as CIP key recovery, rage quit, etc.
    /// @param _stakehouse Address of the Stakehouse to which the BLS public key belongs
    /// @param _liquidStakingManagerAddress Address of the Liquid Staking Manager associated with the BLS public key
    function _topUpSlashedSlot(
        address _stakehouse,
        address _liquidStakingManagerAddress,
        bytes calldata _blsPublicKey,
        uint256 _topUpAmount
    ) public payable {
        require(
            liquidStakingDerivativeFactory.isLiquidStakingManager(
                _liquidStakingManagerAddress
            ),
            "Unknown Liquid Staking Manager"
        );
        require(
            nodeOperatorOfBLSPublicKey[_blsPublicKey] != address(0),
            "Unknown BLS public key"
        );

        LiquidStakingManager liquidStakingManager = LiquidStakingManager(
            payable(_liquidStakingManagerAddress)
        );
        address smartWallet = liquidStakingManager.smartWalletOfNodeRunner(
            address(this)
        );

        // Topup KNOT. Can be used for instances such as key recovery
        getBalanceReporter().topUpSlashedSlot{value: msg.value}(
            _stakehouse,
            _blsPublicKey,
            smartWallet,
            _topUpAmount
        );

        emit ZECBLSPUblicKeyToppedUp(
            _blsPublicKey,
            _liquidStakingManagerAddress,
            _topUpAmount
        );
    }

    function _assertContractNotPaused() internal override {
        if (paused()) revert Errors.ContractPaused();
    }

    function _init(
        LSDNFactory _factory,
        address _lpDeployer,
        address _upgradeManager,
        address _blockswapDAO,
        uint256 _cipBondAmount,
        uint256 _nodeOperatorRewardsClaimDelay,
        uint256 _blsPublicKeyProposerLimit,
        uint256 _totalZecBLSPublicKeyLimit,
        address _feesAndMevGiantPool,
        address _savETHGiantPool,
        address _stakehouseSafeBox,
        address _zecSafeBox
    ) internal virtual {
        lpTokenETH = GiantLP(
            GiantLPDeployer(_lpDeployer).deployToken(
                address(this),
                address(this),
                "ZECLP",
                "zecETH"
            )
        );
        liquidStakingDerivativeFactory = _factory;
        batchSize = 4 ether;
        CIP_BOND = _cipBondAmount;
        CLAIM_DELAY = _nodeOperatorRewardsClaimDelay;
        BLS_PUBLIC_KEY_PROPOSER_LIMIT = _blsPublicKeyProposerLimit;
        ZEC_BLS_PUBLIC_KEY_LIMIT = _totalZecBLSPublicKeyLimit;
        blockswapDAO = _blockswapDAO;
        feesAndMevGiantPool = _feesAndMevGiantPool;
        savETHGiantPool = _savETHGiantPool;
        stakehouseSafeBox = _stakehouseSafeBox;
        zecSafeBox = _zecSafeBox;
        _transferOwnership(_upgradeManager);
    }
}
