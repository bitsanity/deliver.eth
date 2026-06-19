// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract Ownable {

  address payable public _owner;

  modifier isOwner {
    if (msg.sender != _owner) {
      revert( "owner only" );
    }
    _;
  }

  function chown( address payable newown ) external isOwner {
    _owner = newown;
  }

  constructor() {
    _owner = payable(msg.sender);
  }

}

