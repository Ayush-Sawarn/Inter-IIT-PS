// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  FullCollateralFutures_stepwise.sol
  ---------------------------------
  This file contains two incremental versions of a full-collateral futures contract
  (designed for Remix + MetaMask on Sepolia). The idea is step-by-step development:

  STEP 1 - SimpleFullCollateralV1
    - Minimal full-collateral implementation.
    - A trader opens a position by sending ETH (msg.value) to openPosition().
    - The contract simply returns the same ETH when the trader calls closePosition().
    - No price feed, no PnL, only lock-and-return behavior. Good for testing deposit/withdraw flow.

  STEP 2 - FullCollateralWithOracleV2
    - Adds Chainlink price feed (AggregatorV3Interface) integration.
    - Records an entry price on openPosition and computes PnL on closePosition/settleExpired.
    - Payouts (profit or remaining margin) are derived from margin and price movement.
    - A simple liquidation function is included (maintenance margin check).

  NOTE: Both contracts are educational/demo-level. Do NOT deploy to mainnet without review/audit.
*/

// -------------------------
// STEP 1: Minimal version
// -------------------------
contract SimpleFullCollateralV1 {
    event PositionOpened(uint256 indexed id, address indexed trader, uint256 margin, bool isLong, uint256 expiry);
    event PositionClosed(uint256 indexed id, address indexed trader, uint256 returnedAmount);

    struct Position {
        address trader;
        uint256 margin;    // ETH locked
        bool isLong;
        uint256 expiry;
        bool isOpen;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId;
    uint256 public constant DURATION = 24 hours;

    // openPosition: send ETH as full-collateral (no PnL logic yet)
    function openPosition(bool isLong) external payable returns (uint256) {
        require(msg.value > 0, "send ETH as margin");
        uint256 id = nextPositionId++;
        positions[id] = Position({
            trader: msg.sender,
            margin: msg.value,
            isLong: isLong,
            expiry: block.timestamp + DURATION,
            isOpen: true
        });
        emit PositionOpened(id, msg.sender, msg.value, isLong, positions[id].expiry);
        return id;
    }

    // closePosition: simple return of the locked ETH to the position owner
    function closePosition(uint256 id) external {
        Position storage pos = positions[id];
        require(pos.isOpen, "position closed or invalid");
        require(pos.trader == msg.sender, "not your position");

        uint256 amount = pos.margin;
        pos.isOpen = false;
        pos.margin = 0;

        _safeTransfer(payable(msg.sender), amount);
        emit PositionClosed(id, msg.sender, amount);
    }

    // view helper
    function getPosition(uint256 id) external view returns (Position memory) {
        return positions[id];
    }

    // internal safe transfer helper
    function _safeTransfer(address payable to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount, gas: 23000}("");
        require(ok, "transfer failed");
    }

    // accept ETH directly
    receive() external payable {}
}

// -------------------------
// STEP 2: Oracle + PnL
// -------------------------
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract FullCollateralWithOracleV2 {
    // Events
    event PositionOpened(uint256 indexed id, address indexed trader, uint256 margin, bool isLong, uint256 entryPrice, uint256 expiry);
    event PositionClosed(uint256 indexed id, address indexed trader, uint256 returnedAmount, int256 pnl);
    event PositionLiquidated(uint256 indexed id, address indexed liquidator, address indexed trader, uint256 returnedAmount, int256 pnl);
    event Funded(address indexed sender, uint256 amount);

    // Position struct stores entryPrice (scaled to 1e18) for later PnL calculation
    struct Position {
        address trader;
        uint256 margin;      // ETH locked in wei
        uint256 entryPrice;  // price scaled to 1e18 (0 if not set)
        uint256 expiry;
        bool isLong;
        bool isOpen;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId;
    AggregatorV3Interface public priceFeed;
    uint256 public constant DURATION = 24 hours;

    // maintenance margin in basis points (500 == 5%)
    uint256 public maintenanceMarginBps = 500;

    address public owner;

    constructor(address _priceFeed) {
        require(_priceFeed != address(0), "invalid feed");
        priceFeed = AggregatorV3Interface(_priceFeed);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    // Fund the contract to ensure there is liquidity to pay winners in tests
    function fund() external payable {
        require(msg.value > 0, "send ETH");
        emit Funded(msg.sender, msg.value);
    }

    // Owner withdraw (test cleanup)
    function ownerWithdraw(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "insufficient balance");
        _safeTransfer(payable(owner), amount);
    }

    // openPosition: stores margin and also records entry price from oracle
    function openPosition(bool isLong) external payable returns (uint256) {
        require(msg.value > 0, "send ETH as margin");
        uint256 id = nextPositionId++;
        uint256 entry = _getLatestPriceScaled(); // scaled to 1e18

        positions[id] = Position({
            trader: msg.sender,
            margin: msg.value,
            entryPrice: entry,
            expiry: block.timestamp + DURATION,
            isLong: isLong,
            isOpen: true
        });

        emit PositionOpened(id, msg.sender, msg.value, isLong, entry, positions[id].expiry);
        return id;
    }

    // closePosition: computes PnL using oracle and pays trader accordingly
    function closePosition(uint256 id) external {
        Position storage pos = positions[id];
        require(pos.isOpen, "position closed or invalid");
        require(pos.trader == msg.sender, "not your position");

        uint256 current = _getLatestPriceScaled();
        (int256 pnlSigned, uint256 payout) = _computePnLAndPayout(pos, current);

        pos.isOpen = false;
        pos.margin = 0;

        if (payout > 0) {
            _safeTransfer(payable(pos.trader), payout);
        }

        emit PositionClosed(id, pos.trader, payout, pnlSigned);
    }

    // settleExpired: anyone can call after expiry to enforce settlement
    function settleExpired(uint256 id) external {
        Position storage pos = positions[id];
        require(pos.isOpen, "position closed or invalid");
        require(block.timestamp >= pos.expiry, "not yet expired");

        uint256 current = _getLatestPriceScaled();
        (int256 pnlSigned, uint256 payout) = _computePnLAndPayout(pos, current);

        pos.isOpen = false;
        pos.margin = 0;

        if (payout > 0) {
            _safeTransfer(payable(pos.trader), payout);
        }

        emit PositionClosed(id, pos.trader, payout, pnlSigned);
    }

    // simple liquidation: if remaining payout < maintenance threshold then liquidate
    function liquidate(uint256 id) external {
        Position storage pos = positions[id];
        require(pos.isOpen, "position closed or invalid");

        uint256 current = _getLatestPriceScaled();
        (int256 pnlSigned, uint256 payout) = _computePnLAndPayout(pos, current);

        uint256 maintenance = (pos.margin * maintenanceMarginBps) / 10000;
        require(payout < maintenance, "not eligible for liquidation");

        pos.isOpen = false;
        pos.margin = 0;

        // reward liquidator 1% of payout (if any)
        if (payout > 0) {
            uint256 reward = (payout * 100) / 10000; // 1%
            if (reward > address(this).balance) reward = address(this).balance;
            _safeTransfer(payable(msg.sender), reward);
            uint256 toTrader = payout - reward;
            if (toTrader > 0) _safeTransfer(payable(pos.trader), toTrader);
        }

        emit PositionLiquidated(id, msg.sender, pos.trader, payout, pnlSigned);
    }

    // VIEW: get price (raw answer and decimals)
    function getLatestPriceRaw() external view returns (int256, uint8) {
        ( , int256 answer, , , ) = priceFeed.latestRoundData();
        uint8 dec = priceFeed.decimals();
        return (answer, dec);
    }

    // INTERNAL: compute PnL (signed) and payout amount (unsigned)
    // PnL formula: pnl = margin * (current - entry) / entry  (long)
    // for short: pnl = margin * (entry - current) / entry
    function _computePnLAndPayout(Position storage pos, uint256 currentPrice) internal view returns (int256, uint256) {
        if (pos.entryPrice == 0) return (0, pos.margin);

        int256 signedPriceDiff;
        if (currentPrice >= pos.entryPrice) {
            signedPriceDiff = int256(currentPrice - pos.entryPrice);
        } else {
            signedPriceDiff = -int256(pos.entryPrice - currentPrice);
        }

        // pnl scaled: (margin * signedPriceDiff) / entryPrice
        int256 pnl = (int256(pos.margin) * signedPriceDiff) / int256(pos.entryPrice);

        // adjust sign for short
        if (!pos.isLong) pnl = -pnl;

        if (pnl >= 0) {
            uint256 desired = uint256(int256(pos.margin) + pnl);
            uint256 cap = address(this).balance;
            if (desired > cap) desired = cap;
            return (pnl, desired);
        } else {
            uint256 lossAbs = uint256(-pnl);
            if (lossAbs >= pos.margin) {
                return (pnl, 0);
            } else {
                uint256 remaining = pos.margin - lossAbs;
                return (pnl, remaining);
            }
        }
    }

    // scale Chainlink price to 1e18
    function _getLatestPriceScaled() internal view returns (uint256) {
        ( , int256 answer, , , ) = priceFeed.latestRoundData();
        require(answer > 0, "invalid price");
        uint8 dec = priceFeed.decimals();
        if (dec <= 18) {
            return uint256(answer) * (10 ** (18 - dec));
        } else {
            return uint256(answer) / (10 ** (dec - 18));
        }
    }

    function _safeTransfer(address payable to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount, gas: 23000}("");
        require(ok, "transfer failed");
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }
}
