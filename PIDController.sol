// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;


import '../XSD/XSD.sol';
import "../Math/SafeMath.sol";
import "../Uniswap/BankXLibrary.sol";
import "../XSD/Pools/XSDPool.sol";
import "../XSD/Pools/Interfaces/IBankXWETHpool.sol";
import "../XSD/Pools/Interfaces/IXSDWETHpool.sol";


contract PIDController is Owned {
    using SafeMath for uint256;

    // Instances
    XSDStablecoin private XSD;
    BankXToken private BankX;
    XSDPool private xsdpool;

    // XSD and BankX addresses
    address private xsd_contract_address;
    address private bankx_contract_address;
    address private xsdpool_contract_address;
    address private xsdwethpool_address;
    address private bankxwethpool_address;
    address public smartcontract_owner = 0xC34faEea3605a168dBFE6afCd6f909714F844cd7;
    // Misc addresses
    address public timelock_address;
    address public immutable WETH;
    // 6 decimals of precision
    uint256 public growth_ratio;
    uint256 public xsd_step;
    uint256 public GR_top_band;
    uint256 public GR_bottom_band;

    // Bands
    uint256 public XSD_top_band;
    uint256 public XSD_bottom_band;

    // Time-related
    uint256 public internal_cooldown;
    uint256 public last_update;
    
    // Booleans
    bool public is_active;
    bool public use_growth_ratio;
    bool public collateral_ratio_paused;
    bool public FIP_6;
    bool public bucket1;
    bool public bucket2;
    bool public bucket3;

    uint public diff1;
    uint public diff2;
    uint public diff3;

    uint public timestamp1;
    uint public timestamp2;
    uint public timestamp3;

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnerOrGovernance() {
        require(msg.sender == owner || msg.sender == timelock_address, "Not owner or timelock");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _xsd_contract_address,
        address _bankx_contract_address,
        address _xsd_weth_pool_address, 
        address _bankx_weth_pool_address,
        address _xsdpool_contract_address,
        address _WETHaddress,
        address _timelock_address
    ) Owned(smartcontract_owner) {
        xsd_contract_address = _xsd_contract_address;
        bankx_contract_address = _bankx_contract_address;
        xsdpool_contract_address = _xsdpool_contract_address;
        xsdwethpool_address = _xsd_weth_pool_address;
        bankxwethpool_address = _bankx_weth_pool_address;
        timelock_address = _timelock_address;
        xsd_step = 2500;
        xsdpool = XSDPool(_xsdpool_contract_address);
        XSD = XSDStablecoin(xsd_contract_address);
        BankX = BankXToken(bankx_contract_address);
        WETH = _WETHaddress;

        // Upon genesis, if GR changes by more than 1% percent, enable change of collateral ratio
        GR_top_band = 1000;
        GR_bottom_band = 1000; 
        is_active = false;
    }

    //interest rate variable
    /* ========== PUBLIC MUTATIVE FUNCTIONS ========== */
    
    function refreshCollateralRatio() public {
    	require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        uint256 time_elapsed = (block.timestamp).sub(last_update);
        require(time_elapsed >= internal_cooldown, "internal cooldown not passed");
        uint256 bankx_reserves = BankX.balanceOf(bankxwethpool_address);
        uint256 bankx_price = XSD.bankx_price();
        
        uint256 bankx_liquidity = (bankx_reserves.mul(bankx_price)); // Has 6 decimals of precision

        uint256 xsd_supply = XSD.totalSupply();
        
        // Get the XSD price
        uint256 xsd_price = XSD.xsd_price();

        uint256 new_growth_ratio = bankx_liquidity.div(xsd_supply); // (E18 + E6) / E18

        uint256 last_collateral_ratio = XSD.global_collateral_ratio();
        uint256 new_collateral_ratio = last_collateral_ratio;

        if(FIP_6){
            require(xsd_price > XSD_top_band || xsd_price < XSD_bottom_band, "Use PIDController when XSD is outside of peg");
        }

        // First, check if the price is out of the band
        if(xsd_price > XSD_top_band){
            new_collateral_ratio = last_collateral_ratio.sub(xsd_step);
        } else if (xsd_price < XSD_bottom_band){
            new_collateral_ratio = last_collateral_ratio.add(xsd_step);

        // Else, check if the growth ratio has increased or decreased since last update
        } else if(use_growth_ratio){
            if(new_growth_ratio > growth_ratio.mul(1e6 + GR_top_band).div(1e6)){
                new_collateral_ratio = last_collateral_ratio.sub(xsd_step);
            } else if (new_growth_ratio < growth_ratio.mul(1e6 - GR_bottom_band).div(1e6)){
                new_collateral_ratio = last_collateral_ratio.add(xsd_step);
            }
        }

        growth_ratio = new_growth_ratio;
        last_update = block.timestamp;

        // No need for checking CR under 0 as the last_collateral_ratio.sub(xsd_step) will throw 
        // an error above in that case
        if(new_collateral_ratio > 1e6){
            new_collateral_ratio = 1e6;
        }
        (bucket1, diff1) = incentiveChecker1();
        (bucket2, diff2) = incentiveChecker2();
        (bucket3, diff3) = incentiveChecker3();

        if(is_active){
            uint256 delta_collateral_ratio;
            if(new_collateral_ratio > last_collateral_ratio){
                delta_collateral_ratio = new_collateral_ratio - last_collateral_ratio;
                XSD.setPriceTarget(0); // Set to zero to increase CR
                emit XSDdecollateralize(new_collateral_ratio);
            } else if (new_collateral_ratio < last_collateral_ratio){
                delta_collateral_ratio = last_collateral_ratio - new_collateral_ratio;
                XSD.setPriceTarget(1000e6); // Set to high value to decrease CR
                emit XSDrecollateralize(new_collateral_ratio);
            }

            XSD.setXSDStep(delta_collateral_ratio); // Change by the delta
            uint256 cooldown_before = XSD.refresh_cooldown(); // Note the existing cooldown period
            XSD.setRefreshCooldown(0); // Unlock the CR cooldown

            XSD.refreshCollateralRatio(); // Refresh CR

            // Reset params
            XSD.setXSDStep(0);
            XSD.setRefreshCooldown(cooldown_before); // Set the cooldown period to what it was before, or until next controller refresh
            //change price target to that of one ounce/gram of silver.
            XSD.setPriceTarget((XSD.xag_usd_price().mul(283495)).div(1e4));           
        }
    }

    function incentiveChecker1() internal returns(bool bucket, uint difference){
        uint XSDvalue = XSD.totalSupply().mul(XSD.xsd_price());
        uint _reserve0;
        uint _reserve1;
        (_reserve0, _reserve1,) = IXSDWETHpool(xsdwethpool_address).getReserves();
        uint reserve0 = _reserve0.mul(XSD.xsd_price());
        uint reserve1 = _reserve1.mul(XSD.eth_usd_price());
        if(block.timestamp.sub(timestamp1)>=64800){
            timestamp1 = 0;
            bucket = false;
            difference = 0;
        }
        if(timestamp1 == 0){
        if(reserve0.add(reserve1)<XSDvalue.div(5)){
            bucket = true;
            difference = (XSDvalue.div(5)).sub(reserve0.add(reserve1));
            timestamp1 = block.timestamp;
        }
        }
    }

    function incentiveChecker2() internal returns(bool bucket, uint difference){
        uint XSDvalue = XSD.totalSupply().mul(XSD.xsd_price());
        uint _reserve0;
        uint _reserve1;
        (_reserve0, _reserve1,) = IBankXWETHpool(bankxwethpool_address).getReserves();
        uint reserve0 = _reserve0.mul(XSD.bankx_price());
        uint reserve1 = _reserve1.mul(XSD.eth_usd_price());
        if(block.timestamp.sub(timestamp2)>=64800){
            timestamp2 = 0;
            bucket = false;
            difference = 0;
        }
        if(timestamp2 == 0){
        if(reserve0.add(reserve1)<XSDvalue.div(5)){
            bucket = true;
            difference = (XSDvalue.div(5)).sub(reserve0.add(reserve1));
            timestamp2 = block.timestamp;
        }
        }
    }

    function incentiveChecker3() internal returns(bool bucket, uint difference){
        uint XSDvalue = XSD.totalSupply().mul(XSD.xsd_price());
        uint collatValue = xsdpool.collatDollarBalance();
        if(block.timestamp.sub(timestamp3)>=64800){
            timestamp3 = 0;
            bucket = false;
            difference = 0;
        }
        if(timestamp3 == 0){
        if((XSDvalue.mul(100)).div(collatValue)>=3){
            bucket = true;
            difference = collatValue - XSDvalue;
            timestamp3 = block.timestamp;
        }
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function activate(bool _state) external onlyByOwnerOrGovernance {
        is_active = _state;
    }

    function useGrowthRatio(bool _use_growth_ratio) external onlyByOwnerOrGovernance {
        use_growth_ratio = _use_growth_ratio;
    }

    // As a percentage added/subtracted from the previous; e.g. top_band = 4000 = 0.4% -> will decollat if GR increases by 0.4% or more
    function setGrowthRatioBands(uint256 _GR_top_band, uint256 _GR_bottom_band) external onlyByOwnerOrGovernance {
        GR_top_band = _GR_top_band;
        GR_bottom_band = _GR_bottom_band;
    }

    function setInternalCooldown(uint256 _internal_cooldown) external onlyByOwnerOrGovernance {
        internal_cooldown = _internal_cooldown;
    }

    function setXSDStep(uint256 _new_step) external onlyByOwnerOrGovernance {
        xsd_step = _new_step;
    }

    function setPriceBands(uint256 _top_band, uint256 _bottom_band) external onlyByOwnerOrGovernance {
        XSD_top_band = _top_band;
        XSD_bottom_band = _bottom_band;
    }

    function setTimelock(address new_timelock) external onlyByOwnerOrGovernance {
        require(new_timelock != address(0), "Timelock address cannot be 0");
        timelock_address = new_timelock;
    }

    function toggleCollateralRatio(bool _is_paused) external onlyByOwnerOrGovernance {
    	collateral_ratio_paused = _is_paused;
    }

    function activateFIP6(bool _activate) external onlyByOwnerOrGovernance {
        FIP_6 = _activate;
    }


    /* ========== EVENTS ========== */  
    event XSDdecollateralize(uint256 new_collateral_ratio);
    event XSDrecollateralize(uint256 new_collateral_ratio);
}