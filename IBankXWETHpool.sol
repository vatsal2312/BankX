// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;

interface IBankXWETHpool {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);
    function amountpaid() external view returns (uint);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function provideLiquidity() external;
    function provideLiquidity2(address to) external;
    function collatDollarBalance() external returns(uint);
    function swap(uint amount0Out, uint amount1Out, address to) external;
    function skim(address to) external;
    function sync() external;
    function flush() external;
    function LiquidityRedemption(address to) external;
    function initialize(address _token0, address _token1, address _bankx_contract_address, address _pid_address) external;
}