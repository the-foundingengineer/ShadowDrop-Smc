// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
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

    function testSubmitWorks() public {
        // this test checks that the submit function works as expected
        vm.prank(whistleblower);
        uint256 id = escrow.submit("QmHash", 1 ether);

        assertEq(id, 1);

        (
            string memory ipfsHash,
            uint256 fee,
            bool resolved,
            address assignedJournalist
        ) = escrow.getSubmission(1);

        assertEq(ipfsHash, "QmHash");
        assertEq(fee, 1 ether);
        assertEq(resolved, false);
        assertEq(assignedJournalist, address(0));
    }

    function testMaxSubmissionsReached() public {
        vm.startPrank(whistleblower);
        for (uint256 i = 0; i < 10; i++) {
            escrow.submit("QmHash", 1 ether);
        }

        vm.expectRevert("Submission limit reached");
        escrow.submit("QmHash", 1 ether);

        vm.stopPrank();
    }

    function testTimeoutRefund() public {
        vm.prank(whistleblower);
        escrow.submit("QmHash", 1 ether);

        vm.warp(block.timestamp + 8 days);

        vm.prank(whistleblower);
        escrow.timeoutRefund(1);

        (, , bool resolved, ) = escrow.getSubmission(1);
        assertTrue(resolved);
    }

    function testGrantAccessPaysWhistleblower() public {
        vm.prank(whistleblower);
        escrow.submit("QmHash", 1 ether);

        vm.deal(agent, 2 ether);
        uint256 before = whistleblower.balance;

        vm.prank(agent);
        escrow.grantAccess{value: 1 ether}(1, journalist);

        assertEq(whistleblower.balance, before + 1 ether);
    }

    function testWithdrawPending() public {
        vm.prank(whistleblower);
        escrow.submit("QmHash", 1 ether);

        vm.deal(agent, 1 ether);

        vm.prank(agent);
        escrow.grantAccess{value: 1 ether}(1, journalist);

        vm.prank(whistleblower);
        escrow.withdrawPending();
    }
}
