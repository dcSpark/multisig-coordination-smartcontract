//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "./ERC1967.sol";
import "./State.sol";

/// @title Multisig
/// @dev Contains multisig functionality for the SidechainBridge, i.e. defines
/// what it means for the bridge to be owned by the Milkomeda validators,
/// and how they can propose arbitrary transaction execution when confirmed
/// by a majority of them.
/// Don't define any storage variables here!
abstract contract Multisig is ERC1967, State {
    /// @dev Emitted when a validator votes for a transaction proposal
    event Confirmation(address indexed sender, bytes32 indexed transactionId);
    /// @dev Emitted when a transaction proposal gets executed successfully
    event Execution(bytes32 indexed transactionId);
    /// @dev Emitted when a transaction proposal gathers `quorum` of votes
    /// but its execution fails
    event ExecutionFailure(bytes32 indexed transactionId);
    /// @dev Emitted when validators are added, removed or replaced.
    /// An address field can be empty (equal 0) if corresponding change is not
    /// performed.
    event ValidatorsUpdated(
        address indexed removedValidator,
        address indexed addedValidator
    );
    /// @dev Emitted when quorum or validator set is changed
    event QuorumChanged(uint256 quorum, string stargateAddress);

    /// @dev A central modifier implementing the "validator-majority only"
    /// functionality: the bridge contract itself will call a function only
    /// when `quorum` of validators have voted for it.
    modifier onlyBridge() {
        if (msg.sender != address(this)) revert("Sender is not the bridge");
        _;
    }

    modifier validatorDoesNotExist(address validator) {
        if (isValidator[validator]) revert("Validator exists");
        _;
    }

    modifier validatorExists(address validator) {
        if (!isValidator[validator]) revert("Validator doesn't exist");
        _;
    }

    modifier confirmed(bytes32 transactionId, address validator) {
        if (!confirmations[transactionId][validator])
            revert("Transaction not confirmed by validator");
        _;
    }

    modifier notConfirmed(bytes32 transactionId, address validator) {
        if (confirmations[transactionId][validator])
            revert("Transaction confirmed by validator");
        _;
    }

    modifier notExecuted(bytes32 transactionId) {
        if (transactions[transactionId].executed)
            revert("Transaction already executed");
        _;
    }

    modifier notNull(address _address) {
        if (_address == address(0)) revert("Null address");
        _;
    }

    modifier validRequirement(uint256 validatorCount, uint256 _quorum) {
        if (_quorum > validatorCount || _quorum == 0 || validatorCount == 0)
            revert("Invalid quorum");
        if (_quorum < validatorCount / 2 + 1)
            revert("Quorum does not meet 51% majority");
        _;
    }

    /*
     * Public functions
     */
    /// @dev Allows to add a new validator. Only doable by validator majority!
    /// @param validator Address of the new validator.
    /// @param newQuorum New quorum.
    /// @param newStargateAddress New stargate address.
    function addValidator(
        address validator,
        uint256 newQuorum,
        string calldata newStargateAddress
    ) public onlyBridge validatorDoesNotExist(validator) notNull(validator) {
        isValidator[validator] = true;
        validators.push(validator);
        emit ValidatorsUpdated(address(0), validator);
        changeQuorum(newQuorum, newStargateAddress);
    }

    /// @dev Allows to remove a validator. Only doable by validator majority!
    /// @param validator Address of the validator.
    /// @param newQuorum New quorum.
    /// @param newStargateAddress New stargate address.
    function removeValidator(
        address validator,
        uint256 newQuorum,
        string calldata newStargateAddress
    ) public onlyBridge validatorExists(validator) {
        // Validator's votes on sidechain and unwrapping proposals won't be
        // cleared as this is unnecessary (same in replaceValidator).
        // Removal of votes on the finished transactions would have no effect.
        // As for unfinished proposals, we rely on the honest majority of
        // validators to continuously guarantee that proposals are being voted
        // if they are necessary. I.e. if a bad actor who was voting on invalid
        // proposals is being removed, we assume the honest majority will not
        // vote for given invalid proposals anyway or that a valid proposal
        // would have been passed without him, so his contribution is not
        // detrimental.

        isValidator[validator] = false;
        for (uint256 i = 0; i < validators.length - 1; i++)
            if (validators[i] == validator) {
                validators[i] = validators[validators.length - 1];
                break;
            }
        validators.pop();
        emit ValidatorsUpdated(validator, address(0));
        changeQuorum(newQuorum, newStargateAddress);
    }

    /// @dev Allows to replace a validator with a new validator. Only doable by
    /// validator majority!
    /// @param validator Address of the validator to be replaced.
    /// @param newValidator Address of the validator to be added.
    function replaceValidator(
        address validator,
        address newValidator,
        string calldata newStargateAddress
    )
        public
        onlyBridge
        validatorExists(validator)
        validatorDoesNotExist(newValidator)
        notNull(newValidator)
    {
        for (uint256 i = 0; i < validators.length; i++)
            if (validators[i] == validator) {
                validators[i] = newValidator;
                break;
            }
        isValidator[validator] = false;
        isValidator[newValidator] = true;
        emit ValidatorsUpdated(validator, newValidator);
        changeQuorum(quorum, newStargateAddress);
    }

    /// @dev Allows to change the quorum. Only doable by validator majority!
    /// @param _quorum Number of votes needed to execute a transaction.
    function changeQuorum(uint256 _quorum, string calldata newStargateAddress)
        public
        onlyBridge
        validRequirement(validators.length, _quorum)
    {
        if (
            quorum != _quorum ||
            keccak256(bytes(stargateAddress)) !=
            keccak256(bytes(newStargateAddress))
        ) {
            quorum = _quorum;
            stargateAddress = newStargateAddress;
            emit QuorumChanged(quorum, stargateAddress);
        }
    }

    /// @dev Return address of current logic contract
    function getImplementation() public view returns (address) {
        return _getImplementation();
    }

    /// @dev Allows to upgrade the bridge by changing its implementation
    /// address. Only doable by validator majority!
    /// @param newContract New logic contract (implementation) address.
    function upgradeContract(address newContract) public onlyBridge {
        if (_getImplementation() != newContract) {
            _setImplementation(newContract);
            emit Upgraded(newContract);
        }
    }

    /// @dev Returns if there is a transaction proposal stored under given id.
    /// @param transactionId Unique id of transaction.
    function transactionExists(bytes32 transactionId)
        public
        view
        returns (bool)
    {
        return transactions[transactionId].destination != address(0);
    }

    /// @dev Allows a validator to vote for a transaction. If the transactionId
    /// doesn't exist yet, the transaction will be created. If the transactionId
    /// exists and remaining arguments are equal to stored ones, the validator's
    /// vote for the transaction is added. If any argument differs from its
    /// stored counterpart, the function reverts.
    /// @param transactionId Unique id of the transaction.
    /// @param destination Transaction target address.
    /// @param value Transaction wMAIN value.
    /// @param data Transaction data payload.
    function voteForTransaction(
        bytes32 transactionId,
        address destination,
        uint256 value,
        bytes calldata data,
        bool hasReward
    ) public nonReentrant validatorExists(msg.sender) {
        if (!transactionExists(transactionId))
            addTransaction(transactionId, destination, value, data, hasReward);
        else {
            Transaction storage transaction = transactions[transactionId];
            if (isVoteToAddValidator(data, destination))
                require(
                    block.timestamp <= transaction.validatorVotePeriod,
                    "Time expired to vote validator"
                );
            require(
                transaction.destination == destination &&
                    transaction.value == value &&
                    transaction.hasReward == hasReward &&
                    keccak256(transaction.data) == keccak256(data),
                "Request id exists with incompatible data"
            );
        }
        confirmTransaction(transactionId);
    }

    /// @dev Allows anyone to execute a confirmed transaction.
    /// @param transactionId Transaction ID.
    function executeTransaction(bytes32 transactionId)
        public
        nonReentrant
        notExecuted(transactionId)
    {
        reentrantExecuteTransaction(transactionId);
    }

    /// @dev Fullfills the purpose executeTransaction but without reentrancy
    /// protection to be called by other public functions.
    /// @param transactionId Transaction ID.
    function reentrantExecuteTransaction(bytes32 transactionId)
        internal
        notExecuted(transactionId)
    {
        if (isConfirmed(transactionId)) {
            Transaction storage transaction = transactions[transactionId];
            transaction.executed = true;
            uint256 value = transaction.value;
            if (transaction.hasReward) {
                require(value >= WRAPPING_FEE, "Not enough wmain for fee!");
                value -= WRAPPING_FEE;
            }
            (bool success, ) = transaction.destination.call{value: value}(
                transaction.data
            );
            if (success) {
                if (transaction.hasReward) {
                    rewardsPot += WRAPPING_FEE;
                }
                emit Execution(transactionId);
            } else {
                emit ExecutionFailure(transactionId);
                transaction.executed = false;
            }
        }
    }

    /// @dev Returns the confirmation status of a transaction.
    /// @param transactionId Transaction ID.
    /// @return Confirmation status.
    function isConfirmed(bytes32 transactionId) public view returns (bool) {
        uint256 count = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            if (confirmations[transactionId][validators[i]]) count += 1;
            if (count == quorum) return true;
        }
        return false;
    }

    /*
     * Internal functions
     */
    /// @dev Adds a new transaction to the transaction mapping, if the
    /// transaction does not exist yet.
    /// @param transactionId Requested id to store the transaction under.
    /// @param destination Transaction target address.
    /// @param value Transaction ether value.
    /// @param data Transaction data payload.
    function addTransaction(
        bytes32 transactionId,
        address destination,
        uint256 value,
        bytes calldata data,
        bool hasReward
    ) internal notNull(destination) {
        transactions[transactionId] = Transaction({
            destination: destination,
            value: value,
            data: data,
            executed: false,
            hasReward: hasReward,
            validatorVotePeriod: isVoteToAddValidator(data, destination)
                ? block.timestamp + ADD_VALIDATOR_VOTE_PERIOD
                : 0
        });
        transactionIds.push(transactionId);
    }

    /// @dev checks if transaction data is to vote to add a new validator
    function isVoteToAddValidator(bytes calldata data, address destination)
        internal
        view
        returns (bool)
    {
        if (data.length > 4) {
            return
                bytes4(data[:4]) == this.addValidator.selector &&
                destination == address(this);
        }

        return false;
    }

    /// @dev Confirms a transaction by current sender.
    /// @param transactionId Transaction ID.
    function confirmTransaction(bytes32 transactionId)
        internal
        notConfirmed(transactionId, msg.sender)
    {
        confirmations[transactionId][msg.sender] = true;
        emit Confirmation(msg.sender, transactionId);
        if (!transactions[transactionId].executed)
            reentrantExecuteTransaction(transactionId);
    }

    /*
     * Web3 call functions
     */
    /// @dev Returns number of confirmations of a transaction.
    /// @param transactionId Transaction ID.
    /// @return count Number of confirmations.
    function getConfirmationCount(bytes32 transactionId)
        public
        view
        returns (uint256 count)
    {
        for (uint256 i = 0; i < validators.length; i++)
            if (confirmations[transactionId][validators[i]]) count += 1;
    }

    /// @dev Returns total number of transactions after filters are applied.
    /// @param pending Include pending transactions.
    /// @param executed Include executed transactions.
    /// @return count Total number of transactions after filters are applied.
    function getTransactionCount(bool pending, bool executed)
        public
        view
        returns (uint256 count)
    {
        for (uint256 i = 0; i < transactionIds.length; i++) {
            bool txExecuted = transactions[transactionIds[i]].executed;
            if ((!txExecuted && pending) || (txExecuted && executed))
                count += 1;
        }
    }

    /// @dev Returns list of validators.
    /// @return List of validator addresses.
    function getValidators() public view returns (address[] memory) {
        return validators;
    }

    /// @dev Returns array with validator addresses, which confirmed
    /// the transaction.
    /// @param transactionId Transaction ID.
    /// @return _confirmations Returns array of validator addresses.
    function getConfirmations(bytes32 transactionId)
        public
        view
        returns (address[] memory _confirmations)
    {
        address[] memory confirmationsTemp = new address[](validators.length);
        uint256 count = 0;
        uint256 i;
        for (i = 0; i < validators.length; i++)
            if (confirmations[transactionId][validators[i]]) {
                confirmationsTemp[count] = validators[i];
                count += 1;
            }
        _confirmations = new address[](count);
        for (i = 0; i < count; i++) _confirmations[i] = confirmationsTemp[i];
    }

    /// @dev Returns list of transaction IDs in defined range.
    /// @param from Index start position of transaction array.
    /// @param to Index end position of transaction array (non-inclusive).
    /// @param pending Include pending transactions.
    /// @param executed Include executed transactions.
    /// @return _transactionIds Returns array of transaction IDs.
    function getTransactionIds(
        uint256 from,
        uint256 to,
        bool pending,
        bool executed
    ) public view returns (bytes32[] memory _transactionIds) {
        if (to > transactionIds.length) to = transactionIds.length;
        if (from > to) from = to;
        bytes32[] memory transactionIdsTemp = new bytes32[](to - from);
        uint256 count = 0;
        for (uint256 i = from; i < to; i++) {
            bool txExecuted = transactions[transactionIds[i]].executed;
            if ((!txExecuted && pending) || (txExecuted && executed)) {
                transactionIdsTemp[count] = transactionIds[i];
                count += 1;
            }
        }
        _transactionIds = new bytes32[](count);
        for (uint256 i = 0; i < count; i++)
            _transactionIds[i] = transactionIdsTemp[i];
    }
}
