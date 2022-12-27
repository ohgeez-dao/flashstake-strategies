// SPDX-License-Identifier: BSL-1.1

pragma solidity ^0.8.0;

interface IFarmingLPTokenMigrator {
    /**
     * @dev address of legacy FarmingLPTokenFactory
     */
    function factoryLegacy() external view returns (address);

    /**
     * @dev msg.sender MUST be factoryLegacy.getFarmingLPToken(lpToken)
     */
    function onMigrate(
        address account,
        uint256 pid,
        address lpToken,
        uint256 shares,
        uint256 amountLP,
        address beneficiary
    ) external;
}
