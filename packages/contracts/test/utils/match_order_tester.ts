import { LogWithDecodedArgs, ZeroEx } from '0x.js';
import { BlockchainLifecycle } from '@0xproject/dev-utils';
import { BigNumber } from '@0xproject/utils';
import * as chai from 'chai';
import ethUtil = require('ethereumjs-util');
import * as _ from 'lodash';

import { DummyERC20TokenContract } from '../../src/contract_wrappers/generated/dummy_e_r_c20_token';
import { DummyERC721TokenContract } from '../../src/contract_wrappers/generated/dummy_e_r_c721_token';
import { ERC20ProxyContract } from '../../src/contract_wrappers/generated/e_r_c20_proxy';
import { ERC721ProxyContract } from '../../src/contract_wrappers/generated/e_r_c721_proxy';
import {
    CancelContractEventArgs,
    ExchangeContract,
    FillContractEventArgs,
} from '../../src/contract_wrappers/generated/exchange';
import { assetProxyUtils } from '../../src/utils/asset_proxy_utils';
import { constants } from '../../src/utils/constants';
import { crypto } from '../../src/utils/crypto';
import { ERC20Wrapper } from '../../src/utils/erc20_wrapper';
import { ERC721Wrapper } from '../../src/utils/erc721_wrapper';
import { ExchangeWrapper } from '../../src/utils/exchange_wrapper';
import { OrderFactory } from '../../src/utils/order_factory';
import { orderUtils } from '../../src/utils/order_utils';
import { AssetProxyId, ContractName, ERC20BalancesByOwner, ExchangeStatus, SignedOrder } from '../../src/utils/types';
import { chaiSetup } from '../utils/chai_setup';
import { deployer } from '../utils/deployer';
import { provider, web3Wrapper } from '../utils/web3_wrapper';

chaiSetup.configure();
const expect = chai.expect;
const blockchainLifecycle = new BlockchainLifecycle(web3Wrapper);

export class MatchOrderTester {
    private _exchangeWrapper: ExchangeWrapper;
    private _erc20Wrapper: ERC20Wrapper;

    constructor(exchangeWrapper: ExchangeWrapper, erc20Wrapper: ERC20Wrapper) {
        this._exchangeWrapper = exchangeWrapper;
        this._erc20Wrapper = erc20Wrapper;
    }

    public async matchOrders(
        signedOrderLeft: SignedOrder,
        signedOrderRight: SignedOrder,
        makerAssetAddressLeft: string,
        takerAssetAddressLeft: string,
        feeTokenAddress: string,
        takerAddress: string,
        erc20BalancesByOwner: ERC20BalancesByOwner,
    ) {
        const makerAddressLeft = signedOrderLeft.makerAddress;
        const makerAddressRight = signedOrderRight.makerAddress;
        const makerAssetAddressRight = takerAssetAddressLeft;
        const takerAssetAddressRight = makerAssetAddressLeft;
        const feeRecipientAddressLeft = signedOrderLeft.feeRecipientAddress;
        const feeRecipientAddressRight = signedOrderRight.feeRecipientAddress;

        const takerAssetFilledAmountBefore = await this._exchangeWrapper.getTakerAssetFilledAmountAsync(
            orderUtils.getOrderHashHex(signedOrderLeft),
        );
        expect(takerAssetFilledAmountBefore).to.be.bignumber.equal(0);

        await this._exchangeWrapper.matchOrdersAsync(signedOrderLeft, signedOrderRight, takerAddress);

        // Find the amount bought from each order
        const amountBoughtByLeftMaker = await this._exchangeWrapper.getTakerAssetFilledAmountAsync(
            orderUtils.getOrderHashHex(signedOrderLeft),
        );

        const amountBoughtByRightMaker = await this._exchangeWrapper.getTakerAssetFilledAmountAsync(
            orderUtils.getOrderHashHex(signedOrderRight),
        );

        console.log('amountBoughtByLeftMaker = ' + amountBoughtByLeftMaker);
        console.log('amountBoughtByRightMaker = ' + amountBoughtByRightMaker);

        const newBalances = await this._erc20Wrapper.getBalancesAsync();

        const amountSoldByLeftMaker = amountBoughtByLeftMaker
            .times(signedOrderLeft.makerAssetAmount)
            .dividedToIntegerBy(signedOrderLeft.takerAssetAmount);

        const amountSoldByRightMaker = amountBoughtByRightMaker
            .times(signedOrderRight.makerAssetAmount)
            .dividedToIntegerBy(signedOrderRight.takerAssetAmount);

        const amountReceivedByRightMaker = amountBoughtByLeftMaker
            .times(signedOrderRight.takerAssetAmount)
            .dividedToIntegerBy(signedOrderRight.makerAssetAmount);

        const amountReceivedByLeftMaker = amountSoldByRightMaker;

        const amountReceivedByTaker = amountSoldByLeftMaker.minus(amountReceivedByRightMaker);

        console.log('amountSoldByLeftMaker = ' + amountSoldByLeftMaker);
        console.log('amountSoldByRightMaker = ' + amountSoldByRightMaker);
        console.log('amountReceivedByLeftMaker = ' + amountReceivedByLeftMaker);
        console.log('amountReceivedByRightMaker = ' + amountReceivedByRightMaker);
        console.log('amountReceivedByTaker = ' + amountReceivedByTaker);

        // Verify Makers makerAsset
        expect(newBalances[makerAddressLeft][makerAssetAddressLeft]).to.be.bignumber.equal(
            erc20BalancesByOwner[makerAddressLeft][makerAssetAddressLeft].minus(amountSoldByLeftMaker),
        );

        expect(newBalances[makerAddressRight][makerAssetAddressRight]).to.be.bignumber.equal(
            erc20BalancesByOwner[makerAddressRight][makerAssetAddressRight].minus(amountSoldByRightMaker),
        );

        // Verify Maker's takerAssetAddressLeft
        expect(newBalances[makerAddressLeft][takerAssetAddressLeft]).to.be.bignumber.equal(
            erc20BalancesByOwner[makerAddressLeft][takerAssetAddressLeft].add(amountReceivedByLeftMaker),
        );

        expect(newBalances[makerAddressRight][takerAssetAddressRight]).to.be.bignumber.equal(
            erc20BalancesByOwner[makerAddressRight][takerAssetAddressRight].add(amountReceivedByRightMaker),
        );

        // Verify Taker's assets
        expect(newBalances[takerAddress][makerAssetAddressLeft]).to.be.bignumber.equal(
            erc20BalancesByOwner[takerAddress][makerAssetAddressLeft].add(amountReceivedByTaker),
        );
        expect(newBalances[takerAddress][takerAssetAddressLeft]).to.be.bignumber.equal(
            erc20BalancesByOwner[takerAddress][takerAssetAddressLeft],
        );
        expect(newBalances[takerAddress][makerAssetAddressRight]).to.be.bignumber.equal(
            erc20BalancesByOwner[takerAddress][makerAssetAddressRight],
        );
        expect(newBalances[takerAddress][takerAssetAddressRight]).to.be.bignumber.equal(
            erc20BalancesByOwner[takerAddress][takerAssetAddressRight].add(amountReceivedByTaker),
        );

        // Verify Fees - Left Maker
        const leftMakerFeePaid = signedOrderLeft.makerFee
            .times(amountSoldByLeftMaker)
            .dividedToIntegerBy(signedOrderLeft.makerAssetAmount);
        expect(newBalances[makerAddressLeft][feeTokenAddress]).to.be.bignumber.equal(
            erc20BalancesByOwner[makerAddressLeft][feeTokenAddress].minus(leftMakerFeePaid),
        );

        // Verify Fees - Right Maker
        const rightMakerFeePaid = signedOrderRight.makerFee
            .times(amountSoldByRightMaker)
            .dividedToIntegerBy(signedOrderRight.makerAssetAmount);
        expect(newBalances[makerAddressRight][feeTokenAddress]).to.be.bignumber.equal(
            erc20BalancesByOwner[makerAddressRight][feeTokenAddress].minus(rightMakerFeePaid),
        );

        // Verify Fees - Taker
        const takerFeePaidLeft = signedOrderLeft.takerFee
            .times(amountSoldByLeftMaker)
            .dividedToIntegerBy(signedOrderLeft.makerAssetAmount);
        const takerFeePaidRight = signedOrderRight.takerFee
            .times(amountSoldByRightMaker)
            .dividedToIntegerBy(signedOrderRight.makerAssetAmount);
        const takerFeePaid = takerFeePaidLeft.add(takerFeePaidRight);
        expect(newBalances[takerAddress][feeTokenAddress]).to.be.bignumber.equal(
            erc20BalancesByOwner[takerAddress][feeTokenAddress].minus(takerFeePaid),
        );

        // Verify Fees - Left Fee Recipient
        const feesReceivedLeft = leftMakerFeePaid.add(takerFeePaidLeft);
        expect(newBalances[feeRecipientAddressLeft][feeTokenAddress]).to.be.bignumber.equal(
            erc20BalancesByOwner[feeRecipientAddressLeft][feeTokenAddress].add(feesReceivedLeft),
        );

        // Verify Fees - Right Fee Receipient
        const feesReceivedRight = rightMakerFeePaid.add(takerFeePaidRight);
        expect(newBalances[feeRecipientAddressRight][feeTokenAddress]).to.be.bignumber.equal(
            erc20BalancesByOwner[feeRecipientAddressRight][feeTokenAddress].add(feesReceivedRight),
        );
    }
}
