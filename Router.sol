// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;

import './TransferHelper.sol';

import './IRouter.sol';
import './XSD.sol';
import './IXSDWETHpool.sol';
import './IBankXWETHpool.sol';
import './BankXLibrary.sol';
import './SafeMath.sol';
import './IERC20.sol';
import './IWETH.sol';

//import pools and get the price of bankx/xsd with respect to eth. Then multiply into eth_usd_price.

contract Router is IRouter {
    using SafeMath for uint;

    address public immutable WETH;
    address public XSDWETH_pool;
    address public BankXWETH_pool;
    address public bankx_address;
    address public xsd_address;
    address private treasury = 0x4b3607a868044EbD88d9326bCa7E1d8AD51AE48a;
    address public smartcontract_owner = 0xC34faEea3605a168dBFE6afCd6f909714F844cd7;
    XSDStablecoin private XSD;
    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'BankXRouter: EXPIRED');
        _;
    }

    constructor(address _WETH) public {
        WETH = _WETH;
    }

     // called once by the smart contract owner at time of deployment
     // sets the pool&token addresses
    function initialize(address _bankx_address, address _xsd_address,address _XSDWETH_pool, address _BankXWETH_pool) public {
        require(msg.sender == smartcontract_owner, 'BankXRouter: FORBIDDEN'); // sufficient check
        bankx_address = _bankx_address;
        xsd_address = _xsd_address;
        XSDWETH_pool = _XSDWETH_pool;
        BankXWETH_pool = _BankXWETH_pool;
        XSD = XSDStablecoin(_xsd_address);
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // **** ADD LIQUIDITY ****
    //creator may add XSD/BankX to their respective pools via this function
    function provideLiquidity(address pool) internal virtual {
        if(pool == XSDWETH_pool){
            IXSDWETHpool(pool).provideLiquidity();
        }
        else if(pool == BankXWETH_pool){
            IBankXWETHpool(pool).provideLiquidity();
        }
    }

    function provideLiquidity2(address pool, address sender) internal virtual {
        if(pool == XSDWETH_pool){
            IXSDWETHpool(pool).provideLiquidity2(sender);
        }
        else if(pool == BankXWETH_pool){
            IBankXWETHpool(pool).provideLiquidity2(sender);
        }
    }
    function creatorAddLiquidityTokens(
        address tokenB,
        uint amountB
    ) public virtual override {
        require(msg.sender == treasury, "Only the treasury address may access this function");
        if(tokenB == xsd_address){
            TransferHelper.safeTransferFrom(tokenB, msg.sender, XSDWETH_pool, amountB);
            IXSDWETHpool(XSDWETH_pool).provideLiquidity();
    }
    else if(tokenB == bankx_address){
        TransferHelper.safeTransferFrom(tokenB, msg.sender, BankXWETH_pool, amountB);
        IBankXWETHpool(BankXWETH_pool).provideLiquidity();
    }
    }
    function creatorAddLiquidityETH(
        address pool,
        uint amountETH
    ) external virtual payable override {
        require(msg.sender == treasury, "Only the treasury address may access this function");
        require(pool == XSDWETH_pool || pool == BankXWETH_pool, "Pool address is invalid");
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pool, amountETH));
        provideLiquidity(pool);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    function userAddLiquidityETH(
        address pool, 
        address sender,
        uint amountETH
    ) external virtual payable override{
        require(pool == XSDWETH_pool || pool == BankXWETH_pool, "Pool address is not valid");
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pool, amountETH));
        provideLiquidity2(pool, sender);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** SWAP ****

    function swapETHForXSD(uint amountOut, address to)
        external
        virtual
        payable
        override
    {
        (uint reserveA, uint reserveB, ) = IXSDWETHpool(XSDWETH_pool).getReserves();
        uint amounts = BankXLibrary.quote(amountOut, reserveA, reserveB);
        require(amounts >= amountOut, 'BankXRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts}();
        assert(IWETH(WETH).transfer(XSDWETH_pool, amounts));
        IXSDWETHpool(XSDWETH_pool).swap(amountOut, 0, to);
    }
    function swapXSDForETH(uint amountOut, uint amountInMax, address to)
        external
        virtual
        override
    {
        (uint reserveA, uint reserveB, ) = IXSDWETHpool(XSDWETH_pool).getReserves();
        uint amounts = BankXLibrary.quote(amountOut, reserveB, reserveA);
        require(amounts <= amountInMax, 'BankXRouter: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            xsd_address, msg.sender, XSDWETH_pool, amounts
        );
        IXSDWETHpool(XSDWETH_pool).swap(amounts, 0, to);
        IWETH(WETH).withdraw(amounts);
        TransferHelper.safeTransferETH(to, amounts);
    }

    function swapETHForBankX(uint amountOut, address to)
        external
        virtual
        override
        payable
    {
        (uint reserveA, uint reserveB, ) = IBankXWETHpool(BankXWETH_pool).getReserves();
        uint amounts = BankXLibrary.quote(amountOut, reserveA, reserveB);
        require(amounts >= amountOut, 'BankXRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts}();
        assert(IWETH(WETH).transfer(BankXWETH_pool, amounts));
        IBankXWETHpool(BankXWETH_pool).swap(amountOut, 0, to);
    }
    function swapBankXForETH(uint amountOut, uint amountInMax, address to)
        external
        virtual
        override
    {
        (uint reserveA, uint reserveB, ) = IBankXWETHpool(BankXWETH_pool).getReserves();
        uint amounts = BankXLibrary.quote(amountOut, reserveB, reserveA);
        require(amounts <= amountInMax, 'BankXRouter: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            bankx_address, msg.sender, BankXWETH_pool, amounts
        );
        IBankXWETHpool(BankXWETH_pool).swap(amounts, 0, to);
        IWETH(WETH).withdraw(amounts);
        TransferHelper.safeTransferETH(to, amounts);
    }
    
    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual returns (uint amountB) {
        return BankXLibrary.quote(amountA, reserveA, reserveB);
    }

    
}
