// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;


//must create interface for it
import './Math.sol';
import './SafeMath.sol';
import './UQ112x112.sol';
import './IPIDController.sol';
import './IERC20.sol';
import './XSD.sol';
import './BankX.sol';
import './IXSDWETHpool.sol';

contract XSDWETHpool is IXSDWETHpool{
    using SafeMath for uint;
    using SafeMath for uint112;
    using UQ112x112 for uint224;

    //uint public override constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
    bytes32 public override DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant override PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public override nonces;
    uint256 private constant PRICE_PRECISION = 1e6;
    address private XSDaddress;
    address private bankxaddress;
    address private WETHaddress;
    address private pid_address;
    address public smartcontract_owner = 0xC34faEea3605a168dBFE6afCd6f909714F844cd7;

    IPIDController pid_controller;
    XSDStablecoin private XSD;
    BankXToken private BankX;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves
    
    uint public override amountpaid;
    uint public override price0CumulativeLast;
    uint public override price1CumulativeLast;
    uint public override kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    struct LiquidityProvider{
        uint ethvalue;
        uint bankxrewards;
        uint xsdrewards;
        uint vestingtimestamp;
    }
    mapping(address => LiquidityProvider) private liquidity_provider;

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'XSDWETH: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public override view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'XSDWETH: TRANSFER_FAILED');
    }


    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    // called once by the smartcontract_address at time of deployment
    function initialize(address _token0, address _token1, address _bankx_contract_address, address _pid_address) public override {
        require(msg.sender == smartcontract_owner, 'XSD/WETH: FORBIDDEN'); // sufficient check
        XSDaddress = _token0;
        XSD = XSDStablecoin(XSDaddress);
        BankX = BankXToken(_bankx_contract_address);
        bankxaddress = _bankx_contract_address;
        WETHaddress = _token1;
        pid_controller = IPIDController(_pid_address);
        pid_address = _pid_address;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, 'XSDWETH: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    function provideLiquidity() external override lock{
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(XSDaddress).balanceOf(address(this));
        uint balance1 = IERC20(WETHaddress).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);
         _update(balance0, balance1, _reserve0, _reserve1);
        kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit ProvideLiquidity(msg.sender, amount0, amount1);
    }

    function provideLiquidity2(address to) external override lock{
        require(pid_controller.bucket1(), "There is no deficit detected");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(XSDaddress).balanceOf(address(this));
        uint balance1 = IERC20(WETHaddress).balanceOf(address(this));
        uint amount1 = balance1.sub(_reserve1);
        uint ethvalue = amount1.mul(XSD.eth_usd_price());
        uint difference = pid_controller.diff1();
        liquidity_provider[to].ethvalue = ethvalue;
        liquidity_provider[to].bankxrewards = liquidity_provider[to].bankxrewards.add(ethvalue.mul(9)).div(100);
        if(amountpaid<difference.div(3)){
            liquidity_provider[to].xsdrewards = liquidity_provider[to].xsdrewards.add(ethvalue.div(20));
            liquidity_provider[to].vestingtimestamp = block.timestamp.add(604800);
        }
        else if(amountpaid<(difference.mul(2)).div(3)){
            liquidity_provider[to].xsdrewards = liquidity_provider[to].xsdrewards.add(ethvalue.div(50));
            liquidity_provider[to].vestingtimestamp = block.timestamp.add(1209600);
        }
        else{
            liquidity_provider[to].vestingtimestamp = block.timestamp.add(1814400);
        }
        amountpaid = amountpaid.add(ethvalue);
         _update(balance0, balance1, _reserve0, _reserve1);
        kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit ProvideLiquidity2(msg.sender, amount1);
    }

    function LiquidityRedemption(address to) external override lock{
        require(liquidity_provider[to].bankxrewards != 0 || liquidity_provider[to].xsdrewards != 0, "Nothing to claim");
        require(liquidity_provider[to].vestingtimestamp<=block.timestamp, "vesting period is not over");
        uint bankxamount = liquidity_provider[to].bankxrewards.div(XSD.bankx_price());
        uint xsdamount = liquidity_provider[to].xsdrewards.div(XSD.xsd_price());
        BankX.pool_mint(to, bankxamount);
        XSD.pool_mint(to, xsdamount);
    }

    // Returns dollar value of collateral held in this XSD pool
    function collatDollarBalance() public view override returns (uint256) {
            uint256 eth_usd_price = XSD.eth_usd_price();
            //uint256 eth_collat_price = collatEthOracle.consult(weth_address, (PRICE_PRECISION * (10 ** missing_decimals)));

            //uint256 collat_usd_price = eth_usd_price.mul(PRICE_PRECISION).div(eth_collat_price);
            return ((IERC20(WETHaddress).balanceOf(address(this)).mul(eth_usd_price)).div(PRICE_PRECISION)); //.mul(getCollateralPrice()).div(1e6);    
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to) external override lock {
        require(amount0Out > 0 || amount1Out > 0, 'XSDWETH: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        _reserve0 = uint112(_reserve0.sub(1));
        _reserve1 = uint112(_reserve1.sub(1));
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'XSDWETH: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = XSDaddress;
        address _token1 = WETHaddress;
        require(to != _token0 && to != _token1, 'XSDWETH: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'XSDWETH: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0;
        uint balance1Adjusted = balance1;
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1), 'XSDWETH: K');
        }

        _update(balance0, balance1, uint112(_reserve0.add(1)),uint112(_reserve1.add(1)));
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external override lock {
        address _token0 = XSDaddress; // gas savings
        address _token1 = WETHaddress; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external override lock {
        _update(IERC20(XSDaddress).balanceOf(address(this)), IERC20(WETHaddress).balanceOf(address(this)), reserve0, reserve1);
    }

    /* ========== EVENTS ========== */
    event ProvideLiquidity(address sender, uint amount0, uint amount1);
    event ProvideLiquidity2(address sender, uint amount1);
    

}
