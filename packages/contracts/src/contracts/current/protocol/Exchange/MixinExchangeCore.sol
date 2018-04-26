/*

  Copyright 2018 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.4.21;
pragma experimental ABIEncoderV2;

import "./mixins/MExchangeCore.sol";
import "./mixins/MSettlement.sol";
import "./mixins/MSignatureValidator.sol";
import "./mixins/MTransactions.sol";
import "./LibOrder.sol";
import "./LibOrderStatus.sol";
import "./LibPartialAmount.sol";
import "../../utils/SafeMath/SafeMath.sol";

/// @dev Provides MExchangeCore
/// @dev Consumes MSettlement
/// @dev Consumes MSignatureValidator
contract MixinExchangeCore is
    LibOrder,
    MExchangeCore,
    MSettlement,
    MSignatureValidator,
    MTransactions,
    SafeMath,
    LibOrderStatus,
    LibPartialAmount
{
    // Mapping of orderHash => amount of takerAsset already bought by maker
    mapping (bytes32 => uint256) public filled;

    // Mapping of orderHash => cancelled
    mapping (bytes32 => bool) public cancelled;

    // Mapping of makerAddress => lowest salt an order can have in order to be fillable
    // Orders with a salt less than their maker's epoch are considered cancelled
    mapping (address => uint256) public makerEpoch;

    event Fill(
        address indexed makerAddress,
        address takerAddress,
        address indexed feeRecipientAddress,
        uint256 makerAssetFilledAmount,
        uint256 takerAssetFilledAmount,
        uint256 makerFeePaid,
        uint256 takerFeePaid,
        bytes32 indexed orderHash,
        bytes makerAssetData,
        bytes takerAssetData
    );

    event Cancel(
        address indexed makerAddress,
        address indexed feeRecipientAddress,
        bytes32 indexed orderHash,
        bytes makerAssetData,
        bytes takerAssetData
    );

    event CancelUpTo(
        address indexed makerAddress,
        uint256 makerEpoch
    );

    /*
    * Core exchange functions
    */

    function getOrderStatus(
        Order memory order,
        bytes memory signature)
        public
        view
        returns (
            uint8 status,
            bytes32 orderHash,
            uint256 filledAmount)
    {
        // Compute the order hash and fetch filled amount
        orderHash = getOrderHash(order);
        filledAmount = filled[orderHash];

        // Validations on order only if first time seen
        if (filledAmount == 0) {

            // If order.takerAssetAmount is zero, then the order will always
            // be considered filled because:
            //    0 == takerAssetAmount == filledAmount
            // Instead of distinguishing between unfilled and filled zero taker
            // amount orders, we choose not to support them.
            if (order.takerAssetAmount == 0) {
                status = uint8(OrderStatus.ORDER_INVALID);
                return;
            }

            // If order.makerAssetAmount is zero, we also reject the order.
            // While the Exchange contract handles them correctly, they create
            // edge cases in the supporting infrastructure because they have
            // an 'infinite' price when computed by a simple division.
            if (order.makerAssetAmount == 0) {
                status = uint8(OrderStatus.ORDER_INVALID);
                return;
            }

            // Maker signature needs to be valid
            if (!isValidSignature(orderHash, order.makerAddress, signature)) {
                status = uint8(OrderStatus.ORDER_SIGNATURE_INVALID);
                return;
            }
        }

        // Validate order expiration
        if (block.timestamp >= order.expirationTimeSeconds) {
            status = uint8(OrderStatus.ORDER_EXPIRED);
            return;
        }

        // Validate order availability
        if (filledAmount >= order.takerAssetAmount) {
            status = uint8(OrderStatus.ORDER_FULLY_FILLED);
            return;
        }

        // Check if order has been cancelled
        if (cancelled[orderHash]) {
            status = uint8(OrderStatus.ORDER_CANCELLED);
            return;
        }

        // Validate order is not cancelled
        if (makerEpoch[order.makerAddress] > order.salt) {
            status = uint8(OrderStatus.ORDER_CANCELLED);
            return;
        }

        // Validate sender is allowed to fill this order
        if (order.senderAddress != address(0) && order.senderAddress != msg.sender) {
            status = uint8(OrderStatus.ORDER_SENDER_INVALID);
            return;
        }

        // Order is OK
        status = uint8(OrderStatus.SUCCESS);
        return;
    }

    function getFillAmounts(
        Order memory order,
        uint256 filledAmount,
        uint256 takerAssetFillAmount,
        address takerAddress)
        public
        pure
        returns (
            uint8 status,
            FillResults memory fillResults)
    {
        // Validate taker is allowed to fill this order
        if (order.takerAddress != address(0)) {
            require(order.takerAddress == takerAddress);
        }
        require(takerAssetFillAmount > 0);

        // Compute takerAssetFilledAmount
        uint256 remainingtakerAssetAmount = safeSub(
            order.takerAssetAmount, filledAmount);
        fillResults.takerAssetFilledAmount = min256(
            takerAssetFillAmount, remainingtakerAssetAmount);

        // Validate fill order rounding
        if (isRoundingError(
            fillResults.takerAssetFilledAmount,
            order.takerAssetAmount,
            order.makerAssetAmount))
        {
            status = uint8(OrderStatus.ROUNDING_ERROR_TOO_LARGE);
            return;
        }

        // Compute proportional transfer amounts
        // TODO: All three are multiplied by the same fraction. This can
        // potentially be optimized.
        fillResults.makerAssetFilledAmount = getPartialAmount(
            fillResults.takerAssetFilledAmount,
            order.takerAssetAmount,
            order.makerAssetAmount);
        fillResults.makerFeePaid = getPartialAmount(
            fillResults.takerAssetFilledAmount,
            order.takerAssetAmount,
            order.makerFee);
        fillResults.takerFeePaid = getPartialAmount(
            fillResults.takerAssetFilledAmount,
            order.takerAssetAmount,
            order.takerFee);

        status = uint8(OrderStatus.SUCCESS);
        return;
    }

    function updateState(
        Order memory order,
        address takerAddress,
        bytes32 orderHash,
        FillResults memory fillResults)
        private
    {
        // Update state
        filled[orderHash] = safeAdd(filled[orderHash], fillResults.takerAssetFilledAmount);

        // Log order
        emitFillEvent(order, takerAddress, orderHash, fillResults);
    }

    /// @dev Fills the input order.
    /// @param order Order struct containing order specifications.
    /// @param takerAssetFillAmount Desired amount of takerToken to sell.
    /// @param signature Proof that order has been created by maker.
    /// @return Amounts filled and fees paid by maker and taker.
    function fillOrder(
        Order memory order,
        uint256 takerAssetFillAmount,
        bytes memory signature)
        public
        returns (FillResults memory fillResults)
    {
        // Fetch current order status
        bytes32 orderHash;
        uint8 status;
        uint256 filledAmount;
        (status, orderHash, filledAmount) = getOrderStatus(order, signature);
        if (!isValidOrderStatus(OrderStatus(status))) {
            emit ExchangeOrderStatus(uint8(status), orderHash);
            revert();
        } else if (status != uint8(OrderStatus.SUCCESS)) {
            emit ExchangeOrderStatus(uint8(status), orderHash);
            return fillResults;
        }

        // Get the taker address
        address takerAddress = getCurrentContextAddress();

        // Compute proportional fill amounts
        uint256 makerAssetFilledAmount;
        uint256 makerFeePaid;
        uint256 takerFeePaid;
        (   status,
            fillResults
        ) = getFillAmounts(
            order,
            filledAmount,
            takerAssetFillAmount,
            takerAddress);
        if (status != uint8(OrderStatus.SUCCESS)) {
            emit ExchangeOrderStatus(uint8(status), orderHash);
            return fillResults;
        }

        // Settle order
        (fillResults.makerAssetFilledAmount, fillResults.makerFeePaid, fillResults.takerFeePaid) =
            settleOrder(order, takerAddress, fillResults.takerAssetFilledAmount);

        // Update exchange internal state
        updateState(order, takerAddress, orderHash, fillResults);
        return fillResults;
    }

    /// @dev After calling, the order can not be filled anymore.
    /// @param order Order struct containing order specifications.
    /// @return True if the order state changed to cancelled.
    ///         False if the transaction was already cancelled or expired.
    function cancelOrder(Order memory order)
        public
        returns (bool)
    {
        // Compute the order hash
        bytes32 orderHash = getOrderHash(order);

        // Validate the order
        require(order.makerAssetAmount > 0);
        require(order.takerAssetAmount > 0);

        // Validate sender is allowed to cancel this order
        if (order.senderAddress != address(0)) {
            require(order.senderAddress == msg.sender);
        }

        // Validate transaction signed by maker
        address makerAddress = getCurrentContextAddress();
        require(order.makerAddress == makerAddress);

        if (block.timestamp >= order.expirationTimeSeconds) {
            emit ExchangeOrderStatus(uint8(OrderStatus.ORDER_EXPIRED), orderHash);
            return false;
        }

        if (cancelled[orderHash]) {
            emit ExchangeOrderStatus(uint8(OrderStatus.ORDER_CANCELLED), orderHash);
            return false;
        }

        cancelled[orderHash] = true;

        emit Cancel(
            order.makerAddress,
            order.feeRecipientAddress,
            orderHash,
            order.makerAssetData,
            order.takerAssetData
        );
        return true;
    }

    /// @param salt Orders created with a salt less or equal to this value will be cancelled.
    function cancelOrdersUpTo(uint256 salt)
        external
    {
        uint256 newMakerEpoch = salt + 1;                // makerEpoch is initialized to 0, so to cancelUpTo we need salt+1
        require(newMakerEpoch > makerEpoch[msg.sender]); // epoch must be monotonically increasing
        makerEpoch[msg.sender] = newMakerEpoch;
        emit CancelUpTo(msg.sender, newMakerEpoch);
    }

    /// @dev Checks if rounding error > 0.1%.
    /// @param numerator Numerator.
    /// @param denominator Denominator.
    /// @param target Value to multiply with numerator/denominator.
    /// @return Rounding error is present.
    function isRoundingError(uint256 numerator, uint256 denominator, uint256 target)
        public pure
        returns (bool isError)
    {
        uint256 remainder = mulmod(target, numerator, denominator);
        if (remainder == 0) {
            return false; // No rounding error.
        }

        uint256 errPercentageTimes1000000 = safeDiv(
            safeMul(remainder, 1000000),
            safeMul(numerator, target)
        );
        isError = errPercentageTimes1000000 > 1000;
        return isError;
    }

    /// @dev Logs a Fill event with the given arguments.
    ///      The sole purpose of this function is to get around the stack variable limit.
    function emitFillEvent(
        Order memory order,
        address takerAddress,
        bytes32 orderHash,
        FillResults memory fillResults)
        internal
    {
        emit Fill(
            order.makerAddress,
            takerAddress,
            order.feeRecipientAddress,
            fillResults.makerAssetFilledAmount,
            fillResults.takerAssetFilledAmount,
            fillResults.makerFeePaid,
            fillResults.takerFeePaid,
            orderHash,
            order.makerAssetData,
            order.takerAssetData
        );
    }
}
