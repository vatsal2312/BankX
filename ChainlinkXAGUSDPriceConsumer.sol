// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;

import "./AggregatorV3Interface.sol";

contract ChainlinkXAGUSDPriceConsumer {

    AggregatorV3Interface internal priceFeed;


    constructor() public {
        //Mainnet address: 0x379589227b15F1a12195D3f2d90bBc9F31f95235
        //Rinkeby address: 0x9c1946428f4f159dB4889aA6B218833f467e1BfD
        
        priceFeed = AggregatorV3Interface(0x9c1946428f4f159dB4889aA6B218833f467e1BfD);
    }

    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        (
            , 
            int price,
            ,
            ,
            
        ) = priceFeed.latestRoundData();
        return price;
    }

    function getDecimals() public view returns (uint8) {
        return priceFeed.decimals();
    }
}