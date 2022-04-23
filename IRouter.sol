// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;


interface IRouter{
    function creatorAddLiquidityTokens(
        address tokenB,
        uint amountB
    ) external;

    function creatorAddLiquidityETH(
        address pool,
        uint amountETH
    ) external payable;

    function userAddLiquidityETH(
        address pool, 
        address sender,
        uint amountETH
    ) external payable;

    function swapETHForXSD(uint amountOut, address to) external payable;

    function swapXSDForETH(uint amountOut, uint amountInMax, address to) external;

    function swapETHForBankX(uint amountOut, address to) external payable;
    
    function swapBankXForETH(uint amountOut, uint amountInMax, address to) external;

}