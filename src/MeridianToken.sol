// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title MeridianToken (MRD)
 * @author Meridian Finance
 * @notice Governance token for Meridian Finance yield aggregator
 * @dev ERC20 with voting capabilities (for future governance) and controlled minting
 *
 * Tokenomics:
 * - Initial supply minted to deployer (for liquidity, team, etc.)
 * - Minters (RewardsDistributor) can mint rewards up to emission schedule
 * - Max supply cap enforced on-chain
 */
contract MeridianToken is ERC20, ERC20Permit, ERC20Votes, Ownable {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum total supply: 100 million MRD
    uint256 public constant MAX_SUPPLY = 100_000_000 * 1e18;

    /// @notice Initial supply minted to deployer: 10 million MRD (10%)
    uint256 public constant INITIAL_SUPPLY = 10_000_000 * 1e18;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Addresses authorized to mint tokens (e.g., RewardsDistributor)
    mapping(address => bool) public minters;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotMinter();
    error ExceedsMaxSupply();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy MRD token and mint initial supply to deployer
     * @param initialOwner Address that will own the contract and receive initial supply
     */
    constructor(address initialOwner)
        ERC20("Meridian Finance", "MRD")
        ERC20Permit("Meridian Finance")
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        _mint(initialOwner, INITIAL_SUPPLY);
    }

    /*//////////////////////////////////////////////////////////////
                            MINTER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add a new minter (e.g., RewardsDistributor contract)
     * @param minter Address to grant minting rights
     */
    function addMinter(address minter) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        minters[minter] = true;
        emit MinterAdded(minter);
    }

    /**
     * @notice Remove a minter
     * @param minter Address to revoke minting rights
     */
    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
        emit MinterRemoved(minter);
    }

    /*//////////////////////////////////////////////////////////////
                               MINTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint new tokens (only callable by approved minters)
     * @param to Recipient of minted tokens
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        if (!minters[msg.sender]) revert NotMinter();
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        _mint(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           REQUIRED OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
