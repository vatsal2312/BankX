// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;

interface IPIDController{
    function andCounter() external view returns (uint);
    function bucket1() external view returns (bool);
    function bucket2() external view returns (bool);
    function bucket3() external view returns (bool);
    function diff1() external view returns (uint);
    function diff2() external view returns (uint);
    function diff3() external view returns (uint);
}