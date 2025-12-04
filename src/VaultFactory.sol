// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MeridianVault} from "./MeridianVault.sol";

/**
 * @title VaultFactory
 * @author Meridian Finance
 * @notice Factory for deploying Meridian Vaults
 * @dev Uses CREATE2 for deterministic addresses. Each asset gets one vault.
 *
 * Design choices:
 * - One vault per asset (simplifies UX and tracking)
 * - Deterministic addresses (can compute vault address before deployment)
 * - Registry of all deployed vaults
 */
contract VaultFactory is Ownable {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Treasury address for all vaults
    address public treasury;

    /// @notice Mapping: asset => vault
    mapping(address => address) public vaults;

    /// @notice Array of all deployed vault addresses
    address[] public allVaults;

    /// @notice Whether an address is a Meridian vault
    mapping(address => bool) public isVault;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event VaultCreated(address indexed asset, address indexed vault, string name, string symbol);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error VaultAlreadyExists();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy the factory
     * @param _treasury Address to receive performance fees from all vaults
     * @param _owner Factory admin
     */
    constructor(address _treasury, address _owner) Ownable(_owner) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    /*//////////////////////////////////////////////////////////////
                           VAULT DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a new vault for an asset
     * @param asset The underlying asset (e.g., USDC, WETH)
     * @return vault The deployed vault address
     */
    function createVault(address asset) external onlyOwner returns (address vault) {
        if (asset == address(0)) revert ZeroAddress();
        if (vaults[asset] != address(0)) revert VaultAlreadyExists();

        // Generate name and symbol from asset
        string memory assetSymbol = IERC20Metadata(asset).symbol();
        string memory name = string.concat("Meridian ", assetSymbol, " Vault");
        string memory symbol = string.concat("mrd", assetSymbol);

        // Deploy vault
        MeridianVault newVault = new MeridianVault(IERC20(asset), name, symbol, treasury, owner());

        vault = address(newVault);
        vaults[asset] = vault;
        allVaults.push(vault);
        isVault[vault] = true;

        emit VaultCreated(asset, vault, name, symbol);
    }

    /**
     * @notice Deploy a vault with custom name and symbol
     * @param asset The underlying asset
     * @param name Custom vault name
     * @param symbol Custom vault symbol
     * @return vault The deployed vault address
     */
    function createVaultCustom(address asset, string calldata name, string calldata symbol)
        external
        onlyOwner
        returns (address vault)
    {
        if (asset == address(0)) revert ZeroAddress();
        if (vaults[asset] != address(0)) revert VaultAlreadyExists();

        MeridianVault newVault = new MeridianVault(IERC20(asset), name, symbol, treasury, owner());

        vault = address(newVault);
        vaults[asset] = vault;
        allVaults.push(vault);
        isVault[vault] = true;

        emit VaultCreated(asset, vault, name, symbol);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get total number of deployed vaults
     */
    function totalVaults() external view returns (uint256) {
        return allVaults.length;
    }

    /**
     * @notice Get all vault addresses
     */
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }

    /**
     * @notice Get vault for a specific asset
     */
    function getVault(address asset) external view returns (address) {
        return vaults[asset];
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update treasury address
     * @dev Only affects new vaults. Existing vaults keep their treasury.
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }
}
