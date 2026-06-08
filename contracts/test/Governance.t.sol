// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Governance } from "../src/Governance.sol";

/// @title GovernanceTest
/// @notice Tests for the Governance contract
contract GovernanceTest is Test {
    Governance public governance;

    address public signer1 = makeAddr("signer1");
    address public signer2 = makeAddr("signer2");
    address public signer3 = makeAddr("signer3");
    address public signer4 = makeAddr("signer4");
    address public signer5 = makeAddr("signer5");
    address public attacker = makeAddr("attacker");
    address public recipient = makeAddr("recipient");

    address public targetContract = makeAddr("target");

    function setUp() public {
        address[] memory signers = new address[](5);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;
        signers[3] = signer4;
        signers[4] = signer5;

        governance = new Governance(signers, 3);
    }

    // ───── Constructor Tests ─────

    function test_Constructor_SetsSigersAndThreshold() public {
        assertTrue(governance.getSignerCount() == 5);
        assertTrue(governance.isSigner(signer1));
        assertTrue(governance.isSigner(signer2));
        assertTrue(governance.isSigner(signer3));
        assertTrue(governance.requiredSignatures() == 3);
    }

    function test_Constructor_RevertWhen_EmptySignerList() public {
        address[] memory emptySigners = new address[](0);
        vm.expectRevert(Governance.EmptySignerList.selector);
        new Governance(emptySigners, 1);
    }

    function test_Constructor_RevertWhen_InvalidThreshold() public {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.expectRevert(Governance.InvalidSignatureCount.selector);
        new Governance(signers, 4); // More than number of signers
    }

    function test_Constructor_RevertWhen_ZeroThreshold() public {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.expectRevert(Governance.InvalidSignatureCount.selector);
        new Governance(signers, 0);
    }

    // ───── Proposal Creation Tests ─────

    function test_CreateProposal_SucceedsForSigner() public {
        vm.startPrank(signer1);

        bytes memory callData = abi.encodeWithSignature("test()");
        uint256 proposalId = governance.createProposal(
            "Test Proposal",
            "A test proposal",
            targetContract,
            callData,
            0
        );

        assertTrue(proposalId == 0);
        Governance.Proposal memory proposal = governance.getProposal(proposalId);
        assertTrue(keccak256(bytes(proposal.title)) == keccak256(bytes("Test Proposal")));
        assertTrue(proposal.target == targetContract);
        assertTrue(uint8(proposal.status) == uint8(Governance.ProposalStatus.Pending));

        vm.stopPrank();
    }

    function test_CreateProposal_RevertWhen_NotSigner() public {
        vm.startPrank(attacker);

        bytes memory callData = abi.encodeWithSignature("test()");
        vm.expectRevert(Governance.UnauthorizedSigner.selector);
        governance.createProposal(
            "Test Proposal",
            "A test proposal",
            targetContract,
            callData,
            0
        );

        vm.stopPrank();
    }

    function test_CreateProposal_RevertWhen_ZeroTarget() public {
        vm.startPrank(signer1);

        bytes memory callData = abi.encodeWithSignature("test()");
        vm.expectRevert(Governance.InvalidAddress.selector);
        governance.createProposal(
            "Test Proposal",
            "A test proposal",
            address(0),
            callData,
            0
        );

        vm.stopPrank();
    }

    // ───── Voting Tests ─────

    function test_Vote_SucceedsForSigner() public {
        _createTestProposal();

        vm.startPrank(signer1);
        governance.vote(0);
        assertTrue(governance.getVoteCount(0) == 1);
        assertTrue(governance.hasVoted(0, signer1));
        vm.stopPrank();
    }

    function test_Vote_UpdatesProposalStatus() public {
        _createTestProposal();

        vm.prank(signer1);
        governance.vote(0);

        Governance.Proposal memory proposal = governance.getProposal(0);
        assertTrue(uint8(proposal.status) == uint8(Governance.ProposalStatus.Active));
    }

    function test_Vote_ApprovesWhenThresholdReached() public {
        _createTestProposal();

        vm.prank(signer1);
        governance.vote(0);

        vm.prank(signer2);
        governance.vote(0);

        vm.prank(signer3);
        governance.vote(0);

        Governance.Proposal memory proposal = governance.getProposal(0);
        assertTrue(uint8(proposal.status) == uint8(Governance.ProposalStatus.Approved));
    }

    function test_Vote_RevertWhen_DuplicateVote() public {
        _createTestProposal();

        vm.startPrank(signer1);
        governance.vote(0);

        vm.expectRevert(Governance.ProposalAlreadyVoted.selector);
        governance.vote(0);

        vm.stopPrank();
    }

    function test_Vote_RevertWhen_NotSigner() public {
        _createTestProposal();

        vm.startPrank(attacker);
        vm.expectRevert(Governance.UnauthorizedSigner.selector);
        governance.vote(0);
        vm.stopPrank();
    }

    function test_Vote_RevertWhen_ProposalExpired() public {
        _createTestProposal();

        // Fast forward past expiry (14 days)
        vm.warp(block.timestamp + 15 days);

        vm.startPrank(signer1);
        vm.expectRevert(Governance.ProposalExpired.selector);
        governance.vote(0);
        vm.stopPrank();
    }

    // ───── Proposal Execution Tests ─────

    function test_ExecuteProposal_SucceedsWhenApproved() public {
        _createAndApproveProposal();

        // Fast forward past time-lock (2 days)
        vm.warp(block.timestamp + 3 days);

        uint256 beforeBalance = address(recipient).balance;

        vm.prank(signer1);
        governance.executeProposal(0);

        Governance.Proposal memory proposal = governance.getProposal(0);
        assertTrue(uint8(proposal.status) == uint8(Governance.ProposalStatus.Executed));
    }

    function test_ExecuteProposal_RevertWhen_TimeLocked() public {
        _createAndApproveProposal();

        // Try to execute before time-lock expires
        vm.startPrank(signer1);
        vm.expectRevert(Governance.ProposalTimeLocked.selector);
        governance.executeProposal(0);
        vm.stopPrank();
    }

    function test_ExecuteProposal_RevertWhen_NotApproved() public {
        _createTestProposal();

        vm.warp(block.timestamp + 3 days);

        vm.startPrank(signer1);
        vm.expectRevert(Governance.ProposalNotApproved.selector);
        governance.executeProposal(0);
        vm.stopPrank();
    }

    // ───── Cancel Proposal Tests ─────

    function test_CancelProposal_SucceedsForSigner() public {
        _createTestProposal();

        vm.prank(signer1);
        governance.cancelProposal(0);

        Governance.Proposal memory proposal = governance.getProposal(0);
        assertTrue(uint8(proposal.status) == uint8(Governance.ProposalStatus.Cancelled));
    }

    function test_CancelProposal_RevertWhen_NotSigner() public {
        _createTestProposal();

        vm.startPrank(attacker);
        vm.expectRevert(Governance.UnauthorizedSigner.selector);
        governance.cancelProposal(0);
        vm.stopPrank();
    }

    function test_CancelProposal_RevertWhen_AlreadyExecuted() public {
        _createAndApproveProposal();
        vm.warp(block.timestamp + 3 days);

        vm.prank(signer1);
        governance.executeProposal(0);

        vm.startPrank(signer2);
        vm.expectRevert(Governance.ProposalNotActive.selector);
        governance.cancelProposal(0);
        vm.stopPrank();
    }

    // ───── Signer Management Tests ─────

    function test_AddSigner_SucceedsForSigner() public {
        vm.prank(signer1);
        governance.addSigner(attacker);

        assertTrue(governance.isSigner(attacker));
        assertTrue(governance.getSignerCount() == 6);
    }

    function test_AddSigner_RevertWhen_NotSigner() public {
        vm.startPrank(attacker);
        vm.expectRevert(Governance.UnauthorizedSigner.selector);
        governance.addSigner(recipient);
        vm.stopPrank();
    }

    function test_AddSigner_RevertWhen_ZeroAddress() public {
        vm.startPrank(signer1);
        vm.expectRevert(Governance.InvalidAddress.selector);
        governance.addSigner(address(0));
        vm.stopPrank();
    }

    function test_AddSigner_RevertWhen_DuplicateSigner() public {
        vm.startPrank(signer1);
        vm.expectRevert(Governance.DuplicateSigner.selector);
        governance.addSigner(signer2);
        vm.stopPrank();
    }

    function test_RemoveSigner_SucceedsForSigner() public {
        vm.prank(signer1);
        governance.removeSigner(signer5);

        assertFalse(governance.isSigner(signer5));
        assertTrue(governance.getSignerCount() == 4);
    }

    function test_RemoveSigner_RevertWhen_LastSigner() public {
        // Remove all but one signer
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(signer1);
            if (i == 0) governance.removeSigner(signer2);
            else if (i == 1) governance.removeSigner(signer3);
            else if (i == 2) governance.removeSigner(signer4);
            else governance.removeSigner(signer5);
        }

        vm.startPrank(signer1);
        vm.expectRevert(Governance.InsufficientSigners.selector);
        governance.removeSigner(signer1);
        vm.stopPrank();
    }

    // ───── Signature Threshold Tests ─────

    function test_SetRequiredSignatures_SucceedsForSigner() public {
        vm.prank(signer1);
        governance.setRequiredSignatures(4);

        assertTrue(governance.requiredSignatures() == 4);
    }

    function test_SetRequiredSignatures_RevertWhen_Invalid() public {
        vm.startPrank(signer1);

        vm.expectRevert(Governance.InvalidSignatureCount.selector);
        governance.setRequiredSignatures(0);

        vm.expectRevert(Governance.InvalidSignatureCount.selector);
        governance.setRequiredSignatures(6); // More than total signers

        vm.stopPrank();
    }

    // ───── ETH Handling Tests ─────

    function test_ReceiveETH() public {
        uint256 amount = 1 ether;
        (bool success, ) = address(governance).call{value: amount}("");
        assertTrue(success);
        assertTrue(address(governance).balance == amount);
    }

    function test_WithdrawETH_SucceedsForSigner() public {
        uint256 amount = 1 ether;
        (bool success, ) = address(governance).call{value: amount}("");
        assertTrue(success);

        vm.prank(signer1);
        governance.withdrawETH(payable(recipient));

        assertTrue(address(governance).balance == 0);
        assertTrue(address(recipient).balance == amount);
    }

    function test_WithdrawETH_RevertWhen_NotSigner() public {
        vm.startPrank(attacker);
        vm.expectRevert(Governance.UnauthorizedSigner.selector);
        governance.withdrawETH(payable(recipient));
        vm.stopPrank();
    }

    // ───── Helper Functions ─────

    function _createTestProposal() private {
        vm.prank(signer1);
        governance.createProposal(
            "Test Proposal",
            "A test proposal",
            targetContract,
            abi.encodeWithSignature("test()"),
            0
        );
    }

    function _createAndApproveProposal() private {
        _createTestProposal();

        vm.prank(signer1);
        governance.vote(0);

        vm.prank(signer2);
        governance.vote(0);

        vm.prank(signer3);
        governance.vote(0);
    }
}
