// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WhistleblowerEscrow} from "../src/WhistleblowerEscrow.sol";

contract WhistleblowerEscrowTest is Test {
    WhistleblowerEscrow escrow;

    address owner = address(0x1);
    address agent = address(0x2);
    address whistleblower = address(0x3);
    address journalist = address(0x4);

    function setUp() public {
        vm.prank(owner);
        escrow = new WhistleblowerEscrow(agent);
    }

    function testFuzzSubmit(string memory ipfsHash, uint256 fee) public {
        vm.assume(bytes(ipfsHash).length > 0);
        vm.assume(fee > 0 && fee < 100 ether);

        vm.prank(whistleblower);
        uint256 id = escrow.submit(ipfsHash, fee);

        (, uint256 storedFee, , ) = escrow.getSubmission(id);
        assertEq(storedFee, fee);
    }
}
