// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract VaultFactoryTest is Test {
    VaultFactory public factory;
    MockERC20 public usdc;
    MockERC20 public weth;

    address public owner = address(1);
    address public treasury = address(2);
    address public user1 = address(3);

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy factory
        vm.prank(owner);
        factory = new VaultFactory(treasury, owner);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InitialState() public view {
        assertEq(factory.owner(), owner);
        assertEq(factory.treasury(), treasury);
        assertEq(factory.totalVaults(), 0);
    }

    function test_RevertIf_DeployWithZeroTreasury() public {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        new VaultFactory(address(0), owner);
    }

    /*//////////////////////////////////////////////////////////////
                          VAULT CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateVault() public {
        vm.prank(owner);
        address vaultAddr = factory.createVault(address(usdc));

        assertTrue(vaultAddr != address(0));
        assertEq(factory.vaults(address(usdc)), vaultAddr);
        assertTrue(factory.isVault(vaultAddr));
        assertEq(factory.totalVaults(), 1);

        // Check vault properties
        MeridianVault vault = MeridianVault(vaultAddr);
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.name(), "Meridian USDC Vault");
        assertEq(vault.symbol(), "mrdUSDC");
        assertEq(vault.treasury(), treasury);
        assertEq(vault.owner(), owner);
    }

    function test_CreateVault_EmitsEvent() public {
        // 1. Predict the address of the contract that will be deployed.
        // The new contract address is deterministic based on the factory's address and its nonce.
        // vm.computeCreateAddress(address) calculates the next address deployed by that address.
        address expectedVaultAddress = vm.computeCreateAddress(address(factory), 1);

        vm.prank(owner);

        // 2. Assert the event is emitted with the predicted address.
        // The failing parameter was 'vault' (the second parameter in VaultCreated).
        vm.expectEmit(true, true, false, true);
        emit VaultFactory.VaultCreated(
            address(usdc),
            expectedVaultAddress, // FIX: Use the computed address instead of address(0)
            "Meridian USDC Vault",
            "mrdUSDC"
        );

        // 3. Execute the function call that emits the event.
        factory.createVault(address(usdc));

        // Optional: Assert the factory recorded the vault correctly
        assertEq(factory.vaults(address(usdc)), expectedVaultAddress);
    }

    function test_CreateMultipleVaults() public {
        vm.startPrank(owner);
        address usdcVault = factory.createVault(address(usdc));
        address wethVault = factory.createVault(address(weth));
        vm.stopPrank();

        assertEq(factory.totalVaults(), 2);
        assertEq(factory.vaults(address(usdc)), usdcVault);
        assertEq(factory.vaults(address(weth)), wethVault);

        address[] memory allVaults = factory.getAllVaults();
        assertEq(allVaults.length, 2);
        assertEq(allVaults[0], usdcVault);
        assertEq(allVaults[1], wethVault);
    }

    function test_CreateVaultCustom() public {
        vm.prank(owner);
        address vaultAddr = factory.createVaultCustom(address(usdc), "My Custom Vault", "CUSTOM");

        MeridianVault vault = MeridianVault(vaultAddr);
        assertEq(vault.name(), "My Custom Vault");
        assertEq(vault.symbol(), "CUSTOM");
    }

    function test_RevertIf_CreateVault_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.createVault(address(usdc));
    }

    function test_RevertIf_CreateVault_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.createVault(address(0));
    }

    function test_RevertIf_CreateVault_AlreadyExists() public {
        vm.startPrank(owner);
        factory.createVault(address(usdc));

        vm.expectRevert(VaultFactory.VaultAlreadyExists.selector);
        factory.createVault(address(usdc));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetVault() public {
        vm.prank(owner);
        address vaultAddr = factory.createVault(address(usdc));

        assertEq(factory.getVault(address(usdc)), vaultAddr);
        assertEq(factory.getVault(address(weth)), address(0)); // Not created
    }

    function test_GetAllVaults() public {
        vm.startPrank(owner);
        address vault1 = factory.createVault(address(usdc));
        address vault2 = factory.createVault(address(weth));
        vm.stopPrank();

        address[] memory vaults = factory.getAllVaults();
        assertEq(vaults.length, 2);
        assertEq(vaults[0], vault1);
        assertEq(vaults[1], vault2);
    }

    function test_IsVault() public {
        vm.prank(owner);
        address vaultAddr = factory.createVault(address(usdc));

        assertTrue(factory.isVault(vaultAddr));
        assertFalse(factory.isVault(address(usdc)));
        assertFalse(factory.isVault(user1));
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetTreasury() public {
        address newTreasury = address(99);

        vm.prank(owner);
        factory.setTreasury(newTreasury);

        assertEq(factory.treasury(), newTreasury);
    }

    function test_SetTreasury_EmitsEvent() public {
        address newTreasury = address(99);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit VaultFactory.TreasuryUpdated(treasury, newTreasury);
        factory.setTreasury(newTreasury);
    }

    function test_RevertIf_SetTreasury_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.setTreasury(address(99));
    }

    function test_RevertIf_SetTreasury_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setTreasury(address(0));
    }

    function test_NewVaults_UseUpdatedTreasury() public {
        address newTreasury = address(99);

        vm.startPrank(owner);
        factory.setTreasury(newTreasury);
        address vaultAddr = factory.createVault(address(usdc));
        vm.stopPrank();

        MeridianVault vault = MeridianVault(vaultAddr);
        assertEq(vault.treasury(), newTreasury);
    }
}
