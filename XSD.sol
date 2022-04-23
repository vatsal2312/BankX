// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;


import "./Context.sol";
import "./IERC20.sol";
import "./ERC20Custom.sol";
import "./ERC20.sol";
import "./SafeMath.sol";
import "./Owned.sol";
import "./BankX.sol";
import "./XSDPool.sol";
import "./IBankXWETHpool.sol";
import "./IXSDWETHpool.sol";
import "./ChainlinkETHUSDPriceConsumer.sol";
import "./ChainlinkXAGUSDPriceConsumer.sol";
import "./AccessControl.sol";

contract XSDStablecoin is ERC20Custom, AccessControl, Owned {
    using SafeMath for uint256;
    using SafeMath for uint64;

    /* ========== STATE VARIABLES ========== */
    enum PriceChoice { XSD, BankX }
    ChainlinkETHUSDPriceConsumer private eth_usd_pricer;
    ChainlinkXAGUSDPriceConsumer private xag_usd_pricer;
    uint8 private eth_usd_pricer_decimals;
    uint8 private xag_usd_pricer_decimals;
    string public symbol;
    string public name;
    uint8 public constant decimals = 18;
    address public timelock_address; // Governance timelock address
    address public controller_address; // Controller contract to dynamically adjust system parameters automatically
    address public bankx_address;
    address public xsd_eth_pool_address;
    address public bankx_eth_pool_address;
    address public collateral_pool_address;
    address public eth_usd_consumer_address;
    address public xag_usd_consumer_address;
    // interest rate related variables
    uint256 public interest_rate;
    BankXToken private BankX;
    IBankXWETHpool private bankxEthPool;
    IXSDWETHpool private xsdEthPool;
    
    uint256 public constant genesis_supply = 54 * 10**6; // 54M XSD (only for testing, genesis supply will be 5k on Mainnet). This is to help with establishing the Uniswap pools, as they need liquidity

    // The addresses in this array are added by the oracle and these contracts are able to mint xsd
    address[] public xsd_pools_array;

    // Mapping is also used for faster verification
    mapping(address => bool) public xsd_pools; 

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;
    
    uint256 public global_collateral_ratio; // 6 decimals of precision, e.g. 924102 = 0.924102
    uint256 public xsd_step; // Amount to change the collateralization ratio by upon refreshCollateralRatio()
    uint256 public refresh_cooldown; // Seconds to wait before being able to run refreshCollateralRatio() again
    uint256 public price_target; // The price of XSD at which the collateral ratio will respond to; this value is only used for the collateral ratio mechanism and not for minting and redeeming which are hardcoded at $1
    uint256 public price_band; // The bound above and below the price target at which the refreshCollateralRatio() will not change the collateral ratio

    address public DEFAULT_ADMIN_ADDRESS;
    bytes32 public constant COLLATERAL_RATIO_PAUSER = keccak256("COLLATERAL_RATIO_PAUSER");

    bool public collateral_ratio_paused = false;

    /* ========== MODIFIERS ========== */

    modifier onlyCollateralRatioPauser() {
        require(hasRole(COLLATERAL_RATIO_PAUSER, msg.sender));
        _;
    }

    modifier onlyPools() {
       require(xsd_pools[msg.sender] == true, "Only xsd pools can call this function");
        _;
    } 
    
    modifier onlyByOwnerGovernanceOrController() {
        require(msg.sender == owner || msg.sender == timelock_address || msg.sender == controller_address, "You are not the owner, controller, or the governance timelock");
        _;
    }

    modifier onlyByOwnerGovernanceOrPool() {
        require(
            msg.sender == owner 
            || msg.sender == timelock_address 
            || xsd_pools[msg.sender] == true, 
            "You are not the owner, the governance timelock, or a pool");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        string memory _name,
        string memory _symbol,
        address _timelock_address
    ) public Owned(smartcontract_owner){
        require(_timelock_address != address(0), "Zero address detected"); 
        name = _name;
        symbol = _symbol;
        timelock_address = _timelock_address;
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        DEFAULT_ADMIN_ADDRESS = _msgSender();
        _mint(treasury, genesis_supply);
        grantRole(COLLATERAL_RATIO_PAUSER, smartcontract_owner);
        grantRole(COLLATERAL_RATIO_PAUSER, timelock_address);
        xsd_step = 2500; // 6 decimals of precision, equal to 0.25%
        global_collateral_ratio = 1000000; // XSD system starts off fully collateralized (6 decimals of precision)
        interest_rate = 50000; //interest rate starts off at 5%
        refresh_cooldown = 3600; // Refresh cooldown period is set to 1 hour (3600 seconds) at genesis
        price_target = 800000; // Change price target to 1 gram of silver
        price_band = 5000; // Collateral ratio will not adjust if between $0.995 and $1.005 at genesis
    }
    //change price target to reflect true value of silver
    /* ========== VIEWS ========== */

    // Choice = 'XSD' or 'BankX' for now
    function pool_price(PriceChoice choice) internal view returns (uint256) {
        // Get the ETH / USD price first, and cut it down to 1e6 precision
        uint256 __eth_usd_price = uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
        uint256 price_vs_eth = 0;
        uint256 reserve0;
        uint256 reserve1;

        if (choice == PriceChoice.XSD) {
            (reserve0, reserve1, ) = xsdEthPool.getReserves();
            price_vs_eth = reserve0.div(reserve1); // How much XSD if you put in 1 WETH
        }
        else if (choice == PriceChoice.BankX) {
            (reserve0, reserve1, ) = bankxEthPool.getReserves();
            price_vs_eth = reserve0.div(reserve1);  // How much BankX if you put in 1 WETH
        }
        else revert("INVALID PRICE CHOICE. Needs to be either 0 (XSD) or 1 (BankX)");

        // Will be in 1e6 format
        return __eth_usd_price.div(price_vs_eth);
    }

    // Returns X XSD = 1 USD
    function xsd_price() public view returns (uint256) {
        return pool_price(PriceChoice.XSD);
    }

    // Returns X BankX = 1 USD
    function bankx_price()  public view returns (uint256) {
        return pool_price(PriceChoice.BankX);
    }

    function eth_usd_price() public view returns (uint256) {
        return uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
    }
    
    function xag_usd_price() public view returns (uint256) {
        return uint256(xag_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** xag_usd_pricer_decimals);
    }
    

    // This is needed to avoid costly repeat calls to different getter functions
    // It is cheaper gas-wise to just dump everything and only use some of the info
    function xsd_info(address _collateral_pool, address _xsd_pool, address _bankx_pool) public returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            pool_price(PriceChoice.XSD), // xsd_price()
            pool_price(PriceChoice.BankX), // bankx_price()
            totalSupply(), // totalSupply()
            global_collateral_ratio, // global_collateral_ratio()
            globalCollateralValue(), // globalCollateralValue
            uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals) //eth_usd_price
        );
    }

    // Iterate through all xsd pools and calculate all value of collateral in all pools globally 
    // rewrite this function.
    function globalCollateralValue() public returns (uint256) {
        uint256 collateral_amount = 0;
        uint256 _eth_usd_price = uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
        collateral_amount = XSDPool(collateral_pool_address).collatDollarBalance();
        return collateral_amount;
    }

    /* ========== PUBLIC FUNCTIONS ========== */
    
    // There needs to be a time interval that this can be called. Otherwise it can be called multiple times per expansion.
    uint256 public last_call_time; // Last time the refreshCollateralRatio function was called
    function refreshCollateralRatio() public {
        require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        uint256 xsd_price_cur = xsd_price();
        require(block.timestamp - last_call_time >= refresh_cooldown, "Must wait for the refresh cooldown since last refresh");

        // Step increments are 0.25% (upon genesis, changable by setXSDStep()) 
        
        if (xsd_price_cur > price_target.add(price_band)) { //decrease collateral ratio
            if(global_collateral_ratio <= xsd_step){ //if within a step of 0, go to 0
                global_collateral_ratio = 0;
            } else {
                global_collateral_ratio = global_collateral_ratio.sub(xsd_step);
            }
        } else if (xsd_price_cur < price_target.sub(price_band)) { //increase collateral ratio
            if(global_collateral_ratio.add(xsd_step) >= 1000000){
                global_collateral_ratio = 1000000; // cap collateral ratio at 1.000000
            } else {
                global_collateral_ratio = global_collateral_ratio.add(xsd_step);
            }
        }
        else
        last_call_time = block.timestamp; // Set the time of the last expansion
        uint256 _interest_rate = (1000000-global_collateral_ratio).div(2);
        //update interest rate
        if(_interest_rate>50000){
            interest_rate = _interest_rate;
        }
        else{
            interest_rate = 50000;
        }

        emit CollateralRatioRefreshed(global_collateral_ratio);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Used by pools when user redeems
    function pool_burn_from(address b_address, uint256 b_amount) public onlyPools {
        super._burnFrom(b_address, b_amount);
        emit XSDBurned(b_address, msg.sender, b_amount);
    }

    // This function is what other xsd pools will call to mint new XSD 
    function pool_mint(address m_address, uint256 m_amount) public onlyPools {
        super._mint(m_address, m_amount);
        emit XSDMinted(msg.sender, m_address, m_amount);
    }
    

    // Adds collateral addresses supported, such as tether and busd, must be ERC20 
    function addPool(address pool_address) public onlyByOwnerGovernanceOrController {
        require(pool_address != address(0), "Zero address detected");

        require(xsd_pools[pool_address] == false, "Address already exists");
        xsd_pools[pool_address] = true; 
        xsd_pools_array.push(pool_address);

        emit PoolAdded(pool_address);
    }

    // Remove a pool 
    function removePool(address pool_address) public onlyByOwnerGovernanceOrController {
        require(pool_address != address(0), "Zero address detected");

        require(xsd_pools[pool_address] == true, "Address nonexistant");
        
        // Delete from the mapping
        delete xsd_pools[pool_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint i = 0; i < xsd_pools_array.length; i++){ 
            if (xsd_pools_array[i] == pool_address) {
                xsd_pools_array[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }

        emit PoolRemoved(pool_address);
    }

    function setXSDStep(uint256 _new_step) public onlyByOwnerGovernanceOrController {
        xsd_step = _new_step;

        emit XSDStepSet(_new_step);
    }  

    function setPriceTarget (uint256 _new_price_target) public onlyByOwnerGovernanceOrController {
        price_target = _new_price_target;

        emit PriceTargetSet(_new_price_target);
    }

    function setRefreshCooldown(uint256 _new_cooldown) public onlyByOwnerGovernanceOrController {
    	refresh_cooldown = _new_cooldown;

        emit RefreshCooldownSet(_new_cooldown);
    }

    function setBankXAddress(address _bankx_address) public onlyByOwnerGovernanceOrController {
        require(_bankx_address != address(0), "Zero address detected");

        bankx_address = _bankx_address;
        BankX = BankXToken(bankx_address);

        emit BankXAddressSet(_bankx_address);
    }

    function getInterestRate() public view returns (uint256) {
        return interest_rate.div(10000);
    }

    function setETHUSDOracle(address _eth_usd_consumer_address) public onlyByOwnerGovernanceOrController {
        require(_eth_usd_consumer_address != address(0), "Zero address detected");

        eth_usd_consumer_address = _eth_usd_consumer_address;
        eth_usd_pricer = ChainlinkETHUSDPriceConsumer(eth_usd_consumer_address);
        eth_usd_pricer_decimals = eth_usd_pricer.getDecimals();

        emit ETHUSDOracleSet(_eth_usd_consumer_address);
    }
    
    function setXAGUSDOracle(address _xag_usd_consumer_address) public onlyByOwnerGovernanceOrController {
        require(_xag_usd_consumer_address != address(0), "Zero address detected");

        xag_usd_consumer_address = _xag_usd_consumer_address;
        xag_usd_pricer = ChainlinkXAGUSDPriceConsumer(xag_usd_consumer_address);
        xag_usd_pricer_decimals = xag_usd_pricer.getDecimals();

        emit XAGUSDOracleSet(_xag_usd_consumer_address);
    }

    function setTimelock(address new_timelock) external onlyByOwnerGovernanceOrController {
        require(new_timelock != address(0), "Zero address detected");

        timelock_address = new_timelock;

        emit TimelockSet(new_timelock);
    }

    function setController(address _controller_address) external onlyByOwnerGovernanceOrController {
        require(_controller_address != address(0), "Zero address detected");

        controller_address = _controller_address;

        emit ControllerSet(_controller_address);
    }

    function setPriceBand(uint256 _price_band) external onlyByOwnerGovernanceOrController {
        price_band = _price_band;

        emit PriceBandSet(_price_band);
    }

    // Sets the XSD_ETH Uniswap oracle address 
    function setXSDEthPool(address _xsd_pool_addr) public onlyByOwnerGovernanceOrController {
        require(_xsd_pool_addr != address(0), "Zero address detected");
        xsd_eth_pool_address = _xsd_pool_addr;
        xsdEthPool = IXSDWETHpool(_xsd_pool_addr); 

        emit XSDETHPoolSet(_xsd_pool_addr);
    }

    // Sets the BankX_ETH Uniswap oracle address 
    function setBankXEthPool(address _bankx_pool_addr) public onlyByOwnerGovernanceOrController {
        require(_bankx_pool_addr != address(0), "Zero address detected");

        bankx_eth_pool_address = _bankx_pool_addr;
        bankxEthPool = IBankXWETHpool(_bankx_pool_addr);

        emit BankXEthPoolSet(_bankx_pool_addr);
    }

    //sets the collateral pool address
    function setCollateralEthPool(address _collateral_pool_address) public onlyByOwnerGovernanceOrController {
        require(_collateral_pool_address != address(0), "Zero address detected");
        collateral_pool_address = _collateral_pool_address;
    }

    function toggleCollateralRatio() public onlyCollateralRatioPauser {
        collateral_ratio_paused = !collateral_ratio_paused;

        emit CollateralRatioToggled(collateral_ratio_paused);
    }

    /* ========== EVENTS ========== */

    // Track XSD burned
    event XSDBurned(address indexed from, address indexed to, uint256 amount);

    // Track XSD minted
    event XSDMinted(address indexed from, address indexed to, uint256 amount);

    event CollateralRatioRefreshed(uint256 global_collateral_ratio);
    event PoolAdded(address pool_address);
    event PoolRemoved(address pool_address);
    event RedemptionFeeSet(uint256 red_fee);
    event MintingFeeSet(uint256 min_fee);
    event XSDStepSet(uint256 new_step);
    event PriceTargetSet(uint256 new_price_target);
    event RefreshCooldownSet(uint256 new_cooldown);
    event BankXAddressSet(address _bankx_address);
    event ETHUSDOracleSet(address eth_usd_consumer_address);
    event XAGUSDOracleSet(address xag_usd_consumer_address);
    event TimelockSet(address new_timelock);
    event ControllerSet(address controller_address);
    event PriceBandSet(uint256 price_band);
    event XSDETHPoolSet(address xsd_pool_addr);
    event BankXEthPoolSet(address bankx_pool_addr);
    event CollateralRatioToggled(bool collateral_ratio_paused);
}
