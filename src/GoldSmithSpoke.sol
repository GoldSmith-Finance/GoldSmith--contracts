// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "./GoldSmithState.sol";
import {MetalToken} from "./MetalToken.sol";
import "message-bridge-contracts/app/WmbApp.sol";
import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20 as OZ_IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract Spoke is GoldSmithState, WmbApp {
    /* ================ WANCHAIN STATE VARS ================ */

    uint256 constant GAS_LIMIT = 250_000;

    /* ================ CONTRACT MAIN STATE VARS ========== ====== */
    enum PoolType {
        GOLD,
        SILVER,
        DAI
    }

    address admin; //privilege to use funds from buyPool to back tokens with RWA
    OZ_IERC20 public buyWithToken; // DAI in this case
    mapping(MetalType => MetalToken) public metalTokens;
    mapping(MetalType => uint256) public buyPool; //pool used to back Metals Tokens by RWA
    mapping(uint => address) public spokeAddresses; //spoke contract addresses on different chains
    uint48 liquidationRatio; //liquidation percentage with 3 decimals

    //pool state
    address[] poolSuppliers; //check if user has supplied to pool
    mapping(PoolType => uint256) public lendAndBorrowPools; // pool type => [token1 balance, token2 balance]
    mapping(address => mapping(PoolType => uint256)) public userPoolSupplyData; // user => hash of pool and token => amount of token
    mapping(address => mapping(PoolType => uint256)) public userPoolBorrowData; // user => hash of pool and token => amount of token

    uint hubChain;
    address hubAddress;

    AggregatorV3Interface internal AuDataFeed;
    AggregatorV3Interface internal AgDataFeed;

    /* ================ CONTRACT MODIFIERS ================ */

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not Admin");

        _;
    }

    /* ================ CONTRACT MAIN FUNCTIONS ================ */

    constructor(
        uint _hubChain,
        address _hubAddress,
        address _admin,
        address _wmbGateway,
        OZ_IERC20 _buyWithToken,
        MetalToken Au,
        MetalToken Ag,
        AggregatorV3Interface AuDataFeed_,
        AggregatorV3Interface AgDataFeed_
    ) {
        initialize(_admin, _wmbGateway);

        admin = msg.sender;
        hubChain = _hubChain;
        hubAddress = _hubAddress;
        buyWithToken = _buyWithToken;
        metalTokens[MetalType.GOLD] = Au;
        metalTokens[MetalType.SILVER] = Ag;
        AuDataFeed = AuDataFeed_;
        AgDataFeed = AgDataFeed_;
        liquidationRatio = 60000; // 60%
    }

    function getChainlinkDataFeedLatestAnswer(
        MetalType metal
    ) internal view returns (int256) {
        int256 price;
        if (metal == MetalType.GOLD) {
            // in case chainlink is not present, send back approx price
            if (address(AuDataFeed) == address(0)) {
                return 198455e16;
            }

            // prettier-ignore
            (
            /* uint80 roundID */,
            int256 answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = AuDataFeed.latestRoundData();
            price = answer;
        } else if (metal == MetalType.SILVER) {
            // in case chainlink is not present, send back approx price
            if (address(AgDataFeed) == address(0)) {
                return 2309e16;
            }
            // prettier-ignore
            (
            /* uint80 roundID */,
            int256 answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = AgDataFeed.latestRoundData();
            price = answer;
        }

        return price;
    }

    /**
     * @notice Buy a Metal using DAI
     */
    function mintMetal(
        MetalType metalType,
        uint256 amountInGrams // supports 3 decimal places, 1g = 1000
    ) public payable {
        //prettier-ignore
        int256 pricePerGram = (getChainlinkDataFeedLatestAnswer(metalType) * (10 ** 7)) / 311034768; //price in $ per gram, decimals = 18

        uint256 totalPrice = (uint256(pricePerGram) * (amountInGrams)) / 1000; // converting to price w/ decimals = 18

        uint256 fee = estimateFee(hubChain, GAS_LIMIT);
        require(msg.value >= fee, "Insufficient fee");

        //prettier-ignore
        uint256 tokensToMint = (amountInGrams * 10 ** metalTokens[metalType].decimals()) / 1000; //fix
        buyPool[metalType] = buyPool[metalType] + tokensToMint;

        buyWithToken.transferFrom(msg.sender, address(this), totalPrice);

        metalTokens[metalType].mint(msg.sender, tokensToMint);

        bytes memory payload = abi.encode(
            Action.MINT_METAL,
            msg.sender,
            metalType,
            tokensToMint
        );

        _dispatchMessage(hubChain, hubAddress, payload, msg.value); //send data to hub chain
    }

    function burnMetal(
        MetalType metalType,
        uint256 amountOfTokens
    ) public payable {
        metalTokens[metalType].burn(msg.sender, amountOfTokens);

        //prettier-ignore
        int256 pricePerGram = (getChainlinkDataFeedLatestAnswer(metalType) * (10 ** 7) / 311034768 ); //price in $ per gram, decimals = 18
        //prettier-ignore
        uint256 totalPrice = (uint256(pricePerGram) * (amountOfTokens)) / 10 ** 18; // converting to price w/ decimals = 18

        buyWithToken.transfer(msg.sender, totalPrice);

        bytes memory payload = abi.encode(
            Action.BURN_METAL,
            msg.sender,
            metalType,
            amountOfTokens
        );

        uint256 fee = estimateFee(hubChain, GAS_LIMIT);
        require(msg.value >= fee, "Insufficient fee");

        _dispatchMessage(hubChain, hubAddress, payload, msg.value); //send data to hub chain
    }

    function transferTokensCrossChain(
        MetalType metalType,
        uint destChain,
        address destReceiver,
        uint256 amountOfTokens
    ) public payable {
        metalTokens[metalType].burn(msg.sender, amountOfTokens);

        uint256 fee = estimateFee(destChain, GAS_LIMIT);
        require(msg.value >= fee, "Insufficient fee");

        address destSpokeContract = spokeAddresses[destChain];

        bytes memory payload = abi.encode(
            Action.TRANSFER_METAL,
            msg.sender,
            destReceiver,
            metalType,
            amountOfTokens
        );

        _dispatchMessage(destChain, destSpokeContract, payload, msg.value); //send data to dest chain

        require(
            !checkIfUserIsUnderCollateralized(msg.sender),
            "User Becomes UnderCollateralized"
        );
    }

    function supplyTokensToPool(PoolType poolType, uint256 amount) public {
        lendAndBorrowPools[poolType] += amount;
        //prettier-ignore
        userPoolSupplyData[msg.sender][poolType] = userPoolSupplyData[msg.sender][poolType] + amount;

        (bool userExists, ) = userExistsInSuppliersList(msg.sender);
        if (!userExists) {
            poolSuppliers.push(msg.sender);
        }

        if (poolType == PoolType.GOLD) {
            //prettier-ignore
            metalTokens[MetalType.GOLD].transferFrom(msg.sender, address(this), amount);
        }
        if (poolType == PoolType.SILVER) {
            //prettier-ignore
            metalTokens[MetalType.SILVER].transferFrom(msg.sender, address(this), amount);
        }
        if (poolType == PoolType.DAI) {
            //prettier-ignore
            buyWithToken.transferFrom(msg.sender, address(this), amount);
        }
    }

    function borrowTokensFromPool(PoolType poolType, uint256 amount) public {
        lendAndBorrowPools[poolType] -= amount;
        //prettier-ignore
        userPoolBorrowData[msg.sender][poolType] = userPoolBorrowData[msg.sender][poolType]  + amount;

        if (poolType == PoolType.GOLD) {
            //prettier-ignore
            metalTokens[MetalType.GOLD].transfer(msg.sender, amount);
        }
        if (poolType == PoolType.SILVER) {
            //prettier-ignore
            metalTokens[MetalType.SILVER].transfer(msg.sender, amount);
        }
        if (poolType == PoolType.DAI) {
            //prettier-ignore
            buyWithToken.transfer(msg.sender, amount);
        }

        require(
            !checkIfUserIsUnderCollateralized(msg.sender),
            "User Becomes UnderCollateralized"
        );
    }

    function repayTokensToPool(PoolType poolType, uint256 amount) public {
        lendAndBorrowPools[poolType] += amount;
        //prettier-ignore
        userPoolBorrowData[msg.sender][poolType] = userPoolBorrowData[msg.sender][poolType] - amount;

        if (poolType == PoolType.GOLD) {
            //prettier-ignore
            metalTokens[MetalType.GOLD].transferFrom(msg.sender, address(this), amount);
        }
        if (poolType == PoolType.SILVER) {
            //prettier-ignore
            metalTokens[MetalType.SILVER].transferFrom(msg.sender, address(this), amount);
        }
        if (poolType == PoolType.DAI) {
            //prettier-ignore
            buyWithToken.transferFrom(msg.sender, address(this), amount);
        }
    }

    function unsupplyTokensToPool(PoolType poolType, uint256 amount) public {
        lendAndBorrowPools[poolType] -= amount;
        //prettier-ignore
        userPoolSupplyData[msg.sender][poolType] = userPoolSupplyData[msg.sender][poolType] - amount;

        if (!checkIfUserHasSuppliedToAnyPool(msg.sender)) {
            (bool userExists, uint index) = userExistsInSuppliersList(
                msg.sender
            );

            if (!userExists) {
                removeUserFromSupplierList(index);
            }
        }

        if (poolType == PoolType.GOLD) {
            //prettier-ignore
            metalTokens[MetalType.GOLD].transfer(msg.sender, amount);
        }
        if (poolType == PoolType.SILVER) {
            //prettier-ignore
            metalTokens[MetalType.SILVER].transfer(msg.sender, amount);
        }
        if (poolType == PoolType.DAI) {
            //prettier-ignore
            buyWithToken.transfer(msg.sender, amount);
        }
    }

    //prettier-ignore
    function checkIfUserHasSuppliedToAnyPool(address user) public view returns(bool) {

        for(uint i = 0; i <= uint(type(PoolType).max) + 1 ; i++) {
            if(userPoolSupplyData[user][PoolType(i)] >= 0) {
                return true;
            }
        }

        return false;
    }

    //prettier-ignore
    function checkIfUserIsUnderCollateralized(address user) view public returns(bool) {
        uint256 totalValueSupplied;
        uint256 totalValueBorrowed;

        for(uint i = 0; i <= uint(type(PoolType).max) + 1 ; i++) {

            if(PoolType(i) == PoolType.DAI) {
                totalValueSupplied += userPoolSupplyData[user][PoolType(i)];
                break;
            }
            
            MetalType metalType = MetalType(i);
            uint256 amountInGrams = userPoolSupplyData[user][PoolType(i)]; // decimals = 18
            int256 pricePerGram = (getChainlinkDataFeedLatestAnswer(metalType) * (10 ** 7)) / 311034768; //price in $ per gram, decimals = 18

            uint256 totalPrice = (uint256(pricePerGram) * (amountInGrams)) / 10 ** 18; // converting to price w/ decimals = 18

            totalValueSupplied += totalPrice;
            
        }

        for(uint i = 0; i <= uint(type(PoolType).max) + 1 ; i++) {

            if(PoolType(i) == PoolType.DAI) {
                totalValueBorrowed += userPoolBorrowData[user][PoolType(i)];
                break;
            }
            
            MetalType metalType = MetalType(i);
            uint256 amountInGrams = userPoolBorrowData[user][PoolType(i)]; // decimals = 18
            int256 pricePerGram = (getChainlinkDataFeedLatestAnswer(metalType) * (10 ** 7)) / 311034768; //price in $ per gram, decimals = 18

            uint256 totalPrice = (uint256(pricePerGram) * (amountInGrams)) / 10 ** 18; // converting to price w/ decimals = 18

            totalValueBorrowed += totalPrice;
            
        }

        return ((totalValueBorrowed * 100 ) / totalValueSupplied) > liquidationRatio;
    }

    function liquidateUnderCollateralized() public {
        //loop through each users

        for (uint i = 0; i <= poolSuppliers.length; i++) {
            address user = poolSuppliers[i];
            bool liquidateUser = checkIfUserIsUnderCollateralized(user);

            if (liquidateUser) {
                for (uint j = 0; j <= uint(type(PoolType).max) + 1; j++) {
                    userPoolSupplyData[user][PoolType(j)] = 0;
                    userPoolBorrowData[user][PoolType(j)] = 0;
                    removeUserFromSupplierList(i);
                }
            }
        }
    }

    function _wmbReceive(
        bytes calldata data,
        bytes32 messageId,
        uint256 fromChainId,
        address fromSC
    ) internal override {
        // do something you want...

        Action actionType = abi.decode(data, (Action));

        if (actionType == Action.TRANSFER_METAL) {
            (
                ,
                ,
                address receiver,
                MetalType metalType,
                uint256 amountOfTokens
            ) = abi.decode(
                    data,
                    (Action, address, address, MetalType, uint256)
                );

            metalTokens[metalType].mint(receiver, amountOfTokens);
        }
    }

    function adminExerciseBuyPool(MetalType metal) public onlyAdmin {
        buyWithToken.transfer(msg.sender, buyPool[metal]);
        buyPool[metal] = 0;
    }

    function adminAddSpokeContracts(
        uint16[] memory spokeChains_,
        address[] memory spokeAddresses_
    ) public onlyAdmin {
        require(
            spokeChains_.length == spokeAddresses_.length,
            "Wrong Params Sent"
        );

        for (uint i = 0; i < spokeChains_.length; i++) {
            spokeAddresses[spokeChains_[i]] = spokeAddresses_[i];
        }
    }

    //prettier-ignore
    function userExistsInSuppliersList(address user) public view returns (bool, uint) {
        for (uint i = 0; i < poolSuppliers.length; i++) {
            if (poolSuppliers[i] == user) {
                return (true, i);
            }
        }

        return (false, 0);
    }

    function removeUserFromSupplierList(uint index) public {
        poolSuppliers[index] = poolSuppliers[poolSuppliers.length - 1];
        poolSuppliers.pop();
    }
}
