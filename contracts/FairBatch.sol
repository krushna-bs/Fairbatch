// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FairBatch
/// @notice Fully onchain batch-auction MVP for ETH/TESTUSDC trading.
/// @dev Orders are grouped into epochs and cleared at a common price.
///      This MVP supports complete equal-sized order matching only.
contract FairBatch is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_ORDERS_PER_EPOCH = 64;
    uint256 public constant MAX_ORDER_ETH = 10 ether;
    uint256 public constant MAX_EPOCH_ETH_VOLUME = 640 ether;

    // Price is TESTUSDC base units per 1 ETH.
    // TESTUSDC has 6 decimals, so $2,507.32 = 2_507_320_000.
    uint256 public constant PRICE_SCALE = 1e18;

    IERC20 public immutable testUSDC;

    enum Side {
        BUY,
        SELL
    }

    enum OrderStatus {
        OPEN,
        MATCHED,
        SETTLED,
        REFUNDED
    }

    struct Order {
        address owner;
        Side side;
        uint256 ethAmount;
        uint256 limitPrice;
        uint256 epoch;
        OrderStatus status;
        uint256 escrowedAmount;
        uint256 matchedOrderId;
    }

    struct Epoch {
        bool closed;
        bool cleared;
        uint256 clearingPrice;
        uint256 matchedVolume;
    }

    uint256 public currentEpoch = 1;
    uint256 public nextOrderId = 1;

    mapping(uint256 => Order) public orders;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => uint256[]) private epochOrderIds;
    mapping(uint256 => uint256) public epochEthVolume;

    error InvalidToken();
    error InvalidAmount();
    error InvalidPrice();
    error OrderTooLarge();
    error EpochVolumeExceeded();
    error EpochClosed();
    error EpochNotClosed();
    error EpochAlreadyCleared();
    error EpochNotCleared();
    error TooManyOrders();
    error OrderNotFound();
    error NotOrderOwner();
    error InvalidOrderStatus();
    error InvalidMatch();
    error AlreadyMatched();
    error TransferFailed();

    event OrderSubmitted(
        uint256 indexed orderId,
        uint256 indexed epoch,
        address indexed owner,
        Side side,
        uint256 ethAmount,
        uint256 limitPrice
    );

    event EpochClosed(uint256 indexed epoch);

    event EpochCleared(
        uint256 indexed epoch,
        uint256 clearingPrice,
        uint256 matchedVolume
    );

    event OrdersMatched(
        uint256 indexed epoch,
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        uint256 ethAmount
    );

    event MatchSettled(
        uint256 indexed epoch,
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        uint256 ethAmount,
        uint256 clearingPrice,
        uint256 quoteAmount
    );

    event OrderRefunded(
        uint256 indexed orderId,
        address indexed owner,
        uint256 amount
    );

    constructor(address testUSDCAddress) {
        if (testUSDCAddress == address(0)) {
            revert InvalidToken();
        }

        testUSDC = IERC20(testUSDCAddress);
        epochs[currentEpoch].closed = false;
    }

    /// @notice Submit a BUY order and escrow TESTUSDC at the buyer's limit price.
    /// @param ethAmount Amount of ETH desired, in wei.
    /// @param limitPrice Maximum TESTUSDC base units payable per ETH.
    function submitBuy(
        uint256 ethAmount,
        uint256 limitPrice
    ) external returns (uint256 orderId) {
        _validateNewOrder(ethAmount, limitPrice);

        uint256 quoteAmount = quoteAtPrice(ethAmount, limitPrice);

        testUSDC.safeTransferFrom(
            msg.sender,
            address(this),
            quoteAmount
        );

        orderId = _createOrder(
            Side.BUY,
            ethAmount,
            limitPrice,
            quoteAmount
        );
    }

    /// @notice Submit a SELL order and escrow ETH.
    /// @param ethAmount Amount of ETH being sold, in wei.
    /// @param limitPrice Minimum TESTUSDC base units acceptable per ETH.
    function submitSell(
        uint256 ethAmount,
        uint256 limitPrice
    ) external payable returns (uint256 orderId) {
        _validateNewOrder(ethAmount, limitPrice);

        if (msg.value != ethAmount) {
            revert InvalidAmount();
        }

        orderId = _createOrder(
            Side.SELL,
            ethAmount,
            limitPrice,
            ethAmount
        );
    }

    /// @notice Close the current epoch so that no more orders can be submitted.
    function closeEpoch() external {
        Epoch storage epoch = epochs[currentEpoch];

        if (epoch.closed) {
            revert EpochClosed();
        }

        epoch.closed = true;

        emit EpochClosed(currentEpoch);
    }

    /// @notice Determine and store the deterministic clearing price.
    /// @dev Candidate prices are the submitted limit prices.
    ///      Maximum executable volume wins; lower price wins ties.
    function clearEpoch() external {
        uint256 epochId = currentEpoch;
        Epoch storage epoch = epochs[epochId];

        if (!epoch.closed) {
            revert EpochNotClosed();
        }

        if (epoch.cleared) {
            revert EpochAlreadyCleared();
        }

        uint256[] storage ids = epochOrderIds[epochId];

        if (ids.length == 0) {
            epoch.cleared = true;
            epoch.clearingPrice = 0;
            epoch.matchedVolume = 0;

            emit EpochCleared(epochId, 0, 0);
            return;
        }

        uint256[] memory candidates = new uint256[](ids.length);
        uint256 candidateCount = 0;

        // Build unique candidate prices.
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 price = orders[ids[i]].limitPrice;
            bool exists;

            for (uint256 j = 0; j < candidateCount; j++) {
                if (candidates[j] == price) {
                    exists = true;
                    break;
                }
            }

            if (!exists) {
                candidates[candidateCount] = price;
                candidateCount++;
            }
        }

        uint256 bestPrice;
        uint256 bestVolume;

        for (uint256 i = 0; i < candidateCount; i++) {
            uint256 candidatePrice = candidates[i];
            uint256 buyVolume;
            uint256 sellVolume;

            for (uint256 j = 0; j < ids.length; j++) {
                Order storage order = orders[ids[j]];

                if (order.side == Side.BUY) {
                    if (order.limitPrice >= candidatePrice) {
                        buyVolume += order.ethAmount;
                    }
                } else {
                    if (order.limitPrice <= candidatePrice) {
                        sellVolume += order.ethAmount;
                    }
                }
            }

            uint256 executableVolume = Math.min(
                buyVolume,
                sellVolume
            );

            if (
                executableVolume > bestVolume ||
                (
                    executableVolume == bestVolume &&
                    executableVolume > 0 &&
                    (bestPrice == 0 || candidatePrice < bestPrice)
                )
            ) {
                bestVolume = executableVolume;
                bestPrice = candidatePrice;
            }
        }

        epoch.clearingPrice = bestPrice;
        epoch.matchedVolume = bestVolume;
        epoch.cleared = true;

        _matchOrders(epochId);

        emit EpochCleared(
            epochId,
            bestPrice,
            bestVolume
        );
    }

    /// @notice Settle a matched BUY/SELL pair at the epoch clearing price.
    /// @param orderId Any order ID belonging to the matched pair.
    function settleMatch(uint256 orderId) external nonReentrant {
        Order storage first = orders[orderId];

        if (first.owner == address(0)) {
            revert OrderNotFound();
        }

        if (first.status != OrderStatus.MATCHED) {
            revert InvalidOrderStatus();
        }

        uint256 otherId = first.matchedOrderId;
        Order storage second = orders[otherId];

        if (second.status != OrderStatus.MATCHED) {
            revert InvalidMatch();
        }

        Epoch storage epoch = epochs[first.epoch];

        if (!epoch.cleared) {
            revert EpochNotCleared();
        }

        uint256 buyOrderId;
        uint256 sellOrderId;

        if (first.side == Side.BUY) {
            buyOrderId = orderId;
            sellOrderId = otherId;
        } else {
            buyOrderId = otherId;
            sellOrderId = orderId;
        }

        Order storage buyOrder = orders[buyOrderId];
        Order storage sellOrder = orders[sellOrderId];

        if (buyOrder.ethAmount != sellOrder.ethAmount) {
            revert InvalidMatch();
        }

        uint256 ethAmount = buyOrder.ethAmount;
        uint256 quoteAmount = quoteAtPrice(
            ethAmount,
            epoch.clearingPrice
        );

        if (quoteAmount > buyOrder.escrowedAmount) {
            revert InvalidMatch();
        }

        // Effects first.
        uint256 buyerRefund = buyOrder.escrowedAmount - quoteAmount;

        buyOrder.escrowedAmount = 0;
        sellOrder.escrowedAmount = 0;

        buyOrder.status = OrderStatus.SETTLED;
        sellOrder.status = OrderStatus.SETTLED;

        // Seller receives TESTUSDC at the common clearing price.
        testUSDC.safeTransfer(
            sellOrder.owner,
            quoteAmount
        );

        // Any unused BUY escrow is returned.
        if (buyerRefund > 0) {
            testUSDC.safeTransfer(
                buyOrder.owner,
                buyerRefund
            );
        }

        // Buyer receives the escrowed ETH.
        (bool success, ) = payable(buyOrder.owner).call{
            value: ethAmount
        }("");

        if (!success) {
            revert TransferFailed();
        }

        emit MatchSettled(
            first.epoch,
            buyOrderId,
            sellOrderId,
            ethAmount,
            epoch.clearingPrice,
            quoteAmount
        );
    }

    /// @notice Refund an unmatched order after its epoch has been cleared.
    function refundOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];

        if (order.owner == address(0)) {
            revert OrderNotFound();
        }

        if (order.owner != msg.sender) {
            revert NotOrderOwner();
        }

        if (order.status != OrderStatus.OPEN) {
            revert InvalidOrderStatus();
        }

        Epoch storage epoch = epochs[order.epoch];

        if (!epoch.cleared) {
            revert EpochNotCleared();
        }

        uint256 amount = order.escrowedAmount;

        order.escrowedAmount = 0;
        order.status = OrderStatus.REFUNDED;

        if (amount > 0) {
            if (order.side == Side.BUY) {
                testUSDC.safeTransfer(
                    order.owner,
                    amount
                );
            } else {
                (bool success, ) = payable(order.owner).call{
                    value: amount
                }("");

                if (!success) {
                    revert TransferFailed();
                }
            }
        }

        emit OrderRefunded(
            orderId,
            order.owner,
            amount
        );
    }

    /// @notice Start the next order epoch after the current epoch is cleared.
    function startNextEpoch() external {
        if (!epochs[currentEpoch].cleared) {
            revert EpochNotCleared();
        }

        currentEpoch++;
    }

    /// @notice Return all order IDs belonging to an epoch.
    function getEpochOrderIds(
        uint256 epochId
    ) external view returns (uint256[] memory) {
        return epochOrderIds[epochId];
    }

    /// @notice Return the number of orders in an epoch.
    function getEpochOrderCount(
        uint256 epochId
    ) external view returns (uint256) {
        return epochOrderIds[epochId].length;
    }

    /// @notice Calculate the TESTUSDC base-unit quote for an ETH amount.
    function quoteAtPrice(
        uint256 ethAmount,
        uint256 price
    ) public pure returns (uint256) {
        return Math.mulDiv(
            ethAmount,
            price,
            PRICE_SCALE,
            Math.Rounding.Ceil
        );
    }

    function _validateNewOrder(
        uint256 ethAmount,
        uint256 limitPrice
    ) internal view {
        if (ethAmount == 0) {
            revert InvalidAmount();
        }

        if (ethAmount > MAX_ORDER_ETH) {
            revert OrderTooLarge();
        }

        if (limitPrice == 0) {
            revert InvalidPrice();
        }

        if (epochs[currentEpoch].closed) {
            revert EpochClosed();
        }

        if (
            epochOrderIds[currentEpoch].length >=
            MAX_ORDERS_PER_EPOCH
        ) {
            revert TooManyOrders();
        }

        if (
            epochEthVolume[currentEpoch] + ethAmount >
            MAX_EPOCH_ETH_VOLUME
        ) {
            revert EpochVolumeExceeded();
        }
    }

    function _createOrder(
        Side side,
        uint256 ethAmount,
        uint256 limitPrice,
        uint256 escrowedAmount
    ) internal returns (uint256 orderId) {
        orderId = nextOrderId++;

        orders[orderId] = Order({
            owner: msg.sender,
            side: side,
            ethAmount: ethAmount,
            limitPrice: limitPrice,
            epoch: currentEpoch,
            status: OrderStatus.OPEN,
            escrowedAmount: escrowedAmount,
            matchedOrderId: 0
        });

        epochOrderIds[currentEpoch].push(orderId);
        epochEthVolume[currentEpoch] += ethAmount;

        emit OrderSubmitted(
            orderId,
            currentEpoch,
            msg.sender,
            side,
            ethAmount,
            limitPrice
        );
    }

    /// @dev Matches only complete equal-sized orders.
    ///      Canonical ordering uses owner address, ETH amount,
    ///      limit price, then order ID. It is used only for allocation,
    ///      never for determining the clearing price.
    function _matchOrders(uint256 epochId) internal {
        Epoch storage epoch = epochs[epochId];

        if (epoch.clearingPrice == 0 || epoch.matchedVolume == 0) {
            return;
        }

        uint256[] storage ids = epochOrderIds[epochId];
        uint256[] memory sortedIds = new uint256[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            sortedIds[i] = ids[i];
        }

        _sortOrderIds(sortedIds);

        uint256 allocatedVolume;

        for (uint256 i = 0; i < sortedIds.length; i++) {
            Order storage buyOrder = orders[sortedIds[i]];

            if (
                buyOrder.side != Side.BUY ||
                buyOrder.status != OrderStatus.OPEN ||
                buyOrder.limitPrice < epoch.clearingPrice
            ) {
                continue;
            }

            for (
                uint256 j = 0;
                j < sortedIds.length;
                j++
            ) {
                Order storage sellOrder = orders[sortedIds[j]];

                if (
                    sellOrder.side != Side.SELL ||
                    sellOrder.status != OrderStatus.OPEN ||
                    sellOrder.limitPrice > epoch.clearingPrice
                ) {
                    continue;
                }

                if (buyOrder.ethAmount != sellOrder.ethAmount) {
                    continue;
                }

                if (
                    allocatedVolume +
                    buyOrder.ethAmount >
                    epoch.matchedVolume
                ) {
                    return;
                }

                buyOrder.status = OrderStatus.MATCHED;
                sellOrder.status = OrderStatus.MATCHED;

                buyOrder.matchedOrderId = sortedIds[j];
                sellOrder.matchedOrderId = sortedIds[i];

                allocatedVolume += buyOrder.ethAmount;

                emit OrdersMatched(
                    epochId,
                    sortedIds[i],
                    sortedIds[j],
                    buyOrder.ethAmount
                );

                break;
            }
        }
    }

    function _sortOrderIds(
        uint256[] memory ids
    ) internal view {
        // Insertion sort is acceptable for the 64-order MVP cap.
        for (uint256 i = 1; i < ids.length; i++) {
            uint256 key = ids[i];
            uint256 j = i;

            while (
                j > 0 &&
                _comesBefore(key, ids[j - 1])
            ) {
                ids[j] = ids[j - 1];
                j--;
            }

            ids[j] = key;
        }
    }

    function _comesBefore(
        uint256 leftId,
        uint256 rightId
    ) internal view returns (bool) {
        Order storage left = orders[leftId];
        Order storage right = orders[rightId];

        if (left.owner != right.owner) {
            return uint160(left.owner) < uint160(right.owner);
        }

        if (left.ethAmount != right.ethAmount) {
            return left.ethAmount < right.ethAmount;
        }

        if (left.limitPrice != right.limitPrice) {
            return left.limitPrice < right.limitPrice;
        }

        return leftId < rightId;
    }
}
