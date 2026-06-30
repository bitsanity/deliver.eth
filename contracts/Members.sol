// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import 'Ownable.sol';

// Enables users to become members and assume roles by putting up a bond that
// they risk losing for bad behaviour.

contract Members is Ownable {

  // Hubs must publish their physical location for mobile members to find
  event Located( address member, bytes location );

  mapping(address => uint256) public bonds;
  mapping(address => bytes) public locations;

  uint256 public threshold;

  function addToBond() external payable {
    bonds[msg.sender] += msg.value;
  }

  function releaseBond() external {
    uint256 amt = bonds[msg.sender];
    bonds[msg.sender] = 0;
    (bool success,) = payable(msg.sender).call{value: amt}("");
    require( success, "bond release failed" );
  }

  function slash( address addr ) external isOwner returns (uint256 result) {
    result = bonds[addr]; // returns how much we're slashing
    bonds[addr] = 0;
    (bool success,) = _owner.call{value: result}("");
    require( success, "slash failed" );
  }

  function isBonded( address addr ) external view returns (bool) {
    return bonds[addr] >= threshold;
  }

  // must put up triple bond to become an arbitrator
  function isArbitrator( address addr ) external view returns (bool) {
    return bonds[addr] >= threshold * 3;
  }

  // must have a location and establish a 10x bond to operate a hub
  function isHub( address addr ) public view returns (bool) {
    return    locations[addr].length > 0
           && bonds[addr] >= threshold * 10;
  }

  function setLocation( bytes calldata location ) external {
    locations[msg.sender] = location;
    emit Located( msg.sender, location );
  }

  function unsetLocation() external {
    delete locations[msg.sender];
    emit Located( msg.sender, hex"" );
  }

  constructor( uint256 _threshold ) {
    threshold = _threshold;
  }

  function setThreshold( uint256 newthreshold ) external isOwner {
    threshold = newthreshold;
  }
}
