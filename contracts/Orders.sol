// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import 'Ownable.sol';
import 'Members.sol';

contract Orders is Ownable {

  enum Status {
    NEW,         // customer has made order, paid and placed package for pickup
    MOBILE,      // a mobile operator has taken custody
    HUB,         // a hub has taken custody
    DELIVERED,   // package has been placed at destination
    ARBITRATION, // claim of lost/damaged package, asks any arbitrator to help
    ARBITRATING, // some arbitrator has it
    COMPLETE     // package confirmed received or arbitration complete
  }

  event OrderStatus( bytes32 indexed orderId, Status status );

  struct Order {
    address payable customer; // defaults to msg.sender placing order

    // values stored encrypted on chain
    bytes origin;
    bytes dest;
    bytes weightkg;

    // not encrypted because sc logic depends on it
    uint256 value;   // declared value of package in wei
    uint256 bounty;  // amount customer has paid for delivery in wei
  }

  Members members;

  uint256 counter; // ensure new order ids are always unique

  mapping( bytes32 => Order ) orders;
  mapping( bytes32 => Status ) statuses;
  mapping( bytes32 => address payable[] ) custodians;
  mapping( bytes32 => address payable) arbitrators;
  mapping( address => uint256 ) holdings;

  modifier orderExists( bytes32 orderId ) {
    require( orders[orderId].customer != payable(address(0)), "unknown order" );
    _;
  }

  function place( Order calldata _order ) external payable {
    require( msg.value > 1000 gwei, "some bounty must be provided" );

    Order memory order = Order({
      customer: (_order.customer == payable(address(0)))
               ? payable(address(msg.sender))
               : _order.customer,

      origin: _order.origin,
      dest: _order.dest,
      value: _order.value,
      weightkg: _order.weightkg,
      bounty: msg.value
    });

    bytes32 orderId =
      keccak256( abi.encode(order, msg.sender, block.timestamp, counter++) );

    orders[orderId] = order;
    statuses[orderId] = Status.NEW;
    emit OrderStatus( orderId, Status.NEW );
  }

  function get( bytes32 orderId ) external view orderExists(orderId)
  returns (Order memory) {
    require (    msg.sender == orders[orderId].customer
              || members.isBonded(msg.sender),
              "caller must be customer or member" );
    return orders[orderId];
  }

  function xfer( bytes32 orderId, address oper ) internal {

    require(   holdings[msg.sender]
             + orders[orderId].value
             + orders[orderId].bounty
             < members.bonds(msg.sender), "insufficient bond" );

    if (members.isHub(oper)) {
      statuses[orderId] = Status.HUB;
      emit OrderStatus( orderId, Status.HUB );
    } else {
      require( members.isBonded(oper), "caller must be in network" );
      statuses[orderId] = Status.MOBILE;
      emit OrderStatus( orderId, Status.MOBILE );
    }

    uint len = custodians[orderId].length;
    if (len > 0) {
      address payable lastmbr = custodians[orderId][len - 1];
      holdings[lastmbr] -= orders[orderId].value;
    }

    holdings[oper] += orders[orderId].value;
    custodians[orderId].push( payable(oper) );
  }

  function pickup( bytes32 orderId ) external orderExists(orderId) {
    require( statuses[orderId] == Status.NEW, "cant pickup" );

    xfer( orderId, msg.sender );
  }

  function handoff( bytes32 orderId ) external orderExists(orderId) {
    require(    statuses[orderId] > Status.NEW
             && statuses[orderId] < Status.DELIVERED, "cant take custody" );

    if (custodians[orderId].length > 0) {
      require(
        custodians[orderId][custodians[orderId].length - 1] != msg.sender,
        "cant retake custody" );
    }
    xfer( orderId, msg.sender );
  }

  function deliver( bytes32 orderId ) external orderExists(orderId) {
    require(    statuses[orderId] > Status.NEW
             && statuses[orderId] < Status.DELIVERED, "invalid status" );

    uint len = custodians[orderId].length;
    require( len > 0 && custodians[orderId][len - 1] == msg.sender,
             "only latest custodian can mark as delivered" );

    holdings[msg.sender] -= orders[orderId].value;

    statuses[orderId] = Status.DELIVERED;
    emit OrderStatus( orderId, Status.DELIVERED );
  }

  function complete( bytes32 orderId ) external orderExists(orderId) {
    require( statuses[orderId] == Status.DELIVERED, "must be delivered" );
    require(    msg.sender == _owner
             || msg.sender == orders[orderId].customer,
             "must be customer or owner to complete" );
    payout( orderId );
  }

  function askArbitrate( bytes32 orderId ) external orderExists(orderId) {
    require( statuses[orderId] < Status.ARBITRATION, "already arbitrated" );

    require( members.isBonded(msg.sender)
             || msg.sender == orders[orderId].customer,
             "caller must be customer or bonded member" );

    statuses[orderId] = Status.ARBITRATION;
    emit OrderStatus( orderId, Status.ARBITRATION );
  }

  function arbitrate( bytes32 orderId ) external orderExists(orderId) {
    require( statuses[orderId] == Status.ARBITRATION, "not for arbitration" );

    require(    members.isArbitrator(msg.sender)
             && arbitrators[orderId] == payable(address(0)),
             "caller must be an arbitrator and nobody already arbitrating" );

    statuses[orderId] = Status.ARBITRATING;
    arbitrators[orderId] = payable(address(msg.sender));
    emit OrderStatus( orderId, Status.ARBITRATING );
  }

  function payout( bytes32 orderId ) internal {
    uint256 bounty = orders[orderId].bounty;
    orders[orderId].bounty = 0;

    if (custodians[orderId].length != 0) {
      uint256 share = 99 * bounty / 100 / custodians[orderId].length;

      for (uint ii = 0; ii < custodians[orderId].length; ii++) {
        (bool ok,) = custodians[orderId][ii].call{value:share}("");
        if (!ok) {} // defeat warning about unused variable
      }
    }

    statuses[orderId] = Status.COMPLETE;
    emit OrderStatus( orderId, Status.COMPLETE );
  }

  // seize the bond of the latest custodian of the order and use the funds to
  // make things right

  function slash( bytes32 orderId ) external orderExists(orderId) {
    require( custodians[orderId].length > 0, "nobody to slash" );

    require(    msg.sender == arbitrators[orderId]
             || msg.sender == _owner, "only arbitrator or owner may slash" );

    uint256 bounty = orders[orderId].bounty;
    uint256 orderval = orders[orderId].value;
    address payable customer = orders[orderId].customer;
    address payable arbitrator = arbitrators[orderId];
    orders[orderId].bounty = 0;
    arbitrators[orderId] = payable(address(0));
    address payable slashee =
      custodians[orderId][custodians[orderId].length - 1];

    // Members.slash() sends the slashed funds to its owner, this contract
    uint256 slashed = members.slash( slashee );
    bool ok;

    if (slashed > orderval + bounty) {
      (ok,) = customer.call{ value: orderval + bounty }("");
      slashed = slashed - (orderval + bounty);
    }
    else {
      (ok,) = customer.call{ value: slashed }("");
      slashed = 0;
    }
    require( ok, "failed to reimburse customer" ); // needs offchain action

    // arbitrator gets equivalent to bounty
    if (slashed >= bounty) {
      (ok,) = arbitrator.call{value: bounty}("");
      if (ok) {
        slashed -= bounty;
      }
    }

    // return any left over to slashee
    if (slashed > 0) {
      (ok,) = slashee.call{value: slashed}("");
    }

    statuses[orderId] = Status.COMPLETE;
    emit OrderStatus( orderId, Status.COMPLETE );
  }

  constructor( uint256 threshold ) {
    members = new Members( threshold ); // <== pay bonds there
  }

  function setThreshold( uint256 newthresh ) external isOwner {
    members.setThreshold( newthresh );
  }

  receive() external payable {
    // donations, tips welcome!
  }

  function retrieve( uint256 amt ) external isOwner {
    (bool ok,) = _owner.call{value: amt}("");
    require( ok, "failed to retrieve" );
  }
}
