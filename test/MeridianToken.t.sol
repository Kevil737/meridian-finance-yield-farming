// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MeridianTokenTest is Test {
    MeridianToken public token;

    address public owner = address(1);
    address public minter = address(2);
    address public user1 = address(3);
    address public user2 = address(4);

    function setUp() public {
        vm.prank(owner);
        token = new MeridianToken(owner);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InitialState() public view {
        assertEq(token.name(), "Meridian Finance");
        assertEq(token.symbol(), "MRD");
        assertEq(token.decimals(), 18);
        assertEq(token.owner(), owner);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
        assertEq(token.balanceOf(owner), token.INITIAL_SUPPLY());
    }

    function test_Constants() public view {
        assertEq(token.MAX_SUPPLY(), 100_000_000 * 1e18);
        assertEq(token.INITIAL_SUPPLY(), 10_000_000 * 1e18);
    }

    function test_RevertIf_DeployWithZeroAddress() public {
        // Now using the imported error name, which is more reliable than the raw selector.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MeridianToken(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          MINTER MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddMinter() public {
        vm.prank(owner);
        token.addMinter(minter);

        assertTrue(token.minters(minter));
    }

    function test_AddMinter_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit MeridianToken.MinterAdded(minter);
        token.addMinter(minter);
    }

    function test_RevertIf_AddMinter_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        token.addMinter(minter);
    }

    function test_RevertIf_AddMinter_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MeridianToken.ZeroAddress.selector);
        token.addMinter(address(0));
    }

    function test_RemoveMinter() public {
        vm.startPrank(owner);
        token.addMinter(minter);
        assertTrue(token.minters(minter));

        token.removeMinter(minter);
        assertFalse(token.minters(minter));
        vm.stopPrank();
    }

    function test_RemoveMinter_EmitsEvent() public {
        vm.startPrank(owner);
        token.addMinter(minter);

        vm.expectEmit(true, false, false, false);
        emit MeridianToken.MinterRemoved(minter);
        token.removeMinter(minter);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             MINTING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint() public {
        vm.prank(owner);
        token.addMinter(minter);

        uint256 mintAmount = 1000 * 1e18;
        vm.prank(minter);
        token.mint(user1, mintAmount);

        assertEq(token.balanceOf(user1), mintAmount);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY() + mintAmount);
    }

    function test_RevertIf_Mint_NotMinter() public {
        vm.prank(user1);
        vm.expectRevert(MeridianToken.NotMinter.selector);
        token.mint(user2, 1000 * 1e18);
    }

    function test_RevertIf_Mint_ExceedsMaxSupply() public {
        vm.prank(owner);
        token.addMinter(minter);

        // Try to mint more than remaining supply
        uint256 remaining = token.MAX_SUPPLY() - token.totalSupply();

        vm.prank(minter);
        vm.expectRevert(MeridianToken.ExceedsMaxSupply.selector);
        token.mint(user1, remaining + 1);
    }

    function test_Mint_UpToMaxSupply() public {
        vm.prank(owner);
        token.addMinter(minter);

        uint256 remaining = token.MAX_SUPPLY() - token.totalSupply();

        vm.prank(minter);
        token.mint(user1, remaining);

        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    /*//////////////////////////////////////////////////////////////
                           TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(owner);
        token.transfer(user1, amount);

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.balanceOf(owner), token.INITIAL_SUPPLY() - amount);
    }

    function test_TransferFrom() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(owner);
        token.approve(user1, amount);

        vm.prank(user1);
        token.transferFrom(owner, user2, amount);

        assertEq(token.balanceOf(user2), amount);
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Mint(uint256 amount) public {
        uint256 remaining = token.MAX_SUPPLY() - token.totalSupply();
        amount = bound(amount, 0, remaining);

        vm.prank(owner);
        token.addMinter(minter);

        vm.prank(minter);
        token.mint(user1, amount);

        assertEq(token.balanceOf(user1), amount);
    }

    function testFuzz_Transfer(uint256 amount) public {
        amount = bound(amount, 0, token.INITIAL_SUPPLY());

        vm.prank(owner);
        token.transfer(user1, amount);

        assertEq(token.balanceOf(user1), amount);
    }
}
