// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import 'Ownable.sol';

// Enables users to become members and assume roles by putting up a bond that
// they risk losing for bad behaviour.

contract Members is Ownable {

  event Hub( address member, bytes location );

  mapping(address => uint256) amounts;
  mapping(address => bytes) locations;

  uint256 public threshold;

  function addToBond() external payable {
    amounts[msg.sender] += msg.value;
  }

  function releaseBond() external {
    uint256 amt = amounts[msg.sender];
    amounts[msg.sender] = 0;
    (bool success,) = payable(msg.sender).call{value: amt}("");
    require( success, "bond release failed" );
  }

  function slash( address addr ) external isOwner returns (uint256 result) {
    result = amounts[addr]; // returns how much we're slashing
    amounts[addr] = 0;
    (bool success,) = _owner.call{value: amounts[addr]}("");
    require( success, "slash failed" );
  }

  function isBonded( address addr ) external view returns (bool) {
    return amounts[addr] >= threshold;
  }

  // must put up triple bond to become an arbitrator
  function isArbitrator( address addr ) external view returns (bool) {
    return amounts[addr] >= threshold * 3;
  }

  // must put up a 10x bond to operate a hub
  function isHub( address addr ) public view returns (bool) {
    return amounts[addr] >= threshold * 10;
  }

  function setLocation( bytes calldata location ) external {
    require( isHub(msg.sender), "set hub bond first" );
    locations[msg.sender] = location;
    emit Hub( msg.sender, location );
  }

  function unsetLocation() external {
    delete locations[msg.sender];
    emit Hub( msg.sender, hex"" );
  }

  constructor( uint256 _threshold ) {
    threshold = _threshold;
  }

  function setThreshold( uint256 newthreshold ) external isOwner {
    threshold = newthreshold;
  }
}
