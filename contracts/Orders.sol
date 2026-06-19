// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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
    address payable shipper; // defaults to msg.sender placing order

    // values stored encrypted on chain
    bytes origin;
    bytes dest;
    bytes weightkg;

    // not encrypted because sc logic depends on it
    uint256 value;   // declared value of package in wei
    uint256 bounty;  // amount customer has paid for delivery in wei
  }

  Members members; // reference to the Members smart contract

  uint256 counter; // ensure new order ids are always unique

  mapping( bytes32 => Order ) orders;
  mapping( bytes32 => Status ) statuses;
  mapping( bytes32 => address payable[] ) custodians;
  mapping( bytes32 => address payable) arbitrators;

  modifier orderExists( bytes32 orderId ) {
    require( orders[orderId].shipper != payable(address(0)), "unknown order" );
    _;
  }

  function place( Order calldata _order ) external payable {
    require( msg.value > 1000 gwei, "some bounty must be provided" );

    Order memory order = Order({
      shipper: (_order.shipper == payable(address(0)))
               ? payable(address(msg.sender))
               : _order.shipper,

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
  returns (Order memory)
   {
    require (    msg.sender == orders[orderId].shipper
              || members.isBonded(msg.sender),
              "caller must be shipper or member" );
    return orders[orderId];
  }

  function xfer( bytes32 orderId, address oper ) internal {
    if (members.isHub(oper)) {
      statuses[orderId] = Status.HUB;
      emit OrderStatus( orderId, Status.HUB );
    } else {
      require( members.isBonded(oper), "caller must be in network" );
      statuses[orderId] = Status.MOBILE;
      emit OrderStatus( orderId, Status.MOBILE );
    }
    custodians[orderId].push( payable(oper) );
  }

  function pickup( bytes32 orderId ) external orderExists(orderId) {
    require( statuses[orderId] == Status.NEW, "cant pickup" );
    xfer( orderId, msg.sender );
  }

  function handoff( bytes32 orderId ) external orderExists(orderId) {
    require(    statuses[orderId] > Status.NEW
             && statuses[orderId] < Status.DELIVERED, "cant take custody" );

    // prevent hack where member repeatedly takes custody to cheat the bounty
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

    statuses[orderId] = Status.DELIVERED;
    emit OrderStatus( orderId, Status.DELIVERED );
  }

  function askArbitrate( bytes32 orderId ) external orderExists(orderId) {
    require( statuses[orderId] < Status.ARBITRATION, "already arbitrated" );

    require( members.isBonded(msg.sender)
             || msg.sender == orders[orderId].shipper,
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

  function complete( bytes32 orderId ) external orderExists(orderId) {
    require( statuses[orderId] == Status.ARBITRATING, "not in arbitration" );
    require (    members.isArbitrator(msg.sender)
              || msg.sender == _owner,
              "caller must be customer confirming receipt or arbitrator" );
    payout( orderId );
  }

  function payout( bytes32 orderId ) internal {
    uint256 bounty = orders[orderId].bounty;
    orders[orderId].bounty = 0;

    if (custodians[orderId].length != 0) {
      uint256 share = 98 * bounty / 100 / custodians[orderId].length;

      for (uint ii = 0; ii < custodians[orderId].length; ii++) {
        (bool ok,) = custodians[orderId][ii].call{value:share}("");
        if (!ok) {} // defeat warning about unused variable
      }
    }

    statuses[orderId] = Status.COMPLETE;
    emit OrderStatus( orderId, Status.COMPLETE );
  }

  // seize the bond of the latest custodian of the order

  function slash( bytes32 orderId ) external orderExists(orderId) {
    require( custodians[orderId].length > 0, "nobody to slash" );
    require(    msg.sender == arbitrators[orderId]
             || msg.sender == _owner,
             "only the order arbitrator or owner may slash" );

    uint256 bounty = orders[orderId].bounty;
    uint256 orderval = orders[orderId].value;
    address payable shipper = orders[orderId].shipper;
    address payable arbitrator = arbitrators[orderId];
    address payable slashee =
        custodians[orderId][custodians[orderId].length - 1];

    orders[orderId].bounty = 0;
    arbitrators[orderId] = payable(address(0));

    // the Members.slash() internally sends the slashed funds to this contract
    uint256 slashed = members.slash( slashee );

    // arbitrator gets the amount of the bounty
    (bool ok,) = arbitrator.call{value: bounty}("");
    require( ok, "failed to compensate arbitrator" );

    // customer receives value of shipment and cost of shipping
    (ok,) = shipper.call{ value: orderval + bounty }("");
    require( ok, "failed to reimburse customer" );

    // return whatever is left over to slashee
    uint256 required = orderval + 2 * bounty;

    if (slashed > required) {
      uint256 slashamt = slashed - required;
      (ok,) = slashee.call{value: slashamt}("");
      require( ok, "failed to return leftovers to slashee" );
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
    // donations welcome!
  }

  function retrieve( uint256 amt ) external isOwner {
    (bool ok,) = _owner.call{value: amt}("");
    require( ok, "failed to retrieve" );
  }
}
