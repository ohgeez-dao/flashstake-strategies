// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IFSushiBar.sol";
import "./interfaces/IFSushi.sol";
import "./libraries/WeightedPriorityQueue.sol";
import "./libraries/DateUtils.sol";

/**
 * @notice FSushiBar is an extension of ERC4626 with the addition of vesting period for locks
 */
contract FSushiBar is IFSushiBar {
    using WeightedPriorityQueue for WeightedPriorityQueue.Heap;
    using SafeERC20 for IERC20;
    using Math for uint256;
    using DateUtils for uint256;

    uint8 public constant decimals = 18;
    string public constant name = "Flash SushiBar";
    string public constant symbol = "xfSUSHI";
    uint256 internal constant MINIMUM_WEEKS = 1;
    uint256 internal constant MAXIMUM_WEEKS = 104; // almost 2 years

    address public immutable override asset;
    uint256 public immutable override startWeek;

    mapping(address => uint256) public override balanceOf;
    uint256 public override totalSupply;

    mapping(address => WeightedPriorityQueue.Heap) internal _locks;

    uint256 public override totalAssets;
    /**
     * @dev this is guaranteed to be correct up until the last week
     * @return minimum number of staked total assets during the whole week
     */
    mapping(uint256 => uint256) public override totalAssetsDuring;
    /**
     * @notice totalAssetsDuring is guaranteed to be correct before this week
     */
    uint256 public override lastCheckpoint; // week
    mapping(address => uint256) public override userAssets;
    /**
     * @dev this is guaranteed to be correct up until the last week
     * @return minimum number of staked assets of account during the whole week
     */
    mapping(address => mapping(uint256 => uint256)) public override userAssetsDuring;
    /**
     * @notice userAssetsDuring is guaranteed to be correct before this week (exclusive)
     */
    mapping(address => uint256) public override lastUserCheckpoint; // week

    uint256 internal _totalPower;

    modifier validWeeks(uint256 _weeks) {
        if (_weeks < MINIMUM_WEEKS || _weeks > MAXIMUM_WEEKS) revert InvalidDuration();
        _;
    }

    constructor(address fSushi) {
        asset = fSushi;

        uint256 nextWeek = block.timestamp.toWeekNumber() + 1;
        startWeek = nextWeek;
        lastCheckpoint = nextWeek;
    }

    function maxDeposit() public view override returns (uint256) {
        return (totalAssets > 0 || totalSupply == 0) ? type(uint256).max : 0;
    }

    function previewDeposit(uint256 assets, uint256 _weeks)
        public
        view
        override
        validWeeks(_weeks)
        returns (uint256 shares)
    {
        uint256 power = _toPower(assets, _weeks);
        uint256 supply = totalSupply;
        return (power == 0 || supply == 0) ? power : power.mulDiv(supply, _totalPower, Math.Rounding.Down);
    }

    function maxWithdraw(address owner) public view override returns (uint256 shares, uint256 assets) {
        return previewWithdraw(owner, block.timestamp);
    }

    function previewWithdraw(address owner, uint256 expiry)
        public
        view
        override
        returns (uint256 shares, uint256 assets)
    {
        (, shares) = _locks[owner].enqueued(expiry);
        assets = _toAssets(shares);
    }

    function _toPower(uint256 assets, uint256 _weeks) internal pure returns (uint256) {
        return assets.mulDiv(_weeks, MAXIMUM_WEEKS, Math.Rounding.Up);
    }

    function _toAssets(uint256 shares) internal view virtual returns (uint256 assets) {
        uint256 supply = totalSupply;
        return (supply == 0) ? shares : shares.mulDiv(totalAssets, supply, Math.Rounding.Down);
    }

    function depositSigned(
        uint256 assets,
        uint256 _weeks,
        address beneficiary,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override returns (uint256) {
        IFSushi(asset).permit(msg.sender, address(this), assets, deadline, v, r, s);

        return deposit(assets, _weeks, beneficiary);
    }

    function deposit(
        uint256 assets,
        uint256 _weeks,
        address beneficiary
    ) public override returns (uint256) {
        if (assets > maxDeposit()) revert Bankrupt();

        uint256 shares = previewDeposit(assets, _weeks);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        _mint(beneficiary, shares);

        uint256 power = _toPower(assets, _weeks);
        _locks[msg.sender].enqueue(block.timestamp + _weeks * (1 weeks), power, shares);
        _totalPower += power;

        userCheckpoint(msg.sender);

        uint256 week = block.timestamp.toWeekNumber();
        totalAssets += assets;
        totalAssetsDuring[week] += assets;
        userAssets[msg.sender] += assets;
        userAssetsDuring[msg.sender][week] += assets;

        emit Deposit(msg.sender, beneficiary, shares, assets);

        return shares;
    }

    function withdraw(uint256 expiry, address beneficiary) public override returns (uint256) {
        (uint256 power, uint256 shares) = _locks[msg.sender].drain(expiry);
        if (shares == 0) revert NotExpired();

        uint256 assets = _toAssets(shares);
        _totalPower -= power;

        _burn(msg.sender, shares);
        IERC20(asset).safeTransfer(beneficiary, assets);

        userCheckpoint(msg.sender);

        uint256 week = block.timestamp.toWeekNumber();
        totalAssets -= assets;
        totalAssetsDuring[week] -= assets;
        userAssets[msg.sender] -= assets;
        userAssetsDuring[msg.sender][week] -= assets;

        emit Withdraw(msg.sender, beneficiary, shares, assets);

        return shares;
    }

    function checkpointedTotalAssetsDuring(uint256 week) external override returns (uint256) {
        checkpoint();
        return totalAssetsDuring[week];
    }

    function checkpointedUserAssetsDuring(address account, uint256 week) external override returns (uint256) {
        checkpoint();
        return userAssetsDuring[account][week];
    }

    /**
     * @dev if this function doesn't get called for 512 weeks (around 9.8 years) this contract breaks
     */
    function checkpoint() public override {
        uint256 from = lastCheckpoint;
        uint256 until = block.timestamp.toWeekNumber();
        if (until <= from) return;

        for (uint256 i; i < 512; ) {
            uint256 week = from + i;
            if (until <= week) break;

            totalAssetsDuring[week + 1] = totalAssetsDuring[week];

            unchecked {
                ++i;
            }
        }

        lastCheckpoint = until;
    }

    /**
     * @dev if this function doesn't get called for 512 weeks (around 9.8 years) this contract breaks
     */
    function userCheckpoint(address account) public override {
        checkpoint();

        uint256 from = lastUserCheckpoint[account];
        if (from == 0) {
            from = startWeek;
        }
        uint256 until = block.timestamp.toWeekNumber();
        if (until <= from) return;

        for (uint256 i; i < 512; ) {
            uint256 week = from + i;
            if (until <= week) break;

            userAssetsDuring[account][week + 1] = userAssetsDuring[account][week];

            unchecked {
                ++i;
            }
        }

        lastUserCheckpoint[account] = until;
    }

    function _mint(address account, uint256 amount) internal {
        if (account == address(0)) revert InvalidAccount();

        totalSupply += amount;
        unchecked {
            balanceOf[account] += amount;
        }

        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        if (account == address(0)) revert InvalidAccount();

        uint256 balance = balanceOf[account];
        if (balance < amount) revert NotEnoughBalance();
        unchecked {
            balanceOf[account] = balance - amount;
            totalSupply -= amount;
        }

        emit Transfer(account, address(0), amount);
    }
}
