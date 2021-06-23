// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;

import "hardhat/console.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interface/ICurvePool.sol";
import "./interface/IAaveGauge.sol";
import "./interface/ILendingPool.sol";
import "./interface/IAaveIncentivesController.sol";
import "./interface/IUniswapV2Router02.sol";

contract Strategy is Ownable, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// Aave related contracts
    ILendingPool lendingPool =
        ILendingPool(address(0x8dff5e27ea6b7ac08ebfdf9eb090f32ee9a30fcf));
    IAaveIncentivesController aaveRewards =
        IAaveIncentivesController(0x357D51124f59836DeD84c8a1730D72B749d8BC23);
    IProtocolDataProvider provider =
        IProtocolDataProvider(0x7551b5D2763519d4e37e8B81929D336De671d46d);

    /// Curve.fi related contracts
    ICurvePool public curvePool =
        ICurvePool(address(0x445FE580eF8d70FF569aB36e80c647af338db351));
    IAaveGauge public aaveGauge =
        IAaveGauge(address(0xe381C25de995d62b453aF8B931aAc84fcCaa7A62));
    IERC20 public lpCRV =
        IERC20(address(0xE7a24EF0C5e95Ffb0f6684b813A78F2a3AD7D171));

    int128 public curveId;

    // Sushiswap to recycle rewards
    IUniswapV2Router02 sushiswapRouter =
        IUniswapV2Router02(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);
    address public constant weth =
        address(0x7ceb23fd6bc0add59e62ac25578270cff1b9f619);

    address public delegateFund;
    address public want; // it could DAI, USDC or USDT (which?)
    address public manager;

    /// Tokens involved in the strategy
    address public constant CRV =
        address(0x172370d5Cd63279eFa6d502DAB29171933a610AF);
    address public constant WMATIC =
        address(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);

    uint256 public constant MAX_FEE = 10000;
    uint256 public REVENUE_FEE = 1000;
    uint256 public constant HF_REFERENCE = 1.35 ether;
    uint256 public minSellThreshold = 0.5 ether;
    uint256 public depositLimit;

    event UpdateDepositLimit(uint256 depositLimit, uint256 timestamp);
    event Deposited(uint256 amountDeposited, uint256 timestamp);
    event RepayDebt(uint256 repaidDebt, uint256 existingAaveDebt);
    event Harvest(
        uint256 curveHarvested,
        uint256 wmaticHarvested,
        uint256 curveProtocolFee,
        uint256 wmaticProtocolFee,
        uint256 wantDeposited,
        uint256 indexed blockNumber
    );

    constructor(
        address[3] memory _initialConfig,
        uint256 _limit,
        int128 _curveId
    ) public {
        delegateFund = _initialConfig[0];
        want = _initialConfig[1];
        manager = _initialConfig[2];

        depositLimit = _limit;

        curveId = _curveId;

        IERC20(want).safeApprove(address(lendingPool), type(uint256).max);
    }

    /// --- View Functions ---

    /// @notice Amount of `want` via lp curve relationship
    function lpCurveToWant() public view returns (uint256) {
        uint256 lpRatio = curvePool.get_virtual_price().div(10**18);

        uint256 wantFromLp = lpRatio.mul(balanceInGauge()).div(10**18);

        return wantFromLp;
    }

    /// @notice Amount of lp tokens deposited in Gauge
    function balanceInGauge() public view returns (uint256) {
        return aaveGauge.balanceOf(address(this));
    }

    /// @notice Idle want in strategy
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    /// @notice Provides insight of how many assets are under management expressed in `want`
    function totalAssets() public view returns (uint256) {
        return balanceOfWant().add(0);
    }

    /// --- Functions to pause certain methods (security) ---

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// --- External Actions via `manager` ---

    /// @dev Deposit `want` asset into the strategy
    function deposit(uint256 _amount) external whenNotPaused {
        require(msg.sender == manager, "manager!");
        require(_amount > 0, "nothing!");

        uint256 amount = _amount;

        if (_amount == type(uint256).max) {
            amount = Math.min(
                IERC20(want).balanceOf(msg.sender),
                depositLimit.sub(totalAssets())
            );
        } else {
            require(totalAssets().add(_amount) <= depositLimit, "overLimit!");
        }

        IERC20(want).safeTransferFrom(msg.sender, address(this), amount);

        lendingPool.deposit(want, amount, address(this), 0);

        emit Deposited(amount, block.timestamp);
    }

    /// @dev Withdraw `want` asset from the strategy into the DelegateCreditManager
    function withdraw(address _recipient, uint256 _amount)
        external
        whenNotPaused
    {
        require(msg.sender == manager, "manager!");
        require(_amount > 0, "nothing!");

        uint256 _wantBalanceIdle = IERC20(want).balanceOf(address(this));

        if (_wantBalanceIdle >= _amount) {
            IERC20(want).approve(_recipient, _amount);

            IERC20(want).safeTransferFrom(address(this), _recipient, _amount);
        } else {
            // in this case we will need to withdraw from where the strategy is deploying the assets
        }
    }

    // --- External Actions authorized only to `owner` ---

    /// @dev Harvest accum rewards from Gauge (CRV & WMATIC) and compound positions
    function harvest() external onlyOwner {
        (address aToken, , address variableDebt) = provider
        .getReserveTokensAddresses(want);

        address[] memory claimableAddresses = new address[](2);
        claimableAddresses[0] = aToken;
        claimableAddresses[1] = variableDebt;

        aaveRewards.claimRewards(
            claimableAddresses,
            type(uint256).max,
            address(this)
        );

        aaveGauge.claim_rewards(address(this));

        uint256 curveBal = IERC20(CRV).balanceOf(address(this));
        uint256 wmaticBal = IERC20(WMATIC).balanceOf(address(this));

        (uint256 curveFee, uint256 wmaticFee) = protocolFee(
            curveBal,
            wmaticBal
        );

        curveBal = curveBal.sub(curveFee);
        wmaticBal = wmaticBal.sub(wmaticFee);

        if (wmaticBal > 0 || curveBal > 0) {
            _recycleRewards(address(CRV), curveBal);
            _recycleRewards(address(WMATIC), wmaticBal);
        }

        uint256 wantAmount = IERC20(want).balanceOf(address(this));

        lendingPool.deposit(want, wantAmount, address(this), 0);

        // here we should borrow accordingly to HF and provide lp into Curve again!

        emit Harvest(
            curveBal,
            wmaticBal,
            curveFee,
            wmaticFee,
            wantAmount,
            block.number
        );
    }

    /**
     * @dev Recycle rewards for `want` via Sushiswap
     * @param _rewardAddress Reward address
     * @param _rewardAmount Amount of rewards to be recycled
     **/
    function _recycleRewards(address _rewardAddress, uint256 _rewardAmount)
        internal
    {
        if (_rewardAmount > minSellThreshold) {
            address[] memory path = new address[](3);
            path[0] = _rewardAddress;
            path[1] = weth;
            path[2] = address(want);

            sushiswapRouter.swapExactTokensForTokens(
                _rewardAmount,
                type(uint256).min,
                path,
                address(this),
                now
            );
        }
    }

    /**
     * @dev It will send revenue to our DelegateFund contract accordingly (depending on `REVENUE_FEE`)
     * @param curveHarvested  Total amount which has been harvested in harvest() of curve tokens
     * @param wmaticHarvested Total amount which has been harvested in harvest() of wmatic tokens
     **/
    function protocolFee(uint256 curveHarvested, uint256 wmaticHarvested)
        internal
        returns (uint256 curveFee, uint256 wmaticFee)
    {
        curveFee = curveHarvested.mul(REVENUE_FEE).div(MAX_FEE);

        IERC20(CRV).safeTransfer(delegateFund, curveFee);

        wmaticFee = wmaticHarvested.mul(REVENUE_FEE).div(MAX_FEE);

        IERC20(WMATIC).safeTransfer(delegateFund, wmaticFee);

        return (curveFee, wmaticFee);
    }

    /**
     * @dev Set fee
     * @param _revenueFee Set new revenue fee, max 15%
     **/
    function setRevenueFee(uint256 _revenueFee) external onlyOwner {
        require(_revenueFee <= 1500, "too_high!");
        REVENUE_FEE = _revenueFee;
    }

    /**
     * @dev Set deposit limit
     * @param _limit Set new limit which can be deposited into the strategy
     **/
    function setDepositLimit(uint256 _limit) external onlyOwner {
        depositLimit = _limit;

        emit UpdateDepositLimit(depositLimit, block.timestamp);
    }

    /**
     * @dev Set new selling threshold
     * @param _minSellThreshold new threshold amount
     **/
    function setMinCompToSell(uint256 _minSellThreshold) external onlyOwner {
        minSellThreshold = _minSellThreshold;
    }
}
