// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;


import "./Context.sol";
import "./ERC20Custom.sol";
import "./IERC20.sol";
import "./XSD.sol";
import "./Owned.sol";
import "./SafeMath.sol";
import "./AccessControl.sol";

contract BankXToken is ERC20Custom, AccessControl, Owned {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    string public symbol;
    string public name;
    uint8 public constant decimals = 18;
    
    
    uint256 public constant genesis_supply = 2000000000e18; // 2B is printed upon genesis
    address public pool_address; //points to BankX pool address
    address public timelock_address; // Governance timelock address
    XSDStablecoin private XSD; //XSD stablecoin instance
    uint256 public treasury_tokens; // keeps track of burnt tokens sent to the origin address
    /* ========== MODIFIERS ========== */

    modifier onlyPools() {
       require(XSD.xsd_pools(msg.sender) == true, "Only xsd pools can mint new XSD");
        _;
    } 
    
    modifier onlyByOwnerOrGovernance() {
        require(msg.sender == owner || msg.sender == timelock_address, "You are not an owner or the governance timelock");
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
        _mint(treasury, genesis_supply);

    
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setPool(address new_pool) external onlyByOwnerOrGovernance {
        require(new_pool != address(0), "Zero address detected");

        pool_address = new_pool;
    }

    function setTimelock(address new_timelock) external onlyByOwnerOrGovernance {
        require(new_timelock != address(0), "Timelock address cannot be 0");
        timelock_address = new_timelock;
    }
    
    function setXSDAddress(address xsd_contract_address) external onlyByOwnerOrGovernance {
        require(xsd_contract_address != address(0), "Zero address detected");

        XSD = XSDStablecoin(xsd_contract_address);

        emit XSDAddressSet(xsd_contract_address);
    }
    
    function mint(address to, uint256 amount) public onlyPools {
        _mint(to, amount);
    }
    
    function genesisSupply() public pure returns(uint256){
        return genesis_supply;
    }

    // This function is what other xsd pools will call to mint new BankX (similar to the XSD mint) 
    function pool_mint(address m_address, uint256 m_amount) external onlyPools  {        
        super._mint(m_address, m_amount);
        emit BankXMinted(address(this), m_address, m_amount);
    }

    // This function is what other xsd pools will call to burn BankX 
    function pool_burn_from(address b_address, uint256 b_amount) external onlyPools {

        super._burnFrom(b_address, b_amount);
        treasury_tokens = treasury_tokens.add(b_amount);
        emit BankXBurned(b_address, address(this), b_amount);
    }
    /* ========== OVERRIDDEN PUBLIC FUNCTIONS ========== */

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {

        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));

        return true;
    }
   
    
    /* ========== EVENTS ========== */

    // Track BankX burned
    event BankXBurned(address indexed from, address indexed to, uint256 amount);

    // Track BankX minted
    event BankXMinted(address indexed from, address indexed to, uint256 amount);

    event XSDAddressSet(address addr);
    event ValueReceived(address user, uint amount);
}
