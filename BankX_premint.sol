// SPDX-License-Identifier: GPL-2.0-or-later
//new-code-start
pragma solidity >=0.6.11;

import "../Common/Context.sol";
import "../ERC20/ERC20Custom.sol";
import "../ERC20/IERC20.sol";
import "./BankX.sol";
import"../XSD/XSD.sol";
import "../Staking/Owned.sol";
import "../Math/SafeMath.sol";

contract BankX_premint is ERC20Custom, Owned{
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    //ERC20 instances
    BankXToken BankX;
    XSDStablecoin XSD;
    //addresses
    address bankx_address;
    address xsd_address;

    //empty constructor initializes smart contract owner
    constructor() Owned(smartcontract_owner){}

    //call this function to set the BankX instance in the contract.
    function setBankXToken(address _bankx_contract_address) public onlyOwner{
        require(_bankx_contract_address != address(0), "Zero address detected");
        BankX = BankXToken(_bankx_contract_address);
        bankx_address = _bankx_contract_address;
    }

    //call this function to set the XSD instance in the contract.
    function setXSDToken(address _xsd_contract_address) public onlyOwner{
        require(_xsd_contract_address != address(0), "Zero Address detected");
        XSD = XSDStablecoin(_xsd_contract_address);
        xsd_address = _xsd_contract_address;
    }
    
    // user accessible function that accepts the BankX amount and ETH sent with transaction 
    // as parameters.
    function BuyBankX(uint256 BankXamount, uint256 ETHamount) public payable {
        require(msg.value == ETHamount, "Ether amount sent differs from input parameter");
        uint ethvalue = ETHamount.mul(XSD.eth_usd_price());
        uint bankxamount = ethvalue.div(XSD.bankx_price());
        require(BankXamount <= bankxamount, "Slippage limit reached" );
        require(BankX.transfer(_msgSender(), BankXamount), "Owner address has yet to transfer BankX to this address");
    }

    function withdrawEth() public{
        require(_msgSender() == origin_address);
        _msgSender().transfer(address(this).balance);
    }

     /* Fallback function */
    receive() external payable {
        emit ValueReceived(_msgSender(), msg.value);
    }

        event ValueReceived(address user, uint amount);

}
//new-code-end