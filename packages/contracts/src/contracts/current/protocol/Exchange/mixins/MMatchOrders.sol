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

import "../LibOrder.sol";
import "./MExchangeCore.sol";

contract MMatchOrders is LibOrder, MExchangeCore {

    struct MatchedOrderFillAmounts {
        FillResults left;
        FillResults right;
    }

    function validateMatchOrdersContextOrRevert(Order memory left, Order memory right)
        private;


    function getMatchedFillAmounts(Order memory left, Order memory right)
        private
        returns (MatchedOrderFillAmounts memory matchedFillOrderAmounts);

    // Match two complementary orders that overlap.
    // The taker will end up with the maximum amount of left.makerAsset
    // Any right.makerAsset that taker would gain because of rounding are
    // transfered to right.
    function matchOrders(
        Order memory left,
        Order memory right,
        bytes leftSignature,
        bytes rightSignature)
        public
        returns (
            uint256 leftFilledAmount,
            uint256 rightFilledAmount);
}
