pragma solidity ^0.4.12;

import "./SafeMath.sol";

contract CryptoLegacy {

  event KeysNeeded();

  enum States {
    CallForKeepers,
    Active,
    CallForKeys,
    Cancelled
  }

  modifier atState(States _state) {
    require(state == _state);
    _;
  }

  modifier ownerOnly() {
    require(msg.sender == owner);
    _;
  }

  modifier activeKeepersOnly() {
    require(activeKeepers[msg.sender].lastCheckInAt > 0);
    _;
  }

  struct KeeperProposal {
    address keeperAddress;
    bytes publicKey; // 64-byte
  }

  struct ActiveKeeper {
    bytes publicKey; // 64-byte
    bytes32 keyPartHash; // sha-3 hash
    uint lastCheckInAt;
    uint balance;
    bool keyPartSupplied;
  }

  struct EncryptedData {
    bytes encryptedData;
    bytes32 dataHash; // sha-3 hash
    bytes encryptedKeyParts; // packed array of key parts
    bytes[] suppliedKeyParts;
  }

  address public owner = msg.sender;

  uint public checkInInterval;
  uint public keepingFee;
  uint public finalReward;

  // We can rely on the value of now (block.timestamp) for our purposes, as the consensus
  // rule is that a block's timestamp must be 1) more than the parent's block timestamp;
  // and 2) less than the current wall clock time. See:
  // https://github.com/ethereum/go-ethereum/blob/885c13c/consensus/ethash/consensus.go#L223
  uint public lastOwnerCheckInAt = now;

  States public state = States.CallForKeepers;

  EncryptedData public encryptedData;

  KeeperProposal[] public keeperProposals;
  mapping(address => bool) public proposedKeeperFlags;

  mapping(address => ActiveKeeper) public activeKeepers;
  address[] public activeKeepersAddresses; // TODO: make internal

  // How much in total we need to pay to active Keepers when they all supply their keys.
  uint internal totalFinalReward;

  // We need this because current version of Solidity doesn't support non-integer numbers.
  // We set it to be equal to number of wei in eth to make sure we transfer keeping fee with
  // enough precision.
  uint internal constant KEEPING_FEE_PRECISION = 1 ether;


  // Called by the person who possesses the data they wish to transfer.
  // This person becomes the owner of the contract.
  //
  function CryptoLegacy(uint _checkInInterval, uint _keepingFee, uint _finalReward) public {
    checkInInterval = _checkInInterval;
    keepingFee = _keepingFee;
    finalReward = _finalReward;
  }


  // Called by a Keeper to submit their proposal.
  //
  function submitKeeperProposal(bytes publicKey) external
    atState(States.CallForKeepers)
  {
    require(msg.sender != owner);
    require(!proposedKeeperFlags[msg.sender]);

    keeperProposals.push(KeeperProposal({
      keeperAddress: msg.sender,
      publicKey: publicKey
    }));

    proposedKeeperFlags[msg.sender] = true;
  }


  // Called by owner to accept selected proposals and activate the contract.
  //
  function acceptKeepers(
    uint[] selectedProposalIndices,
    bytes32[] keyPartHashes,
    bytes encryptedKeyParts,
    bytes _encryptedData,
    bytes32 dataHash
  ) payable external
    ownerOnly()
    atState(States.CallForKeepers)
  {
    uint _totalFinalReward = 0;

    encryptedData = EncryptedData({
      encryptedData: _encryptedData,
      dataHash: dataHash,
      encryptedKeyParts: encryptedKeyParts,
      suppliedKeyParts: new bytes[](0)
    });

    for (uint i = 0; i < selectedProposalIndices.length; i++) {
      uint proposalIndex = selectedProposalIndices[i];
      KeeperProposal storage proposal = keeperProposals[proposalIndex];

      activeKeepers[proposal.keeperAddress] = ActiveKeeper({
        publicKey: proposal.publicKey,
        keyPartHash: keyPartHashes[i],
        lastCheckInAt: now,
        balance: 0,
        keyPartSupplied: false
      });

      activeKeepersAddresses.push(proposal.keeperAddress);

      uint keeperFinalReward = finalReward;
      _totalFinalReward = SafeMath.add(_totalFinalReward, keeperFinalReward);
    }

    require(this.balance >= _totalFinalReward);

    state = States.Active;
    totalFinalReward = _totalFinalReward;
    lastOwnerCheckInAt = now;
  }


  // Updates owner check-in time and credits all active Keepers with keeping fee.
  //
  function ownerCheckIn() payable external
    ownerOnly()
    atState(States.Active)
  {
    uint timeSinceLastOwnerCheckIn = SafeMath.sub(now, lastOwnerCheckInAt);
    require(timeSinceLastOwnerCheckIn <= checkInInterval);

    uint keepingFeeMult = SafeMath.mul(KEEPING_FEE_PRECISION, timeSinceLastOwnerCheckIn) / checkInInterval;
    uint keepersBalance = 0;

    for (uint i = 0; i < activeKeepersAddresses.length; i++) {
      ActiveKeeper keeper = activeKeepers[activeKeepersAddresses[i]];
      uint balanceToAdd = SafeMath.mul(keepingFee, keepingFeeMult) / KEEPING_FEE_PRECISION;
      keeper.balance = SafeMath.add(keeper.balance, balanceToAdd);
      keepersBalance = SafeMath.add(keepersBalance, keeper.balance);
    }

    require(this.balance >= SafeMath.add(keepersBalance, totalFinalReward));

    lastOwnerCheckInAt = now;
  }


  function keeperCheckIn() external
    activeKeepersOnly()
    atState(States.Active)
  {
    uint timeSinceLastOwnerCheckIn = SafeMath.sub(now, lastOwnerCheckInAt);
    if (timeSinceLastOwnerCheckIn > checkInInterval) {
      ownerFailedToCheckInInTime();
      return;
    }

    ActiveKeeper keeper = activeKeepers[msg.sender];
    if (keeper.balance > 0) {
      msg.sender.transfer(keeper.balance);
      keeper.balance = 0;
    }

    keeper.lastCheckInAt = now;
  }


  function ownerFailedToCheckInInTime() internal {
    state = States.CallForKeys;
    KeysNeeded();
  }


  function supplyKey(bytes keyPart) external
    activeKeepersOnly()
    atState(States.CallForKeys)
  {
    ActiveKeeper keeper = activeKeepers[msg.sender];
    require(!keeper.keyPartSupplied);

    bytes32 suppliedKeyPartHash = keccak256(keyPart);
    require(suppliedKeyPartHash == keeper.keyPartHash);

    encryptedData.suppliedKeyParts.push(keyPart);

    uint keeperFinalReward = finalReward;
    msg.sender.transfer(keeper.balance + keeperFinalReward);

    keeper.balance = 0;
    keeper.keyPartSupplied = true;
  }


  // TODO: how a Keeper can get their remaining balance when a contract is cancelled?
  //
  function cancel() external
    ownerOnly()
    atState(States.Active)
  {
    uint totalKeepersBalance = 0;

    for (uint i = 0; i < activeKeepersAddresses.length; i++) {
      ActiveKeeper keeper = activeKeepers[activeKeepersAddresses[i]];
      totalKeepersBalance = SafeMath.add(totalKeepersBalance, keeper.balance);
    }

    if (this.balance > totalKeepersBalance) {
      msg.sender.transfer(this.balance - totalKeepersBalance);
    }

    state = States.Cancelled;
  }

}
